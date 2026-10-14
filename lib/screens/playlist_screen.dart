import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import '../widgets/list_scrollbar.dart';
import '../widgets/navigation.dart';
import '../widgets/covers.dart';
import '../widgets/playlist_actions.dart';
import '../widgets/song_menu.dart';
import '../widgets/song_tile.dart';

const _searchDuration = Duration(milliseconds: 220);
const _findBarHeight = 38.0;

class PlaylistScreen extends StatefulWidget {
  final Playlist playlist;

  /// Between the header and the songs, e.g. an artist's albums.
  final Widget? beforeTracks;

  const PlaylistScreen({super.key, required this.playlist, this.beforeTracks});

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

  late Color _accent = widget.playlist.id == Library.likedId
      ? LikedCover.accent
      : const Color(0xFF535353);

  /// Only songs with this tag are listed, when set.
  String? _tagFilter;
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
    FindShortcut.register(_findShortcut);
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
    if (!Library.isRemote(widget.playlist) &&
        !Library.instance.scanning &&
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
    FindShortcut.unregister(_findShortcut);
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

  /// In the desktop layout: Spotify's wide header, the cover beside the
  /// name.
  bool get _wide => DesktopScope.of(context);

  double _coverSize(BuildContext context) => _wide
      ? 220
      : (MediaQuery.sizeOf(context).width * 0.6).clamp(160.0, 300.0);

  /// 0 while the playlist name is below the title bar, 1 once it has
  /// scrolled under it.
  double get _collapse {
    final start = _coverSize(context) * 0.8;
    return ((_offset - start) / 70).clamp(0.0, 1.0);
  }

  bool get _isCurrent => _player.isCurrent(_playlist);

  bool get _isArtist => _playlist.id.startsWith('youtube:artist:');

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

  /// Cmd+F / Ctrl+F: "Find on this page", if this page is the one showing.
  bool _findShortcut() {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    _openSearch();
    return true;
  }

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
    final shown = _tagFiltered();
    final barColor = AppColors.backdrop(_accent, 0.4);
    final collapse = _collapse;
    return Stack(
      children: [
        ListScrollbar(
          controller: _scroll,
          padding: EdgeInsets.only(
            top: _barBottom,
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: _wide
                    ? _buildWideHeader(context)
                    : _buildHeader(context),
              ),
              if (widget.beforeTracks case final extra?)
                SliverToBoxAdapter(child: extra),
              if (tracks.isEmpty)
                SliverToBoxAdapter(
                  child: _EmptyPlaylist(liked: _playlist.id == Library.likedId),
                ),
              SliverList.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => _buildTrack(shown[i]),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.paddingOf(context).bottom + 24,
                ),
              ),
            ],
          ),
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
              // Balances the back button; options sit by the name below.
              const SizedBox(width: 48),
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
          colors: [AppColors.tint(_accent), AppColors.background],
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
                    decoration: BoxDecoration(
                      // Round for an artist's picture.
                      shape: _isArtist ? BoxShape.circle : BoxShape.rectangle,
                      boxShadow: const [
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
          // The name, and the playlist's options in a circle right after
          // it.
          Row(
            children: [
              Flexible(
                child: Text(
                  _playlist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _optionsButton(),
            ],
          ),
          const SizedBox(height: 10),
          // Who and how much on the left, shuffle and play beside it.
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
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
                        Icon(
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
                            style: TextStyle(
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
          _buildTagChips(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// The playlist's ••• in a translucent circle.
  Widget _optionsButton({double size = 36}) => Material(
    color: AppColors.faint,
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => showPlaylistActions(context, _playlist),
      child: Tooltip(
        message: 'Playlist options',
        child: SizedBox.square(
          dimension: size,
          child: const Icon(Icons.more_horiz, size: 22),
        ),
      ),
    ),
  );

  /// Spotify's desktop header: the cover with the kind of playlist, its
  /// name in large type and the summary beside it; play, shuffle, options
  /// and find below.
  Widget _buildWideHeader(BuildContext context) {
    final current = _isCurrent;
    final name = _playlist.name;
    final kind = _isArtist
        ? 'Artist'
        : _playlist.id.startsWith('youtube:album:')
        ? 'Album'
        : Library.isRemote(_playlist)
        ? 'YouTube playlist'
        : _playlist.isCustom
        ? 'Playlist'
        : 'Folder';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.tint(_accent), AppColors.background],
          stops: const [0, 0.9],
        ),
      ),
      padding: EdgeInsets.fromLTRB(24, _barBottom + 8, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: _isArtist ? BoxShape.circle : BoxShape.rectangle,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 40,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: PlaylistCover(
                  playlist: _playlist,
                  size: _coverSize(context),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kind,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: name.length <= 18 ? 72 : 44,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
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
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Musify • ${_summary()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Opacity(
                opacity: _pinPlay ? 0 : 1,
                child: _PlayButton(
                  key: _playKey,
                  playing: current && _playing,
                  onTap: _onPlay,
                ),
              ),
              const SizedBox(width: 20),
              _ShuffleButton(active: current && _shuffle, onTap: _onShuffle),
              const SizedBox(width: 12),
              _optionsButton(size: 40),
              const Spacer(),
              IconButton(
                tooltip: 'Find on this page',
                onPressed: _openSearch,
                icon: Icon(Icons.search, color: AppColors.subtle),
              ),
            ],
          ),
          _buildTagChips(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Indexes of the songs to list: all of them, or those with the chosen tag.
  List<int> _tagFiltered() {
    final tracks = _playlist.tracks;
    final library = Library.instance;
    // A tag no longer on any song here lists everything again.
    final tag = library.tags
        .where(
          (t) =>
              t.id == _tagFilter &&
              tracks.any((track) => library.hasTag(track, t)),
        )
        .firstOrNull;
    return [
      for (var i = 0; i < tracks.length; i++)
        if (tag == null || library.hasTag(tracks[i], tag)) i,
    ];
  }

  /// Filter chips for the tags used in this playlist.
  Widget _buildTagChips() {
    final library = Library.instance;
    final used = [
      for (final tag in library.tags)
        if (_playlist.tracks.any((t) => library.hasTag(t, tag))) tag,
    ];
    if (used.isEmpty) return const SizedBox.shrink();
    final active = used.any((t) => t.id == _tagFilter) ? _tagFilter : null;
    Widget chip(String label, String? id, {Color? dot}) {
      final selected = active == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          selected: selected,
          showCheckmark: false,
          onSelected: (_) => setState(() => _tagFilter = id),
          avatar: dot == null
              ? null
              : Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
          label: Text(label),
          labelStyle: TextStyle(
            color: selected ? Colors.black : AppColors.text,
            fontWeight: FontWeight.w500,
          ),
          selectedColor: AppColors.green,
          backgroundColor: AppColors.chip,
          side: BorderSide.none,
          shape: const StadiumBorder(),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            chip('All', null),
            for (final tag in used) chip(tag.name, tag.id, dot: tag.color),
          ],
        ),
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
                      style: TextStyle(
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
    final current = _isCurrent && track.path == _currentPath;
    return SongTile(
      track: track,
      current: current,
      playing: current && _playing,
      onTap: () => _onTrack(index),
      onMore: () => showSongMenu(
        context,
        track,
        onPlay: () => _onTrack(index),
        from: _playlist,
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
          color: AppColors.faint,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
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
          Icon(Icons.search, size: 22, color: AppColors.subtle),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              cursorColor: AppColors.green,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: AppColors.text, fontSize: 14),
              decoration: InputDecoration(
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
              child: Icon(Icons.close, size: 20, color: AppColors.subtle),
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
  final bool liked;

  const _EmptyPlaylist({required this.liked});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 0),
      child: Column(
        children: [
          Text(
            liked
                ? 'Songs you like will appear here'
                : "Let's start building your playlist",
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            liked
                ? 'Save songs by tapping the heart in the player, or "Like" '
                      'in a song\'s menu.'
                : 'While a song plays, open ••• in the player and choose '
                      '"Add to playlist". Song menus in your folders have it '
                      'too.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
