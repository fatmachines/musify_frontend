import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'metadata_service.dart';
import 'youtube/youtube_media.dart';

/// Saves YouTube songs into library folders as M4A (AAC, as YouTube serves
/// it: no re-encoding), with title, artist and cover written into the file,
/// then rescans so they show up in their folder's playlist.
class Downloads extends ChangeNotifier {
  Downloads._();

  static final instance = Downloads._();

  static const _lastFolderKey = 'download_last_folder';

  /// Progress (0 to 1) of songs downloading, by video id.
  final _progress = <String, double>{};

  double? progressOf(YouTubeTrack track) => _progress[track.videoId];

  static Future<String?> lastFolder() async =>
      (await SharedPreferences.getInstance()).getString(_lastFolderKey);

  /// Returns the saved file, or null if it failed.
  Future<File?> download(YouTubeTrack track, String folder) async {
    if (_progress.containsKey(track.videoId)) return null;
    _progress[track.videoId] = 0;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_lastFolderKey, folder);

    final media = YouTubeMedia.instance;
    File? file;
    try {
      final size = await media.sizeOf(track.videoId);
      file = _freeName(Directory(folder), _fileName(track));
      final sink = file.openWrite();
      var done = 0;
      var shown = 0.0;
      try {
        await for (final data in media.bytes(track.videoId, 0, size)) {
          sink.add(data);
          done += data.length;
          final progress = done / size;
          // Don't rebuild for every packet.
          if (progress - shown >= 0.02) {
            shown = progress;
            _progress[track.videoId] = progress;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      await _writeTags(file, track);
      AppLog.add('download: ${track.name} -> ${file.path}');
      await Library.instance.rescan();
      return file;
    } catch (e) {
      AppLog.add('download: ${track.name} failed: $e');
      if (file != null && file.existsSync()) file.deleteSync();
      return null;
    } finally {
      _progress.remove(track.videoId);
      notifyListeners();
    }
  }

  static Future<void> _writeTags(File file, YouTubeTrack track) async {
    final cover = await MetadataService.cover(track);
    try {
      updateMetadata(file, (metadata) {
        if (metadata is! Mp4Metadata) return;
        metadata.title = track.name;
        metadata.artist = track.channel;
        if (cover != null) {
          metadata.picture = Picture(
            cover,
            'image/jpeg',
            PictureType.coverFront,
          );
        }
      });
    } catch (e) {
      // The file plays without tags; its name carries title and channel.
      AppLog.add('download: tags not written: $e');
    }
  }

  /// "Title - Channel", without characters file systems refuse.
  static String _fileName(YouTubeTrack track) {
    final raw = [track.name, ?track.channel].join(' - ');
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.length > 120 ? safe.substring(0, 120).trim() : safe;
  }

  static File _freeName(Directory folder, String name) {
    var file = File(p.join(folder.path, '$name.m4a'));
    for (var n = 2; file.existsSync(); n++) {
      file = File(p.join(folder.path, '$name ($n).m4a'));
    }
    return file;
  }
}
