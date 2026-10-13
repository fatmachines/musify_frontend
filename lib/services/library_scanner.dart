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

class LibraryScanner {
  /// Walks [rootPath] off the UI isolate and returns one playlist per folder
  /// that holds audio files, sorted by relative path.
  static Future<List<Playlist>> scan(String rootPath) {
    return Isolate.run(() => _scanSync(rootPath));
  }

  static List<Playlist> _scanSync(String rootPath) {
    final playlists = <Playlist>[];
    final pending = [Directory(rootPath)];

    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        // Unreadable subfolder: skip it rather than failing the whole scan.
        continue;
      }

      final tracks = <Track>[];
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (entry is Directory) {
          pending.add(entry);
        } else if (entry is File &&
            audioExtensions.contains(p.extension(name).toLowerCase())) {
          tracks.add(Track(entry.path));
        }
      }

      if (tracks.isNotEmpty) {
        tracks.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        playlists.add(Playlist(
          path: dir.path,
          relativePath: p.relative(dir.path, from: rootPath),
          tracks: tracks,
        ));
      }
    }

    playlists.sort((a, b) =>
        a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()));
    return playlists;
  }
}
