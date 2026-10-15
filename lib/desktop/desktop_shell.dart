import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playlist.dart';
import '../screens/now_playing.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../services/youtube/youtube_web_player.dart';
import '../tabs/settings_tab.dart';
import '../widgets/bottom_bar.dart';
import '../tabs/home_tab.dart';
import '../tabs/library_tab.dart';
import '../tabs/search_tab.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/download_sheet.dart';
import '../widgets/navigation.dart';
import '../widgets/playing_elsewhere.dart';
import '../widgets/sync_conflict.dart';
import '../widgets/toast.dart';

/// Spotify's desktop layout, for the Mac and other wide windows: a top bar
/// (back, home, search), "Your Library" down the left, the page in a
/// rounded panel beside it, and the player across the bottom.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  /// Whether a window this size gets the desktop layout: wide enough, and
  /// not a phone on its side.
  /// In place of play/pause on space, for tests.
  @visibleForTesting
  static VoidCallback? debugSpace;

  static bool fits(Size size) => size.width >= 840 && size.shortestSide >= 560;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell>
    with SingleTickerProviderStateMixin {
  final _main = GlobalKey<NavigatorState>();
  final _query = TextEditingController();
  final _searchFocus = FocusNode();

  /// The Search page while it's open, so typing goes back to it.
  Route<void>? _searchRoute;

  /// The full player, faded in over everything.
  late final _player = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    _searchFocus.addListener(_onFocusChanged);
    searchFocusRequests.addListener(_searchFocus.requestFocus);
    _stopMessages = listenForMessages(this);
    _stopConflicts = listenForConflicts(this);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  late final VoidCallback _stopMessages;
  late final VoidCallback _stopConflicts;

  @override
  void dispose() {
    searchFocusRequests.removeListener(_searchFocus.requestFocus);
    _stopMessages();
    _stopConflicts();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _query.dispose();
    _searchFocus.dispose();
    _player.dispose();
    super.dispose();
  }

  NavigatorState? get _navigator => _main.currentState;

  void _home() {
    _query.clear();
    _searchFocus.unfocus();
    _navigator?.popUntil((route) => route.isFirst);
  }

  /// Typing in (or clicking into) the top bar's search shows the Search
  /// page. Leaving the field doesn't: a result may have just opened.
  String _lastQuery = '';

  void _onQueryChanged() {
    if (_query.text == _lastQuery) return;
    _lastQuery = _query.text;
    if (_query.text.isNotEmpty) _showSearch();
  }

  void _onFocusChanged() {
    if (_searchFocus.hasFocus) _showSearch();
  }

  void _showSearch() {
    final navigator = _navigator;
    if (navigator == null) return;
    final open = _searchRoute;
    if (open != null && open.isActive) {
      if (!open.isCurrent) navigator.popUntil((route) => route == open);
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => SearchTab(query: _query, focus: _searchFocus),
    );
    _searchRoute = route;
    navigator.push(route);
  }

  void _openSettings() =>
      _navigator?.push(MaterialPageRoute(builder: (_) => const SettingsTab()));

  void _openPlayer() => _player.forward();

  void _closePlayer() => _player.reverse();

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      child: DesktopScope(
        main: _main,
        child: Stack(
          children: [
            // YouTube songs play in here, out of sight behind the app.
            Positioned(left: 0, top: 0, child: YouTubeWebHost()),
            DownloadBannerLayout(
              child: Scaffold(
                backgroundColor: AppColors.frame,
                body: Column(
                  children: [
                    _TopBar(
                      query: _query,
                      focus: _searchFocus,
                      onBack: () => _navigator?.maybePop(),
                      onHome: _home,
                      onSettings: _openSettings,
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 320,
                              child: _Panel(child: _Sidebar()),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: _Panel(
                                child: Navigator(
                                  key: _main,
                                  // Opening a page (Search, as you type)
                                  // mustn't take the keyboard from the
                                  // search field.
                                  requestFocus: false,
                                  onGenerateRoute: (_) => MaterialPageRoute(
                                    builder: (_) => HomeTab(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Another device has the music: Spotify's green strip.
                    const PlayingElsewhereStrip(),
                    _PlayerBar(onOpen: _openPlayer),
                  ],
                ),
              ),
            ),
            // The full player, over everything, the page dimmed behind.
            AnimatedBuilder(
              animation: _player,
              builder: (context, child) => _player.value == 0
                  ? SizedBox.shrink()
                  : FadeTransition(opacity: _player, child: child),
              child: Material(
                color: Colors.black.withValues(alpha: 0.85),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 520),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: NowPlaying(onClose: _closePlayer),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Space plays and pauses, as in Spotify, wherever the keyboard focus is
  /// (it moves around: the search field, a slider, nothing), unless typing:
  /// then the text field gets it. Cmd+F / Ctrl+F finds.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // Cmd+F (Ctrl+F elsewhere): the playlist's own search, or the top bar's.
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyF &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      if (!FindShortcut.find()) _searchFocus.requestFocus();
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.space || _typing()) {
      return false;
    }
    (DesktopShell.debugSpace ?? PlayerService.instance.togglePlayback)();
    return true;
  }

  /// Whether a text field has the keyboard (the search, a dialog's field).
  bool _typing() {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null);
  }
}

/// A rounded dark panel, like Spotify's library and page panels.
class _Panel extends StatelessWidget {
  final Widget child;

  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: AppColors.background,
        // The pages inside are phone pages: no bars to keep clear of here.
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          child: child,
        ),
      ),
    );
  }
}

/// Your Library, as on the phone, in its own navigator so its sheets and
/// menus work; playlists open in the main panel.
class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => LibraryTab()),
    );
  }
}

