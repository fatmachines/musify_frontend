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

/// A song streamed from YouTube. Its [path] is `youtube:<video id>`, which
/// keeps it apart from files everywhere songs are compared by path.
class YouTubeTrack extends Track {
  final String videoId;
  final String name;
  final String? channel;
  final String? thumbnail;
  final Duration? length;

  YouTubeTrack({
    required this.videoId,
    required this.name,
    this.channel,
    this.thumbnail,
    this.length,
  }) : super('youtube:$videoId');

  @override
  String get title => name;

  @override
  String get extension => 'YOUTUBE';

  Map<String, Object?> toJson() => {
    'id': videoId,
    'title': name,
    if (channel != null) 'channel': channel,
    if (thumbnail != null) 'thumbnail': thumbnail,
    if (length != null) 'ms': length!.inMilliseconds,
  };

  static YouTubeTrack fromJson(
    Map<String, Object?> json, {
    bool queued = false,
  }) {
    final length = json['ms'] as int?;
    final make = queued ? QueuedYouTubeTrack.new : YouTubeTrack.new;
    return make(
      videoId: json['id'] as String,
      name: json['title'] as String,
      channel: json['channel'] as String?,
      thumbnail: json['thumbnail'] as String?,
      length: length == null ? null : Duration(milliseconds: length),
    );
  }
}

/// A queued YouTube song: plays once, like [QueuedTrack].
class QueuedYouTubeTrack extends YouTubeTrack implements QueuedTrack {
  QueuedYouTubeTrack({
    required super.videoId,
    required super.name,
    super.channel,
    super.thumbnail,
    super.length,
  });
}

/// [track] as a queued song, keeping what it is.
Track queuedCopy(Track track) => track is YouTubeTrack
    ? QueuedYouTubeTrack(
        videoId: track.videoId,
        name: track.name,
        channel: track.channel,
        thumbnail: track.thumbnail,
        length: track.length,
      )
    : QueuedTrack(track.path);

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

  /// Cover image to show instead of a mosaic (YouTube playlists).
  final String? artworkUrl;

  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.location,
    this.artworkUrl,
  });

  bool get isCustom => location == null;
}
