import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../models/playlist.dart';
import '../app_log.dart';
import '../player_service.dart';

/// Plays YouTube songs in YouTube's own (mobile web) player, kept in a tiny
/// hidden web view, the way Demus does. Musify's player queues a silent
/// stand-in of the same length for each YouTube song (see
/// PlayerService._source), so the queue, lock screen, CarPlay, Siri and
/// swipes all work unchanged; this keeps the web player in step with it:
///
///  - the stand-in becomes current: the video is loaded and played
///  - play / pause / seek on the stand-in: mirrored to the video
///  - the video's own clock wins: the stand-in is moved to match it (and
///    held still during ads)
///  - the video ends: on to the next song
///
/// The page is told it's always visible so it keeps playing in the
/// background, and the video is nudged back to playing if the system
/// pauses it.
class YouTubeWebPlayer {
  YouTubeWebPlayer._();

  static final instance = YouTubeWebPlayer._();

  static bool get available => WebViewPlatform.instance != null;

  WebViewController? _controller;
  final _subscriptions = <StreamSubscription>[];

  String? _loaded;

  /// Where to start the video just loaded, e.g. a song resumed from last
  /// time.
  Duration _startAt = Duration.zero;
  Duration _lastVideoTime = Duration.zero;
  DateTime _ignoreSeeksUntil = DateTime.fromMillisecondsSinceEpoch(0);

  WebViewController get controller => _controller ??= _create();

