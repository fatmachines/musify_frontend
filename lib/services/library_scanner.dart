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
  ///
  /// A folder's songs are in the order they were added (oldest first, so
  /// new songs come last); songs added together, like an album copied in
  /// one go, are in name order. Added means the file's change time
  /// (ctime), which a copy, download or move sets.
  static Future<ScanResult> scan(
    String rootPath, {
    Duration batchGap = const Duration(minutes: 2),
  }) {
    return Isolate.run(() => _scanSync(rootPath, batchGap));
  }

  static ScanResult _scanSync(String rootPath, Duration batchGap) {
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

      final found = <(Track, DateTime)>[];
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
          found.add((Track(entry.path), entry.statSync().changed));
        } else {
          skipped.add('$name (${entry.runtimeType})');
        }
      }

      final tracks = _inAddedOrder(found, batchGap);
      log.add(
        'scan: [$rel] entries=${entries.length} dirs=$dirs '
        'audio=${tracks.length} skipped=${skipped.length}',
      );
      if (skipped.isNotEmpty) {
        log.add('scan: [$rel] skipped e.g. ${skipped.take(5).join(', ')}');
      }

      if (tracks.isNotEmpty) {
        playlists.add(
          Playlist(
            id: dir.path,
            name: p.basename(dir.path),
            location: rel,
            tracks: tracks,
          ),
        );
      }
    }

    playlists.sort(
      (a, b) => a.location!.toLowerCase().compareTo(b.location!.toLowerCase()),
    );
    log.add('scan: done, playlists=${playlists.length}');
    return ScanResult(playlists, log, rootError);
  }

  /// Oldest first; songs added within [batchGap] of each other count as
  /// one batch, in name order.
  static List<Track> _inAddedOrder(
    List<(Track, DateTime)> found,
    Duration batchGap,
  ) {
    int byName(Track a, Track b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());
    found.sort((a, b) => a.$2.compareTo(b.$2));
    final ordered = <Track>[];
    var batch = <Track>[];
    DateTime? previous;
    for (final (track, added) in found) {
      if (previous != null && added.difference(previous) > batchGap) {
        ordered.addAll(batch..sort(byName));
        batch = [];
      }
      batch.add(track);
      previous = added;
    }
    return ordered..addAll(batch..sort(byName));
  }
}
