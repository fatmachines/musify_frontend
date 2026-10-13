import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../models/playlist.dart';

/// YouTube search through youtube_explode (no API key, no quota). Playback
/// goes through YouTube's own player instead (see YouTubeWebPlayer).
class YouTubeMedia {
  YouTubeMedia._();

  static final instance = YouTubeMedia._();

  final _yt = YoutubeExplode();

  /// Matching videos, as tracks.
  Future<List<YouTubeTrack>> search(String query) async {
    final results = await _yt.search.search(query);
    return [
      for (final video in results)
        if (!video.isLive)
          YouTubeTrack(
            videoId: video.id.value,
            name: video.title,
            channel: video.author,
            thumbnail: video.thumbnails.highResUrl,
            length: video.duration,
          ),
    ];
  }
}
