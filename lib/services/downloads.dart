import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'local_copies.dart';
import 'musify_server.dart';
import 'sync_service.dart';

/// Saves YouTube songs into library folders as M4A, through Musify's
/// server (AAC as YouTube has it, with title, artist and cover). Then
/// rescans, so the song shows up in its folder's playlist. One song at a
/// time; the rest wait their turn.
class Downloads extends ChangeNotifier {
  Downloads._();

  static final instance = Downloads._();

  static const _lastFolderKey = 'download_last_folder';

  /// Songs waiting or downloading, in order, with progress (0 to 1; null
  /// while waiting).
  final _progress = <String, double?>{};
  final _waiting = <(YouTubeTrack, String)>[];
  YouTubeTrack? _current;

  YouTubeTrack? get current => _current;

  bool isQueued(YouTubeTrack track) => _progress.containsKey(track.videoId);

  double? progressOf(YouTubeTrack track) => _progress[track.videoId];

  /// How many songs are still to save, including the current one.
  int get pending => _progress.length;

  /// Songs asked for since the queue was last empty, and how many of them
  /// are finished (saved or failed): "2/3 downloading".
  int get batchTotal => _batchTotal;
  int get batchDone => _batchDone;
  int _batchTotal = 0;
  int _batchDone = 0;

  /// Shows [track] as downloading, for screenshots and tests.
  @visibleForTesting
  void debugShow(YouTubeTrack track, double progress, int done, int total) {
    _current = track;
    _progress[track.videoId] = progress;
    _batchDone = done;
    _batchTotal = total;
    notifyListeners();
  }