  WebViewController _create() {
    var params = const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const {},
      );
    }
    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Musify', onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _inject(),
          onPageFinished: (_) {
            if (_current == null) return;
            _inject();
            if (_startAt > const Duration(seconds: 1)) {
              _command('seek', _startAt.inMilliseconds / 1000);
            }
            _command(_player.playing ? 'play' : 'pause');
          },
          onWebResourceError: (e) =>
              AppLog.add('youtube web: ${e.errorCode} ${e.description}'),
        ),
      );
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    return controller;
  }

  AudioPlayer get _player => PlayerService.instance.player;

  YouTubeTrack? get _current {
    final tag = _player.sequenceState.currentSource?.tag;
    return tag is YouTubeTrack ? tag : null;
  }

  /// Starts following the player. Call once, after the app is up.
  void attach() {
    if (!available || _subscriptions.isNotEmpty) return;
    final player = _player;
    _subscriptions
      ..add(player.sequenceStateStream.listen((_) => _onSongChanged()))
      ..add(
        player.playingStream.listen((playing) {
          if (_current == null) return;
          AppLog.add('youtube web: ${playing ? 'play' : 'pause'}');
          _command(playing ? 'play' : 'pause');
        }),
      )
      ..add(
        player.positionDiscontinuityStream.listen((d) {
          if (d.reason != PositionDiscontinuityReason.seek) return;
          if (_current == null) return;
          if (DateTime.now().isBefore(_ignoreSeeksUntil)) return;
          _command('seek', player.position.inMilliseconds / 1000);
        }),
      );
  }

  void _onSongChanged() {
    final track = _current;
    if (track == null) {
      if (_loaded != null) {
        _loaded = null;
        _command('pause');
        controller.loadRequest(Uri.parse('about:blank'));
      }
      return;
    }
    if (track.videoId == _loaded) return;
    _loaded = track.videoId;
    _startAt = _player.position;
    _lastVideoTime = _startAt;
    AppLog.add('youtube web: loading ${track.videoId} (${track.name})');
    controller.loadRequest(
      Uri.parse('https://m.youtube.com/watch?v=${track.videoId}'),
    );
  }

  void _command(String command, [num? arg]) {
    controller
        .runJavaScript(
          'window.__musifyCmd && window.__musifyCmd('
          '${jsonEncode(command)}, ${arg ?? 'null'});',
        )
        .catchError((_) {});
  }

  /// Moves the stand-in without that move being sent back to the video.
  void _follow(Duration position) {
    _ignoreSeeksUntil = DateTime.now().add(const Duration(milliseconds: 800));
    _player.seek(position);
  }

  void _onMessage(JavaScriptMessage message) {
    final track = _current;
    if (track == null) return;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (data['e']) {
      case 'tick':
        final ad = data['ad'] == true;
        final time = Duration(
          milliseconds: (((data['t'] as num?) ?? 0) * 1000).round(),
        );
        if (ad) {
          // Hold the stand-in where the song was while the ad runs.
          if ((_player.position - _lastVideoTime).abs() >
              const Duration(seconds: 1)) {
            _follow(_lastVideoTime);
          }
          return;
        }
        _lastVideoTime = time;
        if ((_player.position - time).abs() >
            const Duration(milliseconds: 1500)) {
          _follow(time);
        }
      case 'paused':
        AppLog.add('youtube web: video paused itself, resuming');
      case 'ended':
        AppLog.add('youtube web: ${track.videoId} ended');
        if (_player.loopMode == LoopMode.one) {
          _command('seek', 0);
          _command('play');
        } else {
          PlayerService.instance.next();
        }
    }
  }

  void _inject() => controller.runJavaScript(_script).catchError((_) {});

  static const _script = r'''
(function () {
  if (window.__musifyCmd) return;
  // Always look visible, so YouTube doesn't pause in the background.
  try {
    Object.defineProperty(document, 'hidden', { get: () => false });
    Object.defineProperty(document, 'visibilityState', { get: () => 'visible' });
  } catch (e) {}
  document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);

  let want = null;
  let seekTo = null;
  const ready = v => v && v.readyState > 0 && !isAd();
  const send = o => { try { Musify.postMessage(JSON.stringify(o)); } catch (e) {} };
  const video = () => document.querySelector('video');
  const isAd = () => {
    const p = document.querySelector('.html5-video-player, #movie_player');
    return !!(p && p.classList.contains('ad-showing'));
  };

  window.__musifyCmd = (cmd, arg) => {
    const v = video();
    if (cmd === 'play') { want = 'play'; if (v) v.play().catch(() => {}); }
    else if (cmd === 'pause') { want = 'pause'; if (v) v.pause(); }
    else if (cmd === 'seek') {
      if (ready(v)) v.currentTime = arg; else seekTo = arg;
    }
  };

  let hooked = null;
  setInterval(() => {
    const v = video();
    if (!v) return;
    if (hooked !== v) {
      hooked = v;
      v.addEventListener('ended', () => { if (!isAd()) send({ e: 'ended' }); });
      // The system pauses video when the app leaves the screen: resume.
      v.addEventListener('pause', () => {
        if (want === 'play' && !v.ended && !isAd()) {
          send({ e: 'paused' });
          setTimeout(() => v.play().catch(() => {}), 300);
        }
      });
    }
    if (want === 'play') {
      if (v.muted) v.muted = false;
      if (v.paused && !v.ended) v.play().catch(() => {});
    }
    const skip = document.querySelector(
      '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
    if (skip) skip.click();
    if (seekTo !== null) {
      // Not where it should be yet: say nothing until it is.
      if (!ready(v)) return;
      v.currentTime = seekTo;
      seekTo = null;
    }
    send({ e: 'tick', t: v.currentTime, d: v.duration || 0, p: !v.paused, ad: isAd() });
  }, 500);
})();
''';
}

/// The web view YouTube plays in: kept in the tree but effectively
/// invisible, behind everything.
class YouTubeWebHost extends StatelessWidget {
  const YouTubeWebHost({super.key});

  @override
  Widget build(BuildContext context) {
    if (!YouTubeWebPlayer.available) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: 0.01,
        child: SizedBox(
          width: 2,
          height: 2,
          child: WebViewWidget(
            controller: YouTubeWebPlayer.instance.controller,
          ),
        ),
      ),
    );
  }
}
