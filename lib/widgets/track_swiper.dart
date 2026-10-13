import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/player_service.dart';

/// Shows the current song with the previous and next ones either side, so a
/// sideways swipe slides them in like Spotify's players. Letting go past
/// halfway skips to that song. When the song changes some other way (the
/// buttons, the lock screen, a song ending) the new one slides in too.
class TrackSwiper extends StatefulWidget {
  final Widget Function(BuildContext context, Track track) itemBuilder;

  const TrackSwiper({super.key, required this.itemBuilder});

  @override
  State<TrackSwiper> createState() => _TrackSwiperState();
}

class _TrackSwiperState extends State<TrackSwiper> {
  final _service = PlayerService.instance;
  late StreamSubscription _subscription;

  late PageController _controller;
  List<Track> _pages = const [];

  /// The page holding the current song.
  int _current = 0;

  /// Bumped whenever the pages are rebuilt around a new song, so the
  /// PageView starts over on the right page in the same frame (no flash of
  /// the wrong song).
  int _generation = 0;

  bool _dragging = false;
  bool _sliding = false;

  @override
  void initState() {
    super.initState();
    final (pages, current) = _layout();
    _pages = pages;
    _current = current;
    _controller = PageController(initialPage: current);
    _subscription = _service.player.sequenceStateStream.listen(
      (_) => _onPlayerChange(),
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    _controller.dispose();
    super.dispose();
  }

  (List<Track>, int) _layout() {
    final current = _service.currentTrack;
    if (current == null) return (const [], 0);
    final previous = _service.neighbour(-1);
    final next = _service.neighbour(1);
    return ([?previous, current, ?next], previous == null ? 0 : 1);
  }

  void _onPlayerChange() {
    if (_dragging || _sliding || !mounted) return;
    final current = _service.currentTrack;
    final shownAt = current == null
        ? -1
        : _pages.indexWhere((t) => t.path == current.path);
    if (shownAt >= 0 && shownAt != _current && _controller.hasClients) {
      _sliding = true;
      _controller
          .animateToPage(
            shownAt,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            _sliding = false;
            _relayout();
          });
      return;
    }
    _relayout();
  }

  /// Re-centres the pages on the current song, if anything changed.
  void _relayout() {
    if (!mounted) return;
    final (pages, current) = _layout();
    final unchanged =
        current == _current &&
        pages.length == _pages.length &&
        [for (var i = 0; i < pages.length; i++) pages[i].path == _pages[i].path]
            .every((same) => same) &&
        (!_controller.hasClients || _controller.page?.round() == current);
    if (unchanged) return;
    final old = _controller;
    setState(() {
      _pages = pages;
      _current = current;
      _controller = PageController(initialPage: current);
      _generation++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
    } else if (notification is ScrollEndNotification && _dragging) {
      _dragging = false;
      final page = _controller.page?.round() ?? _current;
      if (page == _current) return false;
      _service.skip(page - _current).whenComplete(_relayout);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) return const SizedBox.shrink();
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView.builder(
        key: ValueKey(_generation),
        controller: _controller,
        itemCount: _pages.length,
        itemBuilder: (context, i) => widget.itemBuilder(context, _pages[i]),
      ),
    );
  }
}
