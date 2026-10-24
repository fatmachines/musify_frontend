import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/playlist.dart';

/// Tags read from an audio file. Any field can be missing: plenty of files
/// carry no tags at all.
class TrackInfo {
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;
  final String? lyrics;

  const TrackInfo({
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.lyrics,
  });

  static const empty = TrackInfo();
}

/// Reads tags and embedded cover art off the UI isolate and caches them
/// until the file changes (see [forgetChanged]).
class MetadataService {
  static final _info = <String, TrackInfo>{};

  /// Each read file's modified time and size when it was read.
  static final _stamps = <String, (int, int)>{};
  static final _covers = <String, Future<Uint8List?>>{};
  static final _playlistCovers = <String, Future<List<Uint8List>>>{};

  // Results already in, so widgets can show them on their first frame
  // instead of starting blank while a finished future is awaited.
  static final _loadedCovers = <String, Uint8List?>{};
  static final _loadedPlaylistCovers = <String, List<Uint8List>>{};

  /// The song's cover if it has been read (null if not yet, or none).
  static Uint8List? loadedCover(Track track) => _loadedCovers[track.path];

  /// The playlist's mosaic covers if already picked.
  static List<Uint8List>? loadedPlaylistCovers(Playlist playlist) =>
      _loadedPlaylistCovers[_playlistKey(playlist)];

  // Keyed on length too: a user's playlist changes as songs are added.
  static String _playlistKey(Playlist playlist) =>
      '${playlist.id}#${playlist.tracks.length}';

  static TrackInfo? cachedInfo(Track track) => track is YouTubeTrack
      ? TrackInfo(
          title: track.name,
          artist: track.channel,
          album: track.album,
          duration: track.length,
        )
      : _info[track.path];

  /// Tags (no artwork) for every track not read yet.
  static Future<void> loadInfo(List<Track> tracks) async {
    final missing = [
      for (final t in tracks)
        if (t is! YouTubeTrack && !_info.containsKey(t.path)) t.path,
    ];
    if (missing.isEmpty) return;
    final read = await Isolate.run(
      () => {for (final path in missing) path: (_readInfo(path), _stamp(path))},
    );
    for (final MapEntry(key: path, value: (info, stamp)) in read.entries) {
      _info[path] = info;
      if (stamp != null) _stamps[path] = stamp;
    }
  }

  static (int, int)? _stamp(String path) {
    try {
      final stat = File(path).statSync();
      return (stat.modified.millisecondsSinceEpoch, stat.size);
    } catch (_) {
      return null;
    }
  }

  /// Drops what was read from files changed since (re-tagged in another
  /// app, or replaced), so they're read again; the library calls this on
  /// every rescan. Returns the paths dropped.
  static Future<List<String>> forgetChanged() async {
    final stamps = Map.of(_stamps);
    if (stamps.isEmpty) return const [];
    final changed = await Isolate.run(
      () => [
        for (final MapEntry(key: path, value: stamp) in stamps.entries)
          if (_stamp(path) != stamp) path,
      ],
    );
    for (final path in changed) {
      _info.remove(path);
      _stamps.remove(path);
      _covers.remove(path);
      _loadedCovers.remove(path);
    }
    if (changed.isNotEmpty) {
      // Mosaics are picked again from the songs' covers as they are now.
      _playlistCovers.clear();
      _loadedPlaylistCovers.clear();
    }
    return changed;
  }

  static Future<Uint8List?> cover(Track track) {
    return _covers.putIfAbsent(track.path, () async {
      final bytes = track is YouTubeTrack
          ? await _download(track.thumbnail)
          : await Isolate.run(() => _readCover(track.path));
      _loadedCovers[track.path] = bytes;
      return bytes;
    });
  }

  /// Up to four different covers from random songs in [playlist], for the
  /// Spotify-style mosaic. Picked once per playlist per app run.
  static Future<List<Uint8List>> playlistCovers(Playlist playlist) {
    final key = _playlistKey(playlist);
    final artwork = playlist.artworkUrl;
    if (artwork != null) {
      // Its own picture (a YouTube Music artist's).
      return _playlistCovers.putIfAbsent(key, () async {
        final bytes = await _download(artwork);
        final covers = [?bytes];
        _loadedPlaylistCovers[key] = covers;
        return covers;
      });
    }
    return _playlistCovers.putIfAbsent(key, () async {
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
      _loadedPlaylistCovers[key] = covers;
      return covers;
    });
  }

  static final _images = <String, Future<Uint8List?>>{};
  static final _loadedImages = <String, Uint8List?>{};

  /// A picture from the web (e.g. an artist's), fetched once per run.
  static Future<Uint8List?> image(String url) =>
      _images.putIfAbsent(url, () async {
        final bytes = await _download(url);
        _loadedImages[url] = bytes;
        return bytes;
      });

  static Uint8List? loadedImage(String url) => _loadedImages[url];

  /// Gives [track] (a YouTube song) or the picture at [url] these bytes
  /// instead of fetching them, for tests and screenshots.
  @visibleForTesting
  static void debugArtwork({Track? track, String? url, Uint8List? bytes}) {
    if (track != null) {
      _covers[track.path] = Future.value(bytes);
      _loadedCovers[track.path] = bytes;
    }
    if (url != null) {
      _images[url] = Future.value(bytes);
      _loadedImages[url] = bytes;
    }
  }

  /// A YouTube thumbnail, or null if there's none or it can't be fetched.
  static Future<Uint8List?> _download(String? url) async {
    if (url == null) return null;
    try {
      final response = await http.get(Uri.parse(url));
      return response.statusCode == 200 ? response.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  static TrackInfo _readInfo(String path) {
    try {
      final m = readMetadata(File(path));
      return TrackInfo(
        title: _clean(m.title),
        artist: _clean(m.artist),
        album: _clean(m.album),
        duration: m.duration,
        lyrics: _clean(m.lyrics),
      );
    } catch (_) {
      return TrackInfo.empty;
    }
  }

  /// The song's embedded cover, or else its folder's picture (cover.jpg
  /// and the like, as ripped albums have).
  static Uint8List? _readCover(String path) {
    try {
      final pictures = readMetadata(File(path), getImage: true).pictures;
      if (pictures.isNotEmpty) {
        final front = pictures.firstWhere(
          (p) => p.pictureType == PictureType.coverFront,
          orElse: () => pictures.first,
        );
        return front.bytes;
      }
    } catch (_) {
      // No tags it can read: the folder's picture may still do.
    }
    return _folderCover(File(path).parent);
  }

  static const _folderCoverNames = ['cover', 'folder', 'front', 'album'];

  static Uint8List? _folderCover(Directory dir) {
    try {
      final images = <String, File>{
        for (final entry in dir.listSync(followLinks: false))
          if (entry is File &&
              RegExp(
                r'\.(jpe?g|png)$',
                caseSensitive: false,
              ).hasMatch(entry.path))
            _baseName(entry.path).toLowerCase(): entry,
      };
      for (final name in _folderCoverNames) {
        if (images[name] case final file?) return file.readAsBytesSync();
      }
      // Windows Media Player's "AlbumArt_{…}_Large.jpg".
      for (final MapEntry(:key, :value) in images.entries) {
        if (key.startsWith('albumart') && key.endsWith('large')) {
          return value.readAsBytesSync();
        }
      }
    } catch (_) {}
    return null;
  }

  static String _baseName(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
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
