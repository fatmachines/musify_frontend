import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'musify_server.dart';

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

  static Future<String?> lastFolder() async =>
      (await SharedPreferences.getInstance()).getString(_lastFolderKey);

  /// Queues [track] for saving into [folder]. [onDone] gets the saved file,
  /// or null if it failed (with why).
  void download(
    YouTubeTrack track,
    String folder, {
    void Function(File? file, String? error)? onDone,
  }) {
    if (isQueued(track)) return;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(_lastFolderKey, folder),
    );
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
    } catch (e) {
      error = '$e';
      AppLog.add('download: ${track.name} failed: $e');
    }
    _progress.remove(track.videoId);
    _current = null;
    _batchDone++;
    notifyListeners();
    _callbacks.remove(track.videoId)?.call(file, error);
    _next();
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
    await Library.instance.rescan();
    return file;
  }

  /// "Title", without characters file systems refuse.
  static String _fileName(YouTubeTrack track) {
    final safe = track.name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final name = safe.isEmpty ? track.videoId : safe;
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