// Top bar ------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  final TextEditingController query;
  final FocusNode focus;
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onSettings;

  const _TopBar({
    required this.query,
    required this.focus,
    required this.onBack,
    required this.onHome,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64 + MediaQuery.paddingOf(context).top,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + 8,
          16,
          8,
        ),
        child: Row(
          children: [
            _RoundButton(
              icon: Icons.arrow_back_ios_new,
              tooltip: 'Back',
              size: 32,
              iconSize: 16,
              onTap: onBack,
            ),
            Spacer(),
            _RoundButton(
              icon: Icons.home_filled,
              tooltip: 'Home',
              onTap: onHome,
            ),
            SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 480),
              child: SizedBox(
                width: 480,
                child: _SearchField(query: query, focus: focus),
              ),
            ),
            Spacer(),
            SyncBadge(
              child: _RoundButton(
                icon: Icons.settings_outlined,
                svg: 'assets/icons/settings.svg',
                tooltip: 'Settings',
                size: 40,
                onTap: onSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final double iconSize;

  /// Drawn from this SVG instead of [icon].
  final String? svg;

  const _RoundButton({
    required this.icon,
    this.svg,
    required this.tooltip,
    required this.onTap,
    this.size = 48,
    this.iconSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surface,
        shape: CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: svg == null
                  ? Icon(icon, size: iconSize, color: AppColors.text)
                  : SvgPicture.asset(
                      svg!,
                      width: iconSize - 2,
                      height: iconSize - 2,
                      colorFilter: ColorFilter.mode(
                        AppColors.text,
                        BlendMode.srcIn,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController query;
  final FocusNode focus;

  const _SearchField({required this.query, required this.focus});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([query, focus]),
      builder: (context, _) => Container(
        height: 48,
        padding: EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: focus.hasFocus ? AppColors.text : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.search, color: AppColors.subtle, size: 26),
            SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: query,
                focusNode: focus,
                cursorColor: AppColors.green,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: 'What do you want to play?',
                  hintStyle: TextStyle(color: AppColors.subtle, fontSize: 15),
                ),
              ),
            ),
            if (query.text.isNotEmpty)
              GestureDetector(
                onTap: query.clear,
                child: Icon(Icons.close, color: AppColors.subtle),
              ),
          ],
        ),
      ),
    );
  }
}

// Player bar ---------------------------------------------------------------------

/// Spotify's bottom bar: the song on the left, the controls and seek bar
/// in the middle, queue, volume and the full player on the right.
class _PlayerBar extends StatelessWidget {
  final VoidCallback onOpen;

