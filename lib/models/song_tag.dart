import 'dart:ui';

/// A coloured label the user puts on songs, e.g. "To replace" for songs
/// whose file should be swapped for a better version.
class SongTag {
  final String id;
  final String name;
  final Color color;

  const SongTag({required this.id, required this.name, required this.color});
}
