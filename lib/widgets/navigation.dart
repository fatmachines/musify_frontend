import 'package:flutter/material.dart';

import '../models/playlist.dart';
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

Future<void> openPlaylist(BuildContext context, Playlist playlist) =>
    openPage(context, PlaylistScreen(playlist: playlist));
