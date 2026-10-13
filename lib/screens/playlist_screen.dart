import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import '../widgets/covers.dart';
import '../widgets/offline_badge.dart';

class PlaylistScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final _player = PlayerService.instance;
  final _subscriptions = <StreamSubscription>[];
  final _scroll = ScrollController();
  final _query = TextEditingController();

  Color _accent = const Color(0xFF535353);
  bool _infoLoaded = false;

  /// How far the header has scrolled under the app bar, 0..1.
  double _collapse = 0;

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
    _scroll.addListener(_onScroll);
    _query.addListener(() => setState(() {}));
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
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The title bar fills in as the playlist name scrolls under it.
    final start = _coverSize(context) * 0.75;
    final t = ((_scroll.offset - start) / 80).clamp(0.0, 1.0);
    if (t != _collapse) setState(() => _collapse = t);
  }

  double _coverSize(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.6).clamp(160.0, 300.0);

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

  /// Indexes into the playlist of the songs matching "Find on this page".
  List<int> _visible() {
    final q = _query.text.trim().toLowerCase();
    final all = List.generate(_playlist.tracks.length, (i) => i);
    if (q.isEmpty) return all;
    return all.where((i) {
      final track = _playlist.tracks[i];
      final info = MetadataService.cachedInfo(track);
      return [track.title, info?.title, info?.artist, info?.album]
          .any((s) => s != null && s.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible();
    final barColor = Color.lerp(_accent, Colors.black, 0.35)!;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: barColor.withValues(alpha: _collapse),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_ios_new, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        centerTitle: true,
        title: Opacity(
          opacity: _collapse,
          child: Text(
            _playlist.name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(child: _buildHeader(context)),
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, i) => _buildTrack(visible[i]),
          ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final current = _isCurrent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_accent, AppColors.background],
          stops: const [0, 0.85],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, top + 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FindBar(controller: _query),
          const SizedBox(height: 24),
          Center(
            child: DecoratedBox(
              decoration: const BoxDecoration(boxShadow: [
                BoxShadow(
                  color: Color(0x80000000),
                  blurRadius: 40,
                  offset: Offset(0, 12),
                ),
              ]),
              child: PlaylistCover(
                  playlist: _playlist, size: _coverSize(context)),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          const Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: AppColors.green,
                child: Icon(Icons.music_note, size: 15, color: Colors.black),
              ),
              SizedBox(width: 8),
              Text(
                'Musify',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.phone_iphone, size: 16, color: AppColors.subtle),
              const SizedBox(width: 6),
              Text(
                _summary(),
                style: const TextStyle(color: AppColors.subtle, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Tooltip(
                message: 'On this device',
                child: OfflineBadge(size: 28),
              ),
              const Spacer(),
              _ShuffleButton(active: current && _shuffle, onTap: _onShuffle),
              const SizedBox(width: 16),
              _PlayButton(playing: current && _playing, onTap: _onPlay),
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

  Widget _buildTrack(int index) {
    final track = _playlist.tracks[index];
    final info = MetadataService.cachedInfo(track);
    final isCurrentTrack = _isCurrent && track.path == _currentPath;
    return InkWell(
      onTap: () => _onTrack(index),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            TrackCover(track: track, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info?.title ?? track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrentTrack ? AppColors.green : AppColors.text,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isCurrentTrack && _playing) ...[
                        const Icon(Icons.graphic_eq,
                            size: 14, color: AppColors.green),
                        const SizedBox(width: 4),
                      ],
                      const OfflineBadge(),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          info?.artist ?? 'Unknown artist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.subtle, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_horiz, color: AppColors.subtle),
              onPressed: () => _showTrackSheet(index),
            ),
          ],
        ),
      ),
    );
  }

  void _showTrackSheet(int index) {
    final track = _playlist.tracks[index];
    final info = MetadataService.cachedInfo(track);
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: TrackCover(track: track, size: 48),
              title: Text(info?.title ?? track.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [info?.artist, info?.album].whereType<String>().join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(color: Colors.white12, height: 16),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Play'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _onTrack(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File'),
              subtitle: Text('${track.title}.${track.extension.toLowerCase()}',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

class _FindBar extends StatelessWidget {
  final TextEditingController controller;

  const _FindBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 22, color: AppColors.text),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              cursorColor: AppColors.green,
              style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Find on this page',
                hintStyle: TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: controller.clear,
              child: const Icon(Icons.close, size: 20, color: AppColors.text),
            ),
        ],
      ),
    );
  }
}

class _ShuffleButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const _ShuffleButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.green : AppColors.subtle;
    return Semantics(
      button: true,
      toggled: active,
      label: 'Shuffle',
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: SizedBox(
          width: 44,
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.shuffle, size: 32, color: color),
              // Spotify marks shuffle-on with a dot under the icon.
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: active ? AppColors.green : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback onTap;

  const _PlayButton({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: Material(
        color: AppColors.green,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 56,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 34,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}