  const _PlayerBar({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return SizedBox(
      height: 88,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: StreamBuilder<SequenceState?>(
          stream: service.player.sequenceStateStream,
          builder: (context, _) {
            final track = service.currentTrack;
            return Row(
              children: [
                Expanded(
                  flex: 3,
                  child: track == null
                      ? SizedBox.shrink()
                      : _NowPlayingSong(track: track, onOpen: onOpen),
                ),
                Expanded(
                  flex: 4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Controls(enabled: track != null),
                      SizedBox(height: 4),
                      const _Seek(),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Queue',
                        onPressed: track == null
                            ? null
                            : () => showQueueSheet(context),
                        icon: const Icon(Icons.queue_music, size: 20),
                      ),
                      const _Volume(),
                      IconButton(
                        tooltip: 'Full player',
                        onPressed: track == null ? null : onOpen,
                        icon: const Icon(Icons.open_in_full, size: 18),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NowPlayingSong extends StatelessWidget {
  final Track track;
  final VoidCallback onOpen;

  const _NowPlayingSong({required this.track, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    return Row(
      children: [
        GestureDetector(
          onTap: onOpen,
          child: TrackCover(track: track, size: 56),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info?.title ?? track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: 2),
              Text(
                info?.artist ?? 'Unknown artist',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.subtle, fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(width: 8),
        ListenableBuilder(
          listenable: Library.instance,
          builder: (context, _) {
            final liked = Library.instance.isLiked(track);
            return IconButton(
              tooltip: liked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
              onPressed: () => Library.instance.toggleLike(track),
              icon: Icon(
                liked ? Icons.check_circle : Icons.add_circle_outline,
                size: 20,
                color: liked ? AppColors.green : AppColors.subtle,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  final bool enabled;

  const _Controls({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    final player = service.player;
    Widget small(
      IconData icon,
      String tip,
      VoidCallback onTap, {
      bool on = false,
    }) => IconButton(
      tooltip: tip,
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 20, color: on ? AppColors.green : null),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: service.shuffleOn,
          builder: (context, on, _) => small(
            Icons.shuffle,
            on ? 'Shuffle off' : 'Shuffle',
            () => service.setShuffle(!on),
            on: on,
          ),
        ),
        small(Icons.skip_previous_rounded, 'Previous', service.previous),
        SizedBox(width: 4),
        ValueListenableBuilder<bool>(
          // This device's, or the other device's being played from here.
          valueListenable: PlayerService.instance.shownPlaying,
          builder: (context, playing, _) {
            return Tooltip(
              message: playing ? 'Pause' : 'Play',
              child: Material(
                color: enabled ? AppColors.text : AppColors.muted,
                shape: CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: enabled ? service.togglePlayback : null,
                  child: SizedBox.square(
                    dimension: 36,
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: AppColors.onText,
                      size: 24,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        SizedBox(width: 4),
        small(Icons.skip_next_rounded, 'Next', service.next),
        StreamBuilder<LoopMode>(
          stream: player.loopModeStream,
          initialData: player.loopMode,
          builder: (context, snapshot) {
            final mode = snapshot.data ?? LoopMode.off;
            return small(
              mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              switch (mode) {
                LoopMode.off => 'Repeat off',
                LoopMode.all => 'Repeat all',
                LoopMode.one => 'Repeat one',
              },
              service.cycleRepeat,
              on: mode != LoopMode.off,
            );
          },
        ),
      ],
    );
  }
}

/// Times either side of a thin seek bar, with a YouTube song's loaded part.
class _Seek extends StatefulWidget {
  const _Seek();

  @override
  State<_Seek> createState() => _SeekState();
}

class _SeekState extends State<_Seek> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    final player = service.player;
    final loaded = YouTubeWebPlayer.instance.buffered;
    return ListenableBuilder(
      listenable: loaded,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: PlayerService.instance.shownPosition,
        initialData: PlayerService.instance.shownPositionNow,
        builder: (context, snapshot) {
          final total = (player.duration ?? Duration.zero).inMilliseconds
              .toDouble();
          final position = PlayerService
              .instance
              .shownPositionNow
              .inMilliseconds
              .toDouble()
              .clamp(0.0, total);
          final value = _dragging ?? position;
          final buffered = service.currentTrack is YouTubeTrack
              ? loaded.value.inMilliseconds.toDouble().clamp(0.0, total)
              : null;
          final time = TextStyle(color: AppColors.subtle, fontSize: 11);
          return Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  _format(value),
                  textAlign: TextAlign.right,
                  style: time,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: AppColors.text,
                    inactiveTrackColor: AppColors.track,
                    secondaryActiveTrackColor: AppColors.loaded,
                    thumbColor: AppColors.text,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: value,
                    secondaryTrackValue: buffered,
                    max: total > 0 ? total : 1,
                    onChanged: total > 0
                        ? (v) => setState(() => _dragging = v)
                        : null,
                    onChangeEnd: (v) {
                      PlayerService.instance.seekTo(
                        Duration(milliseconds: v.round()),
                      );
                      setState(() => _dragging = null);
                    },
                  ),
                ),
              ),
              SizedBox(width: 40, child: Text(_format(total), style: time)),
            ],
          );
        },
      ),
    );
  }

  static String _format(double ms) {
    final d = Duration(milliseconds: ms.round());
    return '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }
}

class _Volume extends StatelessWidget {
  const _Volume();

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance.player;
    return StreamBuilder<double>(
      stream: player.volumeStream,
      initialData: player.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 1;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: volume == 0 ? 'Unmute' : 'Mute',
              onPressed: () => player.setVolume(volume == 0 ? 1 : 0),
              icon: Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
                size: 20,
              ),
            ),
            SizedBox(
              width: 100,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: AppColors.text,
                  inactiveTrackColor: AppColors.track,
                  thumbColor: AppColors.text,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(value: volume, onChanged: player.setVolume),
              ),
            ),
          ],
        );
      },
    );
  }
}
