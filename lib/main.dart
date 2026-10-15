import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop/desktop_shell.dart';
import 'screens/now_playing.dart';
import 'services/android_app.dart';
import 'services/local_copies.dart';
import 'services/app_log.dart';
import 'services/musify_server.dart';
import 'services/appearance.dart';
import 'services/audio_handler.dart';
import 'services/equalizer_service.dart';
import 'services/playback_session.dart';
import 'services/player_service.dart';
import 'services/sync_service.dart';
import 'services/voice_play.dart';
import 'services/youtube/youtube_web_player.dart';
import 'tabs/settings_tab.dart';
import 'tabs/home_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';
import 'theme.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/download_sheet.dart';
import 'widgets/mini_player.dart';
import 'widgets/navigation.dart';
import 'widgets/playing_elsewhere.dart';
import 'widgets/sync_conflict.dart';
import 'widgets/toast.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Appearance.load();
  await AndroidApp.load();
  // The server's address and key, so screens show them straight away.
  await MusifyServer.instance.load();
  await PlayerService.init();
  try {
    await AudioService.init(
      builder: MusifyAudioHandler.new,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.fatmachines.musify.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
      ),
    );
  } catch (e) {
    AppLog.add('audio service setup failed: $e');
  }
  runApp(MusifyApp());
  // Brings back what was playing last time, paused, and keeps it saved.
  PlaybackSession.start();
  // Playlists, tags and what's playing, with the user's other devices.
  SyncService.instance.start();
  // YouTube songs already on the device play from there.
  LocalCopies.instance.start();
  EqualizerService.instance.init();
  VoicePlay.init();
  YouTubeWebPlayer.instance.attach();
}

class MusifyApp extends StatefulWidget {
  const MusifyApp({super.key});

  @override
  State<MusifyApp> createState() => _MusifyAppState();
}

/// Redraws everything when the appearance changes (Settings, or the
/// device's own setting on "Same as this device"): the palette is read
/// directly, so every widget is rebuilt, in place (pages stay open).
class _MusifyAppState extends State<MusifyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Appearance.mode.addListener(_rebuild);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Appearance.mode.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    setState(() {});
    // Widgets that didn't change still read the old colours: rebuild all.
    void mark(Element element) {
      element.markNeedsBuild();
      element.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  void didChangePlatformBrightness() {
    if (Appearance.mode.value == ThemeMode.system) _rebuild();
  }

  Brightness get _brightness => switch (Appearance.mode.value) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
  };

  @override
  Widget build(BuildContext context) {
    final brightness = _brightness;
    return MaterialApp(
      title: 'Musify',
      // Straight to the new colours: every widget is rebuilt anyway.
      themeAnimationDuration: Duration.zero,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness),
      // Spotify's desktop layout on wide windows (the Mac, iPad landscape),
      // the phone's tabs otherwise.
      home: Builder(
        builder: (context) {
          final size = MediaQuery.sizeOf(context);
          _uprightOnPhones(size);
          return DesktopShell.fits(size)
              ? const DesktopShell()
              : const HomeShell();
        },
      ),
    );
  }
}

bool _orientationSet = false;

/// Phones stay upright, as Spotify's app does: the player and the pages are
/// made for it. Tablets turn (wide, they get the desktop layout). Decided
/// once the screen's size is known.
void _uprightOnPhones(Size size) {
  if (_orientationSet || size.isEmpty) return;
  _orientationSet = true;
  if ((Platform.isAndroid || Platform.isIOS) && size.shortestSide < 600) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;

  late final VoidCallback _stopMessages;
  late final VoidCallback _stopConflicts;

  @override
  void initState() {
    super.initState();
    // "Picked up where you left off on …", "You're offline…".
    _stopMessages = listenForMessages(this);
    _stopConflicts = listenForConflicts(this);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// Cmd+F / Ctrl+F on a keyboard (iPad): a playlist's own search.
  bool _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyF &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      return FindShortcut.find();
    }
    return false;
  }

  /// How far the full player is open: 0 is just the mini player, 1 is full
  /// screen. Drags move it directly; releases animate to either end.
  late final _player = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  // Each tab gets its own Navigator so pushed screens (e.g. a playlist) keep
  // the bottom bar visible and survive switching tabs.
  final _navigatorKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  static const _tabs = [HomeTab(), SearchTab(), LibraryTab(), SettingsTab()];

  /// Tapping the open tab goes back to its first page; on Search, tapping
  /// it again from there starts a search.
  void _onSelect(int index) {
    if (index == _index) {
      final navigator = _navigatorKeys[index].currentState;
      if (navigator != null && navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      } else if (index == 1) {
        searchFocusRequests.value++;
      }
    } else {
      setState(() => _index = index);
    }
  }

  @override
  void dispose() {
    _stopMessages();
    _stopConflicts();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _player.dispose();
    super.dispose();
  }

  void _openPlayer() => _player.animateTo(1, curve: Curves.easeOutCubic);

  void _closePlayer() => _player.animateTo(0, curve: Curves.easeOutCubic);

  void _dragPlayer(DragUpdateDetails details) {
    _player.value -= details.primaryDelta! / MediaQuery.sizeOf(context).height;
  }

  /// A flick decides by direction; a slow release by how far it got.
  void _releasePlayer(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -400) {
      _openPlayer();
    } else if (velocity > 400) {
      _closePlayer();
    } else if (_player.value > 0.5) {
      _openPlayer();
    } else {
      _closePlayer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_player.value > 0) {
          _closePlayer();
          return;
        }
        final navigator = _navigatorKeys[_index].currentState;
        if (navigator != null && await navigator.maybePop()) return;
        if (_index != 0) {
          setState(() => _index = 0);
        } else {
          // Not Navigator.maybePop: that comes straight back here.
          await AndroidApp.toBackground();
        }
      },
      child: Stack(
        children: [
          // YouTube songs play in here, out of sight behind the app.
          const Positioned(left: 0, top: 0, child: YouTubeWebHost()),
          // While songs download, a banner at the top pushes the app down.
          DownloadBannerLayout(
            child: Scaffold(
              // The bar fades over the content, so content runs underneath it.
              extendBody: true,
              body: IndexedStack(
                index: _index,
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Navigator(
                      key: _navigatorKeys[i],
                      onGenerateRoute: (_) =>
                          MaterialPageRoute(builder: (_) => _tabs[i]),
                    ),
                ],
              ),
              bottomNavigationBar: BottomBar(
                index: _index,
                onSelect: _onSelect,
                header: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MiniPlayer(
                      onOpen: _openPlayer,
                      onDragUpdate: _dragPlayer,
                      onDragEnd: _releasePlayer,
                    ),
                    // Another device has the music: say so, play here.
                    const PlayingElsewhereStrip(
                      margin: EdgeInsets.fromLTRB(8, 0, 8, 8),
                      radius: BorderRadius.all(Radius.circular(8)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The full player rides up from the bottom over everything.
          AnimatedBuilder(
            animation: _player,
            builder: (context, child) {
              if (_player.value == 0) return const SizedBox.shrink();
              final height = MediaQuery.sizeOf(context).height;
              // Open, it's all a screen reader finds: not the page under it.
              return BlockSemantics(
                blocking: _player.value == 1,
                child: Transform.translate(
                  offset: Offset(0, (1 - _player.value) * height),
                  child: child,
                ),
              );
            },
            child: GestureDetector(
              onVerticalDragUpdate: _dragPlayer,
              onVerticalDragEnd: _releasePlayer,
              child: NowPlaying(
                onClose: _closePlayer,
                onDragUpdate: _dragPlayer,
                onDragEnd: _releasePlayer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
