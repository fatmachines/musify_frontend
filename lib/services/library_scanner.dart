import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/playlist.dart';

const audioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.flac',
  '.wav',
  '.ogg',
  '.opus',
  '.wma',
  '.aif',
  '.aiff',
};

class ScanResult {
  final List<Playlist> playlists;

  /// What the scan saw, folder by folder, for diagnosing empty libraries.
  final List<String> log;

  /// Set when the chosen folder itself couldn't be listed.
  final String? rootError;

  const ScanResult(this.playlists, this.log, this.rootError);
}

class LibraryScanner {
  /// Walks [rootPath] off the UI isolate and returns one playlist per folder
  /// that holds audio files, sorted by relative path.
  static Future<ScanResult> scan(String rootPath) {
    return Isolate.run(() => _scanSync(rootPath));
  }

  static ScanResult _scanSync(String rootPath) {
    final log = <String>['scan: root=$rootPath'];
    final playlists = <Playlist>[];
    final pending = [Directory(rootPath)];
    String? rootError;

    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      final rel = p.relative(dir.path, from: rootPath);
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException catch (e) {
        log.add(
          'scan: [$rel] list failed: ${e.message} '
          '(os: ${e.osError?.message}, code ${e.osError?.errorCode})',
        );
        // An unreadable root means the whole library is unavailable; an
        // unreadable subfolder is skipped rather than failing the scan.
        if (dir.path == rootPath) rootError = e.message;
        continue;
      }

      final tracks = <Track>[];
      final skipped = <String>[];
      var dirs = 0;
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) {
          skipped.add('$name (hidden)');
          continue;
        }
        if (entry is Directory) {
          dirs++;
          pending.add(entry);
        } else if (entry is File &&
            audioExtensions.contains(p.extension(name).toLowerCase())) {
          tracks.add(Track(entry.path));
        } else {
          skipped.add('$name (${entry.runtimeType})');
        }
      }

      log.add(
        'scan: [$rel] entries=${entries.length} dirs=$dirs '
        'audio=${tracks.length} skipped=${skipped.length}',
      );
      if (skipped.isNotEmpty) {
        log.add('scan: [$rel] skipped e.g. ${skipped.take(5).join(', ')}');
      }

      if (tracks.isNotEmpty) {
        tracks.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        playlists.add(
          Playlist(path: dir.path, relativePath: rel, tracks: tracks),
        );
      }
    }

    playlists.sort(
      (a, b) =>
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
    );
    log.add('scan: done, playlists=${playlists.length}');
    return ScanResult(playlists, log, rootError);
  }
}
