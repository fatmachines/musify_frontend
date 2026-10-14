import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/artist_page.dart';
import '../screens/playlist_screen.dart';

/// Present in the wide (desktop) layout: where pages open, so a playlist
/// tapped in the library sidebar shows in the main panel.
class DesktopScope extends InheritedWidget {
  final GlobalKey<NavigatorState> main;

  const DesktopScope({super.key, required this.main, required super.child});

  static DesktopScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DesktopScope>();

  /// Whether [context] is in the desktop layout.
  static bool of(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(DesktopScope old) => old.main != main;
}

/// Opens [page]: in the main panel on the desktop layout, else on the
/// nearest navigator (the tab's own).
Future<T?> openPage<T>(BuildContext context, Widget page) {
  final navigator =
      DesktopScope.maybeOf(context)?.main.currentState ?? Navigator.of(context);
  return navigator.push<T>(MaterialPageRoute(builder: (_) => page));
}

/// Opens [playlist]'s page. A pinned artist or album (no songs yet) opens
/// its page, which loads them.
Future<void> openPlaylist(BuildContext context, Playlist playlist) {
  const artist = 'youtube:artist:', album = 'youtube:album:';
  final id = playlist.id;
  if (playlist.tracks.isEmpty && id.startsWith(artist)) {
    return openPage(
      context,
      ArtistPage(
        artist: YouTubeArtist(
          id: id.substring(artist.length),
          name: playlist.name,
          thumbnail: playlist.artworkUrl,
        ),
      ),
    );
  }
  if (playlist.tracks.isEmpty && id.startsWith(album)) {
    return openPage(
      context,
      AlbumPage(
        album: YouTubeAlbum(
          id: id.substring(album.length),
          title: playlist.name,
          thumbnail: playlist.artworkUrl,
        ),
      ),
    );
  }
  return openPage(context, PlaylistScreen(playlist: playlist));
}

/// Cmd+F / Ctrl+F: the page that can search itself (a playlist's "Find on
/// this page") takes it; asked in turn, the one on top first.
class FindShortcut {
  FindShortcut._();

  static final _pages = <bool Function()>[];

  /// [find] opens the page's search if the page is the one showing, and
  /// says whether it did.
  static void register(bool Function() find) => _pages.add(find);

  static void unregister(bool Function() find) => _pages.remove(find);

  /// Whether a page took it.
  static bool find() {
    for (final page in _pages.reversed) {
      if (page()) return true;
    }
    return false;
  }
}
