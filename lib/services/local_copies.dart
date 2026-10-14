import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'library.dart';
import 'library_store.dart';
import 'metadata_service.dart';

/// Finds a YouTube song's copy on the device, so it plays from the file
/// instead of streaming: the one downloaded with Musify (remembered by
/// video id), or a song already in the library with the same title, by
/// the same artist or of the same length. An artist's 150 songs with 10 on
/// the device play those 10 from their files and the rest from YouTube.
class LocalCopies extends ChangeNotifier {
  LocalCopies._();

  static final instance = LocalCopies._();

  static const _downloadedKey = 'downloaded_videos_v1';

  /// Songs downloaded with Musify, by video id.
  Map<String, SavedTrack> _downloaded = {};

  /// The library's songs by path, and by every way their title can be
  /// written (see [_titles]).
  Map<String, Track> _byPath = {};
  Map<String, List<Track>> _byTitle = {};

  /// Answers so far, by video id (null: not on the device). Cleared
  /// whenever the library changes.
  final _found = <String, Track?>{};

  bool _started = false;
  Timer? _soon;

  /// Reads what was downloaded and follows the library from now on.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final raw = (await SharedPreferences.getInstance()).getString(
      _downloadedKey,
    );
    if (raw != null) {
      _downloaded = {
        for (final MapEntry(:key, :value)
            in (jsonDecode(raw) as Map<String, dynamic>).entries)
          key: SavedTrack.fromJson((value as Map).cast()),
      };
    }
    Library.instance.addListener(_libraryChanged);
    await _index();
  }

  void _libraryChanged() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 500), _index);
  }

  /// Notes that [track] was saved as [path], for good.
  Future<void> remember(YouTubeTrack track, String path) async {
    _downloaded[track.videoId] = Library.instance.saveForm(Track(path));
    _found.remove(track.videoId);
    await (await SharedPreferences.getInstance()).setString(
      _downloadedKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in _downloaded.entries)
          key: value.toJson(),
      }),
    );
  }

  Future<void> _index() async {
    final songs = Library.instance.allSongs;
    await MetadataService.loadInfo(songs);
    _build(songs, MetadataService.cachedInfo);
  }

  /// Indexes [songs] alone, with [info] as their tags, for tests.
  @visibleForTesting
  void debugIndex(List<Track> songs, Map<String, TrackInfo> info) =>
      _build(songs, (song) => info[song.path]);

  TrackInfo? Function(Track) _infoOf = MetadataService.cachedInfo;

  void _build(List<Track> songs, TrackInfo? Function(Track) infoOf) {
    _infoOf = infoOf;
    final byTitle = <String, List<Track>>{};
    for (final song in songs) {
      final info = infoOf(song);
      final artists = {
        ..._artists(info?.artist),
        ..._artists(_fileArtist(song.title)),
      };
      for (final title in _withoutArtist({
        if (info?.title != null) ..._titles(info!.title!),
        ..._titles(_fileTitle(song.title)),
      }, artists)) {
        (byTitle[title] ??= []).add(song);
      }
    }
    _byPath = {for (final song in songs) song.path: song};
    _byTitle = byTitle;
    _found.clear();
    notifyListeners();
  }

  /// [track]'s copy on the device, or null.
  Track? copyOf(YouTubeTrack track) =>
      _found.putIfAbsent(track.videoId, () => _find(track));

  /// What to play for [track]: its file if it's on the device, else
  /// itself. Queued songs stay queued.
  Track resolve(Track track) {
    if (track is! YouTubeTrack) return track;
    final copy = copyOf(track);
    if (copy == null) return track;
    return track is QueuedTrack ? QueuedTrack(copy.path) : copy;
  }

  /// Whether [a] and [b] are the same song, one maybe [b]'s copy.
  bool same(Track a, Track b) =>
      a.path == b.path || resolve(a).path == resolve(b).path;

  Track? _find(YouTubeTrack track) {
    final saved = _downloaded[track.videoId];
    if (saved != null) {
      final path = Library.instance.resolve(saved);
      final song = path == null ? null : _byPath[path];
      if (song != null) return song;
    }
    final artists = _artists(track.channel);
    final length = track.length;
    Track? best;
    var bestScore = 0;
    for (final title in _withoutArtist(_titles(track.name), artists)) {
      for (final song in _byTitle[title] ?? const <Track>[]) {
        final info = _infoOf(song);
        final duration = info?.duration;
        final off = length == null || duration == null
            ? null
            : (length - duration).abs();
        // A live take or a remix of the same name.
        if (off != null && off > const Duration(seconds: 20)) continue;
        final byArtist = {
          ..._artists(info?.artist),
          ..._artists(_fileArtist(song.title)),
        }.any((a) => artists.any((b) => _sameArtist(a, b)));
        final sameLength = off != null && off <= const Duration(seconds: 3);
        // A label's channel often posts the song: then its length has to
        // tell.
        final score = (byArtist ? 2 : 0) + (sameLength ? 1 : 0);
        if (score > bestScore) {
          best = song;
          bestScore = score;
        }
      }
    }
    return best;
  }

  // Comparing names ----------------------------------------------------------

  static final _brackets = RegExp(r'[(\[{【][^)\]}】]*[)\]}】]');
  static final _featuring = RegExp(r'\s(feat|ft|featuring)\.?\s.*$');
  static final _noise = RegExp(
    r'\b(official( music| lyric(al)?)? (video|audio)|lyric(al)? video|'
    r'lyrics?|video song|full (video )?song|audio|visuali[sz]er|hd|4k|mv)\b',
  );
  static final _notLetters = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// [raw] lowercased with what YouTube titles add taken off:
  /// "(Official Video)", "[HD]", "feat. ...", punctuation.
  @visibleForTesting
  static String norm(String raw) {
    final s = raw
        .toLowerCase()
        .replaceAll(_brackets, ' ')
        .replaceAll(_featuring, ' ')
        .replaceAll(_noise, ' ')
        .replaceAll(_notLetters, ' ')
        .trim();
    return s.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// The ways [title] may name the song: as it is, the part before
  /// "Title | Film | Singer"'s first bar, and each side of "Artist - Title".
  @visibleForTesting
  static Set<String> titles(String title) => _titles(title);

  static Set<String> _titles(String title) {
    final first = title.split('|').first;
    return {
      norm(title),
      norm(first),
      for (final part in first.split(RegExp(r'\s[-–—]\s'))) norm(part),
    }..removeWhere((t) => t.isEmpty);
  }

  /// [titles] but the artist's name: "Michael Jackson - Thriller" isn't
  /// called "Michael Jackson".
  static Iterable<String> _withoutArtist(
    Set<String> titles,
    Set<String> artists,
  ) {
    String bare(String s) => s.replaceAll(' ', '');
    final names = artists.map(bare).toSet();
    return titles.where((t) => !names.contains(bare(t)));
  }

  /// A file name without its track number ("01 - Song").
  static String _fileTitle(String name) =>
      name.replaceFirst(RegExp(r'^\d{1,3}[\s.\-_]+'), '');

  /// "Artist" from a file named "Artist - Song".
  static String? _fileArtist(String name) {
    final dash = _fileTitle(name).indexOf(' - ');
    return dash > 0 ? _fileTitle(name).substring(0, dash) : null;
  }

  static Set<String> _artists(String? raw) {
    if (raw == null) return const {};
    final cleaned = raw
        .toLowerCase()
        .replaceAll(RegExp(r'\s-\stopic$'), '')
        .replaceAll(RegExp(r'vevo$'), '');
    return {
      for (final name in cleaned.split(
        RegExp(r',|&|/|;|\sx\s|\sand\s|\sfeat\.?\s|\sft\.?\s'),
      ))
        if (norm(name).isNotEmpty) norm(name),
    };
  }

  /// Spaces aside ("MichaelJacksonVEVO"), one name in the other ("Arijit
  /// Singh" in "Arijit Singh Official").
  static bool _sameArtist(String a, String b) {
    a = a.replaceAll(' ', '');
    b = b.replaceAll(' ', '');
    return a == b ||
        (a.length >= 3 && b.length >= 3 && (a.contains(b) || b.contains(a)));
  }
}
