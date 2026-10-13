import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../utils/cover_color.dart';
import '../widgets/covers.dart';

const _background = Color(0xFF121212);
const _green = Color(0xFF1ED760);
const _subtle = Color(0xFFB3B3B3);

class PlaylistScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final _player = PlayerService.instance;
  final _subscriptions = <StreamSubscription>[];

  Color _accent = const Color(0xFF404040);
  bool _infoLoaded = false;

  /// Playback state, only meaningful while this playlist is the one loaded.
  String? _currentPath;
  bool _playing = false;
  bool _shuffle = false;

  Playlist get _playlist => widget.playlist;

  @override
  void initState() {
    super.initState();
    MetadataService.loadInfo(_playlist.tracks).then((_) {
      if (mounted) setState(() => _infoLoaded = true);
    });
    MetadataService.playlistCovers(_playlist).then((covers) async {
      if (covers.isEmpty) return;
      final color = await coverColor(covers.first);
      if (color != null && mounted) setState(() => _accent = color);
    });
    final player = _player.player;
    _subscriptions
      ..add(player.sequenceStateStream.listen((state) {
        final tag = state.currentSource?.tag;
        setState(() {
          _currentPath = tag is Track ? tag.path : null;
          _shuffle = state.shuffleModeEnabled;
        });
      }))
      ..add(player.playingStream.listen((playing) {
        setState(() => _playing = playing);
      }));
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  bool get _isCurrent => _player.isCurrent(_playlist);

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      AppLog.add('player: failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't play this song")),
      );
    }
  }

  void _onPlay() => _run(() => _isCurrent
      ? _player.togglePlayback()
      : _player.play(_playlist, shuffle: false));

  /// Starts shuffled playback; on the playlist already playing it flips
  /// shuffle on or off without interrupting the song.
  void _onShuffle() => _run(() async {
        if (_isCurrent && _playing) {
          await _player.setShuffle(!_shuffle);
        } else {
          await _player.play(_playlist, shuffle: true);
        }
      });

  void _onTrack(int index) => _run(() => _player.play(_playlist,
      shuffle: _isCurrent && _shuffle, startIndex: index));

  @override
  Widget build(BuildContext context) {
    final tracks = _playlist.tracks;
    return Scaffold(
      backgroundColor: _background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) => _buildTrack(tracks[index], index),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final coverSize = (width * 0.62).clamp(160.0, 320.0);
    final current = _isCurrent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_accent, _background],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, top + 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: DecoratedBox(
              decoration: const BoxDecoration(boxShadow: [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ]),
              child: PlaylistCover(playlist: _playlist, size: coverSize),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _summary(),
            style: const TextStyle(color: _subtle, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: 'Shuffle',
                iconSize: 32,
                onPressed: _onShuffle,
                icon: Icon(
                  Icons.shuffle,
                  color: current && _shuffle ? _green : _subtle,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox.square(
                dimension: 56,
                child: IconButton.filled(
                  tooltip: current && _playing ? 'Pause' : 'Play',
                  style: IconButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.black,
                  ),
                  iconSize: 32,
                  onPressed: _onPlay,
                  icon: Icon(current && _playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _summary() {
    final count = _playlist.tracks.length;
    final songs = '$count ${count == 1 ? 'song' : 'songs'}';
    if (!_infoLoaded) return songs;
    var total = Duration.zero;
    for (final track in _playlist.tracks) {
      total += MetadataService.cachedInfo(track)?.duration ?? Duration.zero;
    }
    if (total == Duration.zero) return songs;
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    final length = hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
    return '$songs • $length';
  }

  Widget _buildTrack(Track track, int index) {
    final info = MetadataService.cachedInfo(track);
    final isPlaying = _isCurrent && track.path == _currentPath;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: TrackCover(track: track),
      title: Text(
        info?.title ?? track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isPlaying ? _green : Colors.white,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        info?.artist ?? 'Unknown artist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: _subtle, fontSize: 14),
      ),
      trailing: isPlaying && _playing
          ? const Icon(Icons.graphic_eq, color: _green)
          : null,
      onTap: () => _onTrack(index),
    );
  }
}
