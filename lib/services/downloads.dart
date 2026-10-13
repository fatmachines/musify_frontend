import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'metadata_service.dart';
import 'youtube/mp4_audio.dart';
import 'youtube/youtube_capture.dart';

/// Saves YouTube songs into library folders as M4A: the AAC audio YouTube's
/// player is given (captured by YouTubeCapture, not re-encoded), with title,
/// artist and cover in the file. Then rescans, so the song shows up in its
/// folder's playlist. One song at a time; the rest wait their turn.
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
    notifyListeners();
    _callbacks.remove(track.videoId)?.call(file, error);
    _next();
  }

  Future<File> _save(YouTubeTrack track, String folder) async {
    var shown = 0.0;
    final captured = await YouTubeCapture.instance.capture(
      track,
      onProgress: (progress) {
        // Don't rebuild for every tick.
        if ((progress - shown).abs() < 0.01) return;
        shown = progress;
        _progress[track.videoId] = progress * 0.98;
        notifyListeners();
      },
    );
    final cover = await MetadataService.cover(track);
    final audio = Mp4Audio.flatten(
      captured,
      title: track.name,
      artist: track.channel,
      cover: cover,
    );
    if (audio == null) throw CaptureFailed('the audio was unreadable');
    AppLog.add(
      'download: ${track.name}: ${audio.duration.inSeconds}s, '
      'gaps ${audio.gaps.inMilliseconds}ms, ${audio.bytes.length} bytes',
    );
    // Missing more than a moment: better no file than a broken one.
    final expected = track.length;
    if (audio.gaps > const Duration(seconds: 2) ||
        (expected != null &&
            audio.duration < expected - const Duration(seconds: 3))) {
      throw CaptureFailed('only part of the song came through');
    }
    final file = _freeName(Directory(folder), _fileName(track));
    await file.writeAsBytes(audio.bytes, flush: true);
    AppLog.add('download: saved ${file.path}');
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
