import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../models/playlist.dart';

/// Tags read from an audio file. Any field can be missing: plenty of files
/// carry no tags at all.
class TrackInfo {
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;

  const TrackInfo({this.title, this.artist, this.album, this.duration});

  static const empty = TrackInfo();
}

/// Reads tags and embedded cover art off the UI isolate and caches them for
/// the app's lifetime.
class MetadataService {
  static final _info = <String, TrackInfo>{};
  static final _covers = <String, Future<Uint8List?>>{};
  static final _playlistCovers = <String, Future<List<Uint8List>>>{};

  static TrackInfo? cachedInfo(Track track) => _info[track.path];

  /// Tags (no artwork) for every track not read yet.
  static Future<void> loadInfo(List<Track> tracks) async {
    final missing = [
      for (final t in tracks)
        if (!_info.containsKey(t.path)) t.path
    ];
    if (missing.isEmpty) return;
    final read = await Isolate.run(() => {
          for (final path in missing) path: _readInfo(path),
        });
    _info.addAll(read);
  }

  static Future<Uint8List?> cover(Track track) {
    return _covers.putIfAbsent(
        track.path, () => Isolate.run(() => _readCover(track.path)));
  }

  /// Up to four different covers from random songs in [playlist], for the
  /// Spotify-style mosaic. Picked once per playlist per app run.
  static Future<List<Uint8List>> playlistCovers(Playlist playlist) {
    return _playlistCovers.putIfAbsent(playlist.path, () async {
      final candidates = [...playlist.tracks]..shuffle(Random());
      final covers = <Uint8List>[];
      final seen = <int>{};
      // Songs from one album share a cover, so look past duplicates, but
      // give up after a bounded number of reads on big folders.
      for (final track in candidates.take(24)) {
        final bytes = await cover(track);
        if (bytes == null || !seen.add(_fingerprint(bytes))) continue;
        covers.add(bytes);
        if (covers.length == 4) break;
      }
      return covers;
    });
  }

  static TrackInfo _readInfo(String path) {
    try {
      final m = readMetadata(File(path));
      return TrackInfo(
        title: _clean(m.title),
        artist: _clean(m.artist),
        album: _clean(m.album),
        duration: m.duration,
      );
    } catch (_) {
      return TrackInfo.empty;
    }
  }

  static Uint8List? _readCover(String path) {
    try {
      final pictures = readMetadata(File(path), getImage: true).pictures;
      if (pictures.isEmpty) return null;
      final front = pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => pictures.first,
      );
      return front.bytes;
    } catch (_) {
      return null;
    }
  }

  static String? _clean(String? value) {
    final trimmed = value?.replaceAll('\u0000', '').trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static int _fingerprint(Uint8List bytes) {
    final step = max(1, bytes.length ~/ 64);
    var hash = bytes.length;
    for (var i = 0; i < bytes.length; i += step) {
      hash = (hash * 31 + bytes[i]) & 0x3fffffff;
    }
    return hash;
  }
}