  /// The last folder downloaded into follows it being renamed.
  static Future<void> followRename(String from, String to) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_lastFolderKey);
    if (last == null) return;
    if (last == from || p.isWithin(from, last)) {
      await prefs.setString(
        _lastFolderKey,
        p.normalize(p.join(to, p.relative(last, from: from))),
      );
    }
  }

  static Future<String?> lastFolder() async =>
      (await SharedPreferences.getInstance()).getString(_lastFolderKey);

  /// Queues [track] for saving into [folder]. [onDone] gets the saved file,
  /// or null if it failed (with why).
  void download(
    YouTubeTrack track,
    String folder, {
    void Function(File? file, String? error)? onDone,
    bool remember = true,
  }) {
    if (isQueued(track)) return;
    if (remember) {
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(_lastFolderKey, folder),
      );
    }
    if (_progress.isEmpty) _batchTotal = _batchDone = 0;
    _batchTotal++;
    _progress[track.videoId] = null;
    _waiting.add((track, folder));
    _callbacks[track.videoId] = onDone;
    notifyListeners();
    if (_current == null) _next();
  }

  final _callbacks = <String, void Function(File?, String?)?>{};

  Future<void> _next() async {
    if (_waiting.isEmpty) return;
    final (track, folder) = _waiting.removeAt(0);
    _current = track;
    _progress[track.videoId] = 0;
    notifyListeners();
    File? file;
    String? error;
    try {
      file = await _save(track, folder);
      await LocalCopies.instance.remember(track, file.path);
    } catch (e) {
      error = '$e';
      AppLog.add('download: ${track.name} failed: $e');
    }
    _progress.remove(track.videoId);
    _current = null;
    _batchDone++;
    notifyListeners();
    _callbacks.remove(track.videoId)?.call(file, error);
    // Once the queue is done, the library picks the new songs (and any new
    // playlist folder) up, and the user's other devices get them.
    if (_waiting.isEmpty) {
      await Library.instance.rescan();
      SyncService.instance.filesChanged();
    }
    _next();
  }

  /// Saves every YouTube song in [playlist] into a new folder named after
  /// it inside [parent], which then shows up as a folder playlist. Songs
  /// already saved there are skipped.
  ///
  /// One of the user's own playlists becomes that folder: its songs on the
  /// device are copied in too, and once every song is there the playlist
  /// is no longer shown on this device (the folder takes its place on Home
  /// if it was pinned); other devices keep it. If any song fails, the
  /// playlist stays.
  ///
  /// Returns how many songs were queued, and the folder. [onDone] gets how
  /// many were saved and failed, and whether the playlist became the folder.
  Future<(int, String)> downloadPlaylist(
    Playlist playlist,
    String parent, {
    void Function(int saved, int failed, bool converted)? onDone,
  }) async {
    final folder = Directory(p.join(parent, _safe(playlist.name, 'Playlist')));
    await folder.create(recursive: true);
    final library = Library.instance;
    final convert =
        playlist.isCustom &&
        !Library.isSystem(playlist) &&
        !Library.isRemote(playlist);

    // The playlist's songs already on the device come along as copies.
    var copyFailed = 0;
    if (convert) {
      for (final song in playlist.tracks) {
        // A YouTube song on the device already comes as its file.
        final track = LocalCopies.instance.resolve(song);
        if (track is YouTubeTrack) continue;
        final target = File(p.join(folder.path, p.basename(track.path)));
        if (target.existsSync()) continue;
        try {
          await File(track.path).copy(target.path);
        } on FileSystemException catch (e) {
          copyFailed++;
          AppLog.add('download: copying ${track.path} failed: ${e.message}');
        }
      }
    }

    final songs = [
      for (final track in playlist.tracks)
        if (track is YouTubeTrack &&
            !isQueued(track) &&
            LocalCopies.instance.copyOf(track) == null &&
            !File(p.join(folder.path, '${_fileName(track)}.m4a')).existsSync())
          track,
    ];
    AppLog.add(
      'download: playlist ${playlist.name}, ${songs.length} songs -> '
      '${folder.path}${convert ? ' (becomes the folder)' : ''}',
    );

    Future<void> finish(int saved, int failed) async {
      var converted = false;
      if (convert && failed == 0 && copyFailed == 0) {
        await library.rescan();
        final folderPlaylist = library.byId(folder.path);
        if (folderPlaylist != null) {
          library.replaceWithFolder(playlist, folderPlaylist);
          converted = true;
        }
        AppLog.add('download: ${playlist.name} is now a folder');
      }
      onDone?.call(saved, failed + copyFailed, converted);
    }

    if (songs.isEmpty) {
      await finish(0, 0);
      return (0, folder.path);
    }
    var saved = 0;
    var failed = 0;
    for (final track in songs) {
      download(
        track,
        folder.path,
        remember: false,
        onDone: (file, _) {
          file == null ? failed++ : saved++;
          if (saved + failed == songs.length) finish(saved, failed);
        },
      );
    }
    return (songs.length, folder.path);
  }

  Future<File> _save(YouTubeTrack track, String folder) async {
    var shown = 0.0;
    final file = _freeName(Directory(folder), _fileName(track));
    await MusifyServer.instance.download(
      track,
      file,
      onProgress: (progress) {
        // Don't rebuild for every packet.
        if (progress - shown < 0.01 && progress < 1) return;
        shown = progress;
        _progress[track.videoId] = progress;
        notifyListeners();
      },
    );
    return file;
  }

  /// "Title", without characters file systems refuse.
  static String _fileName(YouTubeTrack track) =>
      _safe(track.name, track.videoId);

  static String _safe(String raw, String fallback) {
    // Quotes become single ones rather than gaps: Darasal (From 'Raabta').
    final safe = raw
        .replaceAll('"', "'")
        .replaceAll(RegExp(r'[\\/:*?<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(RegExp(r'([(\[]) | ([)\]])'), (m) => m[1] ?? m[2]!)
        .trim();
    final name = safe.isEmpty || safe.startsWith('.') ? fallback : safe;
    return name.length > 120 ? name.substring(0, 120).trim() : name;
  }

  static File _freeName(Directory folder, String name) {
    var file = File(p.join(folder.path, '$name.m4a'));
    for (var n = 2; file.existsSync(); n++) {
      file = File(p.join(folder.path, '$name ($n).m4a'));
    }
    return file;
  }
}
