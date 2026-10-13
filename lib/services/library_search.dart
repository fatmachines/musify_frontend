import '../models/playlist.dart';
import 'library.dart';
import 'metadata_service.dart';

/// Finding songs and playlists by name, shared by the Search tab and voice
/// requests (Siri, Google Assistant, Android Auto).
///
/// Every word of the query has to appear in the song's title, artist, album
/// or file name; titles that are the query, then start with it, then
/// contain it, come first. Tags are only matched once read, so call
/// [MetadataService.loadInfo] on [Library.allSongs] first for artists and
/// albums.
class LibrarySearch {
  static List<String> words(String query) => query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  static List<Playlist> playlists(String query) {
    final q = words(query);
    if (q.isEmpty) return const [];
    final phrase = q.join(' ');
    final found = [
      for (final playlist in Library.instance.all)
        if (q.every(playlist.name.toLowerCase().contains)) playlist,
    ];
    // An exact name first.
    found.sort(
      (a, b) =>
          (a.name.toLowerCase() == phrase ? 0 : 1) -
          (b.name.toLowerCase() == phrase ? 0 : 1),
    );
    return found;
  }

  static List<Track> songs(String query, {String? artist}) {
    final q = words(query);
    final by = words(artist ?? '');
    if (q.isEmpty && by.isEmpty) return const [];
    final phrase = q.join(' ');
    final scored = <(int, String, Track)>[];
    for (final track in Library.instance.allSongs) {
      final info = MetadataService.cachedInfo(track);
      final title = (info?.title ?? track.title).toLowerCase();
      final artistName = info?.artist?.toLowerCase() ?? '';
      final haystack = [
        title,
        track.title.toLowerCase(),
        artistName,
        info?.album?.toLowerCase(),
      ].whereType<String>().join(' ');
      if (!q.every(haystack.contains)) continue;
      if (!by.every(artistName.contains)) continue;
      final rank = phrase.isEmpty
          ? 3
          : title == phrase
          ? 0
          : title.startsWith(phrase)
          ? 1
          : title.contains(phrase)
          ? 2
          : 3;
      scored.add((rank, title, track));
    }
    scored.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2.compareTo(b.$2));
    return [for (final s in scored) s.$3];
  }

  /// Songs whose artist matches [artist], for "play Arijit Singh".
  static List<Track> byArtist(String artist) => songs('', artist: artist);
}
