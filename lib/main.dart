import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'screens/now_playing.dart';
import 'services/app_log.dart';
import 'services/audio_handler.dart';
import 'services/equalizer_service.dart';
import 'services/playback_session.dart';
import 'services/player_service.dart';
import 'services/voice_play.dart';
import 'services/youtube/youtube_web_player.dart';
import 'tabs/equalizer_tab.dart';
import 'tabs/home_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/search_tab.dart';
import 'theme.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/download_sheet.dart';
import 'widgets/mini_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlayerService.init();
  try {
    await AudioService.init(
      builder: MusifyAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.fatmachines.musify.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
      ),
    );
  } catch (e) {
    AppLog.add('audio service setup failed: $e');
  }
  runApp(const MusifyApp());
  // Brings back what was playing last time, paused, and keeps it saved.
  PlaybackSession.start();
  EqualizerService.instance.init();
  VoicePlay.init();
  YouTubeWebPlayer.instance.attach();
}

class MusifyApp extends StatelessWidget {
  const MusifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Musify',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: buildTheme(),
      home: const HomeShell(),
    );
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

  /// How far the full player is open: 0 is just the mini player, 1 is full
  /// screen. Drags move it directly; releases animate to either end.
  late final _player = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  // Each tab gets its own Navigator so pushed screens (e.g. a playlist) keep
  // the bottom bar visible and survive switching tabs.
  final _navigatorKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  static const _tabs = [HomeTab(), SearchTab(), LibraryTab(), EqualizerTab()];

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
        } else if (context.mounted) {
          Navigator.of(context).maybePop();
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
                header: MiniPlayer(
                  onOpen: _openPlayer,
                  onDragUpdate: _dragPlayer,
                  onDragEnd: _releasePlayer,
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
              return Transform.translate(
                offset: Offset(0, (1 - _player.value) * height),
                child: child,
              );
            },
            child: GestureDetector(
              onVerticalDragUpdate: _dragPlayer,
              onVerticalDragEnd: _releasePlayer,
              child: NowPlaying(onClose: _closePlayer),
            ),
          ),
        ],
      ),
    );
  }
}
