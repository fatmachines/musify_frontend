import 'package:path/path.dart' as p;

class Track {
  final String path;

  const Track(this.path);

  String get title => p.basenameWithoutExtension(path);

  String get extension => p.extension(path).replaceFirst('.', '').toUpperCase();
}

/// A song the user queued with "Play next" or "Add to queue". It plays once,
/// ahead of the rest of the playlist, then leaves the queue.
class QueuedTrack extends Track {
  const QueuedTrack(super.path);
}

/// Either a folder that directly contains audio files (nested folders become
/// their own playlists rather than being merged into their parent), or a
/// playlist the user made, which can hold songs from any folder.
class Playlist {
  /// Stable identity: the folder's path for a folder playlist,
  /// `custom:<id>` for one the user made.
  final String id;
  final String name;
  final List<Track> tracks;

  /// Where a folder playlist sits inside its library folder ('.' for the
  /// library folder itself). Null for playlists the user made.
  final String? location;

  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.location,
  });

  bool get isCustom => location == null;
}
