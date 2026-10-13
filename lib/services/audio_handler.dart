import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'cover_files.dart';
import 'library.dart';
import 'metadata_service.dart';
import 'player_service.dart';

const _playlistPrefix = 'playlist:';

/// Connects [PlayerService] to the operating system: background playback,
/// the lock screen, Control Center and the Android notification, headset
/// buttons, CarPlay's Now Playing screen, and Android Auto (which can also
/// browse playlists and search).
class MusifyAudioHandler extends BaseAudioHandler with SeekHandler {
  final _service = PlayerService.instance;

  AudioPlayer get _player => _service.player;

  MusifyAudioHandler() {
    _player.playbackEventStream.listen(
      (_) => _broadcastState(),
      onError: (Object e) => AppLog.add('player: playback error: $e'),
    );
    _player.playingStream.listen((_) => _broadcastState());
    _service.shuffleOn.addListener(_broadcastState);
    _player.loopModeStream.listen((_) => _broadcastState());
    _player.durationStream.listen((duration) {
      final item = mediaItem.value;
      if (item != null && duration != null && item.duration != duration) {
        mediaItem.add(item.copyWith(duration: duration));
      }
    });
    _player.sequenceStateStream
        .map((state) => state.sequence)
        .distinct()
        .listen(_publishQueue);
    _service.trackStream.listen(_publishTrack);
  }

  // What the system shows ------------------------------------------------------

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
        shuffleMode: _service.shuffleOn.value
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (_player.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
      ),
    );
  }

  void _publishQueue(List<IndexedAudioSource> sequence) {
    queue.add([
      for (final source in sequence)
        if (source.tag is Track) _item(source.tag as Track),
    ]);
  }

  /// Shows the song right away, then again once its tags and cover art
  /// have been read.
  Future<void> _publishTrack(Track? track) async {
    if (track == null) return;
    mediaItem.add(_item(track));
    await MetadataService.loadInfo([track]);
    final art = await CoverFiles.uriFor(track);
    if (_service.currentTrack?.path != track.path) return;
    mediaItem.add(_item(track, artUri: art));
  }

  MediaItem _item(Track track, {Uri? artUri, Playlist? playlist}) {
    final info = MetadataService.cachedInfo(track);
    final isCurrent = _service.currentTrack?.path == track.path;
    return MediaItem(
      id: track.path,
      title: info?.title ?? track.title,
      artist: info?.artist,
      album: info?.album ?? (playlist ?? _service.current)?.name,
      duration: (isCurrent ? _player.duration : null) ?? info?.duration,
      artUri: artUri,
      playable: true,
    );
  }

  // Controls -------------------------------------------------------------------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _service.next();

  @override
  Future<void> skipToPrevious() => _service.previous();

  @override
  Future<void> skipToQueueItem(int index) =>
      _player.seek(Duration.zero, index: index);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _service.setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _player.setLoopMode(switch (repeatMode) {
        AudioServiceRepeatMode.none => LoopMode.off,
        AudioServiceRepeatMode.one => LoopMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => LoopMode.all,
      });

  // Browsing (Android Auto) ------------------------------------------------------

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.recentRootId) {
      final track = _service.currentTrack;
      return track == null ? const [] : [_item(track)];
    }
    final playlists = await Library.playlists();
    if (parentMediaId == AudioService.browsableRootId) {
      return [
        for (final playlist in playlists)
          MediaItem(
            id: '$_playlistPrefix${playlist.id}',
            title: playlist.name,
            displaySubtitle: '${playlist.tracks.length} songs',
            playable: false,
          ),
      ];
    }
    final playlist = _playlistById(playlists, parentMediaId);
    if (playlist == null) return const [];
    await MetadataService.loadInfo(playlist.tracks);
    return [for (final t in playlist.tracks) _item(t, playlist: playlist)];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final found = _findTrack(await Library.playlists(), mediaId);
    return found == null ? null : _item(found.$1.tracks[found.$2]);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final playlists = await Library.playlists();
    final playlist = _playlistById(playlists, mediaId);
    if (playlist != null) {
      return _service.play(playlist, shuffle: false);
    }
    final found = _findTrack(playlists, mediaId);
    if (found != null) {
      await _service.play(
        found.$1,
        shuffle: _service.shuffleOn.value,
        startIndex: found.$2,
      );
    }
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final results = <MediaItem>[];
    for (final playlist in await Library.playlists()) {
      await MetadataService.loadInfo(playlist.tracks);
      for (final track in playlist.tracks) {
        final info = MetadataService.cachedInfo(track);
        final haystack = [
          track.title,
          info?.title,
          info?.artist,
          info?.album,
        ].whereType<String>().join(' ').toLowerCase();
        if (haystack.contains(q)) results.add(_item(track, playlist: playlist));
      }
    }
    return results;
  }

  /// "Play [song] on Musify": plays the best match, or a playlist whose
  /// name matches.
  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final playlists = await Library.playlists();
    final q = query.trim().toLowerCase();
    final named = playlists.where((p) => p.name.toLowerCase().contains(q));
    if (q.isNotEmpty && named.isNotEmpty) {
      return _service.play(named.first, shuffle: true);
    }
    final results = await search(query);
    if (results.isNotEmpty) return playFromMediaId(results.first.id);
    if (q.isEmpty && playlists.isNotEmpty) {
      return _service.play(playlists.first, shuffle: true);
    }
  }

  static Playlist? _playlistById(List<Playlist> playlists, String id) {
    if (!id.startsWith(_playlistPrefix)) return null;
    final playlistId = id.substring(_playlistPrefix.length);
    for (final playlist in playlists) {
      if (playlist.id == playlistId) return playlist;
    }
    return null;
  }

  static (Playlist, int)? _findTrack(List<Playlist> playlists, String path) {
    for (final playlist in playlists) {
      final index = playlist.tracks.indexWhere((t) => t.path == path);
      if (index >= 0) return (playlist, index);
    }
    return null;
  }
}
