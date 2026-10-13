import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/covers.dart';
import '../widgets/offline_badge.dart';
import '../widgets/playlist_actions.dart';
import '../widgets/toast.dart';

const _searchDuration = Duration(milliseconds: 220);
const _findBarHeight = 38.0;

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
  final _searchFocus = FocusNode();
  final _playKey = GlobalKey();

  Color _accent = const Color(0xFF535353);
  bool _infoLoaded = false;

  /// Scroll position, driving the header's fade, shrink and title bar.
  double _offset = 0;

  /// Whether the play button has scrolled up to the title bar and is shown
  /// pinned on the bar's bottom edge instead.
  bool _pinPlay = false;

  bool _searching = false;

  /// Playback state, only meaningful while this playlist is the one loaded.
  String? _currentPath;
  bool _playing = false;
  bool get _shuffle => _player.shuffleOn.value;

  /// The latest version from the library: the user's playlists change as
  /// songs are added, removed or the playlist is renamed.
  Playlist get _playlist =>
      Library.instance.byId(widget.playlist.id) ?? widget.playlist;

  @override
  void initState() {
    super.initState();
    _loadDetails();
    Library.instance.addListener(_onLibraryChanged);
    _player.shuffleOn.addListener(_onShuffleChanged);
    _scroll.addListener(_onScroll);
    _query.addListener(() => setState(() {}));
    final player = _player.player;
    _subscriptions
      ..add(
        player.sequenceStateStream.listen((state) {
          final tag = state.currentSource?.tag;
          setState(() {
            _currentPath = tag is Track ? tag.path : null;
          });
        }),
      )
      ..add(
        player.playingStream.listen((playing) {
          setState(() => _playing = playing);
        }),
      );
  }

  void _loadDetails() {
    MetadataService.loadInfo(_playlist.tracks).then((_) {
      if (mounted) setState(() => _infoLoaded = true);
    });
    MetadataService.playlistCovers(_playlist).then((covers) async {
      if (covers.isEmpty) return;
      final color = await coverColor(covers.first);
      if (color != null && mounted) setState(() => _accent = color);
    });
  }

  void _onShuffleChanged() {
    if (mounted) setState(() {});
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    if (!Library.instance.scanning &&
        Library.instance.byId(widget.playlist.id) == null) {
      // Deleted or hidden.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
    _loadDetails();
  }

  @override
  void dispose() {
    Library.instance.removeListener(_onLibraryChanged);
    _player.shuffleOn.removeListener(_onShuffleChanged);
    for (final s in _subscriptions) {
      s.cancel();
    }
    _scroll.dispose();
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  double get _barBottom => MediaQuery.paddingOf(context).top + kToolbarHeight;

  void _onScroll() {
    var pin = false;
    final box = _playKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.attached) {
      final center = box.localToGlobal(box.size.center(Offset.zero)).dy;
      pin = center <= _barBottom;
    }
    setState(() {
      _offset = _scroll.offset;
      _pinPlay = pin;
    });
  }

  double _coverSize(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.6).clamp(160.0, 300.0);

  /// 0 while the playlist name is below the title bar, 1 once it has
  /// scrolled under it.
  double get _collapse {
    final start = _coverSize(context) * 0.8;
    return ((_offset - start) / 70).clamp(0.0, 1.0);
  }

  bool get _isCurrent => _player.isCurrent(_playlist);

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      AppLog.add('player: failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Couldn't play this song")));
    }
  }

  void _onPlay() => _run(
    () => _isCurrent
        ? _player.togglePlayback()
        : _player.play(_playlist, shuffle: false),
  );

  /// Starts shuffled playback; on the playlist already playing it flips
  /// shuffle on or off without interrupting the song.
  void _onShuffle() => _run(() async {
    if (_isCurrent && _playing) {
      await _player.setShuffle(!_shuffle);
    } else {
      await _player.play(_playlist, shuffle: true);
    }
  });

  void _onTrack(int index) => _run(
    () => _player.play(
      _playlist,
      shuffle: _isCurrent && _shuffle,
      startIndex: index,
    ),
  );

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    _query.clear();
    setState(() => _searching = false);
  }

  /// Indexes into the playlist of the songs matching the search.
  List<int> _matches() {
    final q = _query.text.trim().toLowerCase();
    final all = List.generate(_playlist.tracks.length, (i) => i);
    if (q.isEmpty) return all;
    return all.where((i) {
      final track = _playlist.tracks[i];
      final info = MetadataService.cachedInfo(track);
      return [
        track.title,
        info?.title,
        info?.artist,
        info?.album,
      ].any((s) => s != null && s.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: Scaffold(
        body: Stack(
          children: [
            _buildPage(context),
            IgnorePointer(
              ignoring: !_searching,
              child: AnimatedOpacity(
                duration: _searchDuration,
                curve: Curves.easeOut,
                opacity: _searching ? 1 : 0,
                child: _buildSearch(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final tracks = _playlist.tracks;
    final barColor = Color.lerp(_accent, Colors.black, 0.4)!;
    final collapse = _collapse;
    return Stack(
      children: [
        CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(context)),
            if (tracks.isEmpty)
              const SliverToBoxAdapter(child: _EmptyPlaylist()),
            SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, i) => _buildTrack(i),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 24,
              ),
            ),
          ],
        ),
        // Title bar: clear over the header, filling with the cover colour as
        // the playlist name scrolls under it.
        Container(
          height: _barBottom,
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          color: barColor.withValues(alpha: collapse),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_ios_new, size: 22),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Opacity(
                  opacity: collapse,
                  child: Text(
                    _playlist.name,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Playlist options',
                icon: const Icon(Icons.more_horiz),
                onPressed: () => showPlaylistActions(context, _playlist),
              ),
            ],
          ),
        ),
        if (_pinPlay)
          Positioned(
            top: _barBottom - 28,
            right: 16,
            child: _PlayButton(playing: _isCurrent && _playing, onTap: _onPlay),
          ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final current = _isCurrent;
    final coverSize = _coverSize(context);

    // The find bar scrolls away first. The cover then sticks just under the
    // title bar, shrinking and fading, while the name and buttons slide up
    // over it.
    const coverTop = _findBarHeight + 4 + 24;
    final o = _offset.clamp(0.0, double.infinity);
    final coverProgress = (o / (coverSize * 0.85 + coverTop)).clamp(0.0, 1.0);
    final findOpacity = (1 - o / 40).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_accent, AppColors.background],
          stops: const [0, 0.85],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, _barBottom + 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Opacity(
            opacity: findOpacity,
            child: _FindBar(onTap: _openSearch),
          ),
          const SizedBox(height: 24),
          Center(
            child: Transform.translate(
              offset: Offset(0, (o - coverTop).clamp(0.0, double.infinity)),
              child: Transform.scale(
                alignment: Alignment.topCenter,
                scale: 1 - 0.3 * coverProgress,
                child: Opacity(
                  opacity: (1 - coverProgress * 1.1).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x80000000),
                          blurRadius: 40,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: PlaylistCover(playlist: _playlist, size: coverSize),
                  ),
                ),
              ),
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
          // Who and how much on the left, shuffle and play beside it.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: AppColors.green,
                          child: Icon(
                            Icons.music_note,
                            size: 15,
                            color: Colors.black,
                          ),
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
                        const Icon(
                          Icons.phone_iphone,
                          size: 16,
                          color: AppColors.subtle,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _summary(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.subtle,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _ShuffleButton(active: current && _shuffle, onTap: _onShuffle),
              const SizedBox(width: 16),
              Opacity(
                opacity: _pinPlay ? 0 : 1,
                child: _PlayButton(
                  key: _playKey,
                  playing: current && _playing,
                  onTap: _onPlay,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSearch(BuildContext context) {
    final matches = _matches();
    final query = _query.text.trim();
    return ColoredBox(
      color: AppColors.background,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: AnimatedSlide(
              duration: _searchDuration,
              curve: Curves.easeOut,
              // Rises from where the find bar sat in the header.
              offset: _searching ? Offset.zero : const Offset(0, 0.6),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _SearchField(
                        controller: _query,
                        focusNode: _searchFocus,
                      ),
                    ),
                    TextButton(
                      onPressed: _closeSearch,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.text,
                        textStyle: const TextStyle(
                          fontFamily: 'Figtree',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      "Couldn't find \"$query\"",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom + 24,
                    ),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: matches.length,
                    itemBuilder: (context, i) => _buildTrack(matches[i]),
                  ),
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
                        const Icon(
                          Icons.graphic_eq,
                          size: 14,
                          color: AppColors.green,
                        ),
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
                            color: AppColors.subtle,
                            fontSize: 14,
                          ),
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
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        // Sized to its content, scrolling on screens too short for it.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: TrackCover(track: track, size: 48),
                title: Text(
                  info?.title ?? track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play next'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _player.playNext(track);
                  showToast(context, 'Playing next');
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _player.addToQueue(track);
                  showToast(context, 'Added to queue');
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showAddToPlaylist(context, track);
                },
              ),
              if (_playlist.isCustom)
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline),
                  title: const Text('Remove from this playlist'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Library.instance.removeTrack(_playlist, track);
                    showToast(context, 'Removed from ${_playlist.name}');
                  },
                ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('File'),
                subtitle: Text(
                  '${track.title}.${track.extension.toLowerCase()}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The header's "Find on this page" bar. Tapping it opens search.
class _FindBar extends StatelessWidget {
  final VoidCallback onTap;

  const _FindBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: _findBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Row(
          children: [
            Icon(Icons.search, size: 22, color: AppColors.text),
            SizedBox(width: 8),
            Text(
              'Find on this page',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  const _SearchField({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.chip,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 22, color: AppColors.subtle),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              cursorColor: AppColors.green,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: AppColors.text, fontSize: 14),
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Find on this page',
                hintStyle: TextStyle(color: AppColors.subtle, fontSize: 14),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: controller.clear,
              child: const Icon(Icons.close, size: 20, color: AppColors.subtle),
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

  const _PlayButton({super.key, required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: Material(
        color: AppColors.green,
        shape: const CircleBorder(),
        elevation: 4,
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

class _EmptyPlaylist extends StatelessWidget {
  const _EmptyPlaylist();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        children: [
          Text(
            "Let's start building your playlist",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 8),
          Text(
            'While a song plays, open ••• in the player and choose '
            '"Add to playlist". Song menus in your folders have it too.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
