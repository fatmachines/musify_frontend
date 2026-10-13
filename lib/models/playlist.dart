import 'package:path/path.dart' as p;

class Track {
  final String path;

  const Track(this.path);

  String get title => p.basenameWithoutExtension(path);

  String get extension => p.extension(path).replaceFirst('.', '').toUpperCase();
}

/// A folder that directly contains audio files. Nested folders become their
/// own playlists rather than being merged into their parent.
class Playlist {
  final String path;

  /// Path relative to the chosen library root; '.' for the root itself.
  final String relativePath;
  final List<Track> tracks;

  const Playlist({
    required this.path,
    required this.relativePath,
    required this.tracks,
  });

  String get name => p.basename(path);
}
