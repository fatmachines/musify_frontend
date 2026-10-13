// just_audio marks StreamAudioSource experimental; it's the supported way
// to feed it bytes from code.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../models/playlist.dart';
import '../app_log.dart';

/// YouTube search and audio, through youtube_explode (no API key, no
/// quota). Audio is the AAC stream (M4A), which iOS and Android play
/// natively; it's fetched with plain HTTP range requests, so playback can
/// seek and downloads can be resumed in chunks.
class YouTubeMedia {
  YouTubeMedia._();

  static final instance = YouTubeMedia._();

  final _yt = YoutubeExplode();
  final _http = HttpClient();
  final _streams = <String, Future<_Audio>>{};

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

  /// The audio stream for [videoId]. Stream links expire after a few hours,
  /// so they are cached for less than that.
  Future<_Audio> _audio(String videoId, {bool fresh = false}) {
    final cached = _streams[videoId];
    if (!fresh && cached != null) return cached;
    final future = () async {
      final manifest = await _yt.videos.streams.getManifest(videoId);
      final aac = manifest.audioOnly.where(
        (s) => s.container == StreamContainer.mp4,
      );
      final stream = aac.isNotEmpty
          ? aac.withHighestBitrate()
          : manifest.audioOnly.withHighestBitrate();
      return _Audio(stream.url, stream.size.totalBytes, DateTime.now());
    }();
    _streams[videoId] = future;
    future.then(
      (audio) {
        // Drop it well before YouTube's link expires.
        Timer(const Duration(hours: 3), () {
          if (_streams[videoId] == future) _streams.remove(videoId);
        });
      },
      onError: (_) {
        _streams.remove(videoId);
      },
    );
    return future;
  }

  Future<int> sizeOf(String videoId) async => (await _audio(videoId)).size;

  /// Bytes [start] to [end] (exclusive) of the song's audio, in chunks.
  Stream<List<int>> bytes(String videoId, int start, int end) async* {
    const chunk = 1 << 20;
    var audio = await _audio(videoId);
    var from = start;
    var retried = false;
    while (from < end) {
      final to = min(from + chunk, end) - 1;
      final request = await _http.getUrl(audio.url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      final response = await request.close();
      if (response.statusCode == HttpStatus.forbidden && !retried) {
        // The link expired: get a new one and carry on from here.
        await response.drain<void>();
        retried = true;
        audio = await _audio(videoId, fresh: true);
        continue;
      }
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('YouTube answered ${response.statusCode}');
      }
      retried = false;
      await for (final data in response) {
        from += data.length;
        yield data;
      }
    }
  }
}

class _Audio {
  final Uri url;
  final int size;
  final DateTime fetched;

  _Audio(this.url, this.size, this.fetched);
}

/// A YouTube song for just_audio, streamed on demand (and from any point,
/// so seeking works) through just_audio's local proxy.
class YouTubeAudioSource extends StreamAudioSource {
  final YouTubeTrack track;

  YouTubeAudioSource(this.track) : super(tag: track);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final media = YouTubeMedia.instance;
    try {
      final size = await media.sizeOf(track.videoId);
      final from = start ?? 0;
      final to = end ?? size;
      return StreamAudioResponse(
        sourceLength: size,
        contentLength: to - from,
        offset: from,
        stream: media.bytes(track.videoId, from, to),
        contentType: 'audio/mp4',
      );
    } catch (e) {
      AppLog.add('youtube: ${track.videoId} failed: $e');
      rethrow;
    }
  }
}
