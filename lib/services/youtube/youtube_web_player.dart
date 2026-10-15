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
/// hidden web view, the way Demus does, when there's no Musify server to
/// stream them from (or it fails). Musify's player queues a silent
/// stand-in of the same length for each YouTube song (see
/// PlayerService._source), so the queue, lock screen, CarPlay, Siri and
/// swipes all work unchanged; this keeps the web player in step with it:
///
///  - the stand-in becomes current: the video is loaded and played
///  - play / pause / seek on the stand-in: mirrored to the video
///  - the video's own clock wins: the stand-in is moved to match it (and
///    held still during ads)
///  - the video ends: on to the next song
///  - the video stalls, or iOS ends the web view's process in the
///    background: the video is loaded again where it was
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

  /// When the video's clock (or an ad's) last moved on, and to what; and
  /// when it was last loaded: how a stall is noticed.
  DateTime _lastProgress = DateTime.now();
  Duration _progressTime = Duration.zero;
  DateTime _lastLoad = DateTime.now();
  DateTime? _lastTick;
  bool _videoPlaying = false;

  /// Whether this stall was already met with a pause-and-play.
  bool _kicked = false;

  /// The video couldn't load for want of a network: the song was paused
  /// (not left running in silence), and loads again when played.
  bool _offline = false;

  /// Ticks still to log after coming back on screen.
  int _logTicks = 0;
  DateTime _lastPlayFailLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where [track]'s video has got to, if it's the one here and has
  /// started playing; null if it hasn't (still loading, or held up in the
  /// background), when the stand-in's own clock means nothing.
  Duration? playedOf(YouTubeTrack track) =>
      _loaded == track.videoId &&
          _lastTick != null &&
          _lastVideoTime > Duration.zero
      ? _lastVideoTime
      : null;

  /// How far the current video has loaded ahead, for the seek bar.
  final buffered = ValueNotifier<Duration>(Duration.zero);

  /// A song playing whose video hasn't moved for [_kickAfter] gets paused
  /// and played again; after [_stallLimit], reloaded.
  static const _kickAfter = Duration(seconds: 3);
  static const _stallLimit = Duration(seconds: 8);

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
            if (_player.volume < 1) _command('volume', _player.volume);
            _command(_player.playing ? 'play' : 'pause');
          },
          onWebResourceError: (e) {
            AppLog.add('youtube web: ${e.errorCode} ${e.description}');
            if (e.isForMainFrame != false && _isOffline(e)) {
              _goneOffline();
              return;
            }
            // iOS ended the page's process, e.g. while in the background.
            if (e.errorType ==
                WebResourceErrorType.webContentProcessTerminated) {
              _reload('web view process ended');
            }
          },
        ),
      );
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    return controller;
  }

  AudioPlayer get _player => PlayerService.instance.player;

  /// The page failed for want of a network (Android's net:: errors, iOS's
  /// NSURLError codes), not for something on YouTube's side.
  static bool _isOffline(WebResourceError e) =>
      const {
        WebResourceErrorType.hostLookup,
        WebResourceErrorType.connect,
        WebResourceErrorType.timeout,
      }.contains(e.errorType) ||
      const {-1009, -1003, -1004, -1005, -1001}.contains(e.errorCode) ||
      RegExp(
        r'ERR_(INTERNET_DISCONNECTED|NAME_NOT_RESOLVED|NETWORK_CHANGED|'
        r'ADDRESS_UNREACHABLE|CONNECTION_(REFUSED|TIMED_OUT|RESET))',
      ).hasMatch(e.description);

  /// Pauses the song instead of letting its silent stand-in run on, and
  /// says why, once. Playing it again tries again.
  void _goneOffline() {
    if (_current == null) return;
    final wasPlaying = _player.playing;
    _offline = true;
    if (!wasPlaying) return;
    AppLog.add('youtube web: offline, pausing');
    _player.pause();
    PlayerService.instance.notice.value =
        "You're offline: YouTube songs need the internet";
  }

  /// The YouTube song to play here; not one streamed from the server,
  /// which the system's player plays itself.
  YouTubeTrack? get _current {
    final source = _player.sequenceState.currentSource;
    return PlayerService.isWebSource(source)
        ? source!.tag as YouTubeTrack
        : null;
  }

  /// Starts following the player. Call once, after the app is up.
  void attach() {
    if (!available || _subscriptions.isNotEmpty) return;
    final player = _player;
    _subscriptions
      ..add(player.sequenceStateStream.listen((_) => _onSongChanged()))
      ..add(
        player.playingStream.listen((playing) {
          final track = _current;
          if (track == null) return;
          // Played again after going offline: try loading it again.
          if (playing && _offline) {
            AppLog.add('youtube web: played again, retrying');
            _load(track, from: _lastVideoTime);
            return;
          }
          // Give the video a moment to start before calling it stalled.
          if (playing) _markProgress(_lastVideoTime);
          AppLog.add('youtube web: ${playing ? 'play' : 'pause'}');
          _command(playing ? 'play' : 'pause');
        }),
      )
      // The Mac's volume slider moves the stand-in's volume; the video
      // follows. (iPhone's web views ignore it: the buttons do volume.)
      ..add(
        player.volumeStream.listen((volume) {
          if (_current != null) _command('volume', volume);
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
    Timer.periodic(const Duration(seconds: 2), (_) => _check());
    // Back on screen is when a video stopped in the background shows:
    // nudge it, and check on it sooner than usual.
    // Kept alive by the binding it registers with.
    AppLifecycleListener(
      onResume: () {
        if (_current == null || !_player.playing) return;
        AppLog.add('youtube web: back on screen');
        _logTicks = 4;
        _command('play');
        Future.delayed(
          const Duration(seconds: 4),
          () => _check(limit: const Duration(seconds: 4)),
        );
      },
    );
  }

  void _markProgress(Duration time) {
    _lastProgress = DateTime.now();
    _progressTime = time;
    _kicked = false;
  }

  /// Pauses and plays the video, then reloads it, if the song is playing
  /// but the video hasn't moved for a while.
  void _check({Duration limit = _stallLimit}) {
    if (_current == null || !_player.playing || _offline) return;
    final now = DateTime.now();
    final still = now.difference(_lastProgress);
    if (still >= _kickAfter && !_kicked) {
      _kicked = true;
      AppLog.add('youtube web: video still for ${still.inSeconds}s, kicking');
      _command('kick');
    }
    if (still < limit) return;
    if (now.difference(_lastLoad) < limit * 2) return;
    final tick = _lastTick;
    _reload(
      tick == null
          ? 'stalled, no word from the page'
          : 'stalled, last heard ${now.difference(tick).inSeconds}s ago, '
                'video ${_videoPlaying ? 'playing' : 'paused'}',
    );
  }

  /// Loads the current video again, from where it got to.
  void _reload(String why) {
    final track = _current;
    if (track == null) return;
    AppLog.add('youtube web: $why: reloading ${track.videoId}');
    _load(track, from: _lastVideoTime);
  }

  void _onSongChanged() {
    final track = _current;
    if (track == null) {
      buffered.value = Duration.zero;
      if (_loaded != null) {
        _loaded = null;
        _command('pause');
        controller.loadRequest(Uri.parse('about:blank'));
      }
      return;
    }
    if (track.videoId == _loaded) return;
    AppLog.add('youtube web: loading ${track.videoId} (${track.name})');
    _load(track, from: _player.position);
  }

  void _load(YouTubeTrack track, {required Duration from}) {
    _offline = false;
    _loaded = track.videoId;
    _startAt = from;
    _lastVideoTime = from;
    _lastTick = null;
    _videoPlaying = false;
    buffered.value = Duration.zero;
    _lastLoad = DateTime.now();
    _markProgress(from);
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
        _lastTick = DateTime.now();
        _videoPlaying = data['p'] == true;
        // Moved on by more than jitter: an ad running counts too.
        if ((time - _progressTime).abs() >= const Duration(milliseconds: 250)) {
          _markProgress(time);
        }
        if (_logTicks > 0) {
          _logTicks--;
          AppLog.add(
            'youtube web: tick t=${data['t']} playing=${data['p']} '
            'ad=$ad ready=${data['r']} net=${data['n']} err=${data['x']}',
          );
        }
        if (ad) {
          // Hold the stand-in where the song was while the ad runs.
          if ((_player.position - _lastVideoTime).abs() >
              const Duration(seconds: 1)) {
            _follow(_lastVideoTime);
          }
          return;
        }
        _lastVideoTime = time;
        buffered.value = Duration(
          milliseconds: (((data['b'] as num?) ?? 0) * 1000).round(),
        );
        if ((_player.position - time).abs() >
            const Duration(milliseconds: 1500)) {
          _follow(time);
        }
      case 'paused':
        AppLog.add('youtube web: video paused itself, resuming');
      case 'remote':
        // A media key or Now Playing control that went to the page.
        final service = PlayerService.instance;
        AppLog.add('youtube web: ${data['a']} from the page\'s controls');
        switch (data['a']) {
          case 'play':
            _player.play();
          case 'pause':
            _player.pause();
          case 'next':
            service.next();
          case 'previous':
            service.previous();
        }
      case 'playfail':
        final now = DateTime.now();
        if (now.difference(_lastPlayFailLog) > const Duration(seconds: 5)) {
          _lastPlayFailLog = now;
          AppLog.add('youtube web: video refused to play: ${data['m']}');
        }
      case 'media':
        AppLog.add('youtube web: video ${data['m']}');
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

  /// The script, starting out playing or paused as Musify's player is, so
  /// a video that plays by itself on loading (a song brought back from last
  /// time, paused) is paused again.
  void _inject() => controller
      .runJavaScript(
        'window.__musifyWant = ${jsonEncode(_player.playing ? 'play' : 'pause')};'
        '$_script',
      )
      .catchError((_) {});

  static const _script = r'''
(function () {
  if (window.__musifyCmd) return;
  // Always look visible, so YouTube doesn't pause in the background.
  try {
    Object.defineProperty(document, 'hidden', { get: () => false });
    Object.defineProperty(document, 'visibilityState', { get: () => 'visible' });
  } catch (e) {}
  // Window first: its capturing listeners hear the event before the
  // document's.
  for (const name of ['visibilitychange', 'webkitvisibilitychange']) {
    window.addEventListener(name, e => e.stopImmediatePropagation(), true);
    document.addEventListener(name, e => e.stopImmediatePropagation(), true);
  }

  let want = window.__musifyWant || 'pause';
  let seekTo = null;
  const ready = v => v && v.readyState > 0 && !isAd();
  const send = o => { try { Musify.postMessage(JSON.stringify(o)); } catch (e) {} };
  const video = () => document.querySelector('video');
  const isAd = () => {
    const p = document.querySelector('.html5-video-player, #movie_player');
    return !!(p && p.classList.contains('ad-showing'));
  };

  const play = v => v.play().catch(e => send({ e: 'playfail', m: String(e) }));

  // The Mac (and iPhone) list this page as a player of its own, and send
  // it the keyboard's and Now Playing's play, pause, next and previous.
  // Musify's player decides: pass them on, and don't let YouTube take
  // them back.
  if (navigator.mediaSession) {
    const session = navigator.mediaSession;
    const setHandler = session.setActionHandler.bind(session);
    const ours = {};
    for (const [action, name] of [
      ['play', 'play'], ['pause', 'pause'], ['stop', 'pause'],
      ['nexttrack', 'next'], ['previoustrack', 'previous'],
    ]) {
      ours[action] = () => send({ e: 'remote', a: name });
      try { setHandler(action, ours[action]); } catch (e) {}
    }
    session.setActionHandler = (action, handler) => {
      if (!(action in ours)) { try { setHandler(action, handler); } catch (e) {} }
    };
  }

  window.__musifyCmd = (cmd, arg) => {
    const v = video();
    if (cmd === 'play') { want = 'play'; if (v) play(v); }
    else if (cmd === 'kick') {
      want = 'play';
      if (v) { v.pause(); setTimeout(() => play(v), 250); }
    }
    else if (cmd === 'pause') { want = 'pause'; if (v) v.pause(); }
    else if (cmd === 'volume') { window.__musifyVolume = arg; if (v) v.volume = arg; }
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
      for (const name of ['stalled', 'error', 'emptied']) {
        v.addEventListener(name, () => send({ e: 'media', m: name }));
      }
      // The system pauses video when the app leaves the screen: resume.
      v.addEventListener('pause', () => {
        if (want === 'play' && !v.ended && !isAd()) {
          send({ e: 'paused' });
          setTimeout(() => play(v), 300);
        }
      });
    }
    if (window.__musifyVolume != null && Math.abs(v.volume - window.__musifyVolume) > 0.01) {
      v.volume = window.__musifyVolume;
    }
    // Musify's player says paused: the video stays paused, even if
    // YouTube starts it by itself.
    if (want === 'pause' && !v.paused && !isAd()) v.pause();
    if (want === 'play') {
      if (v.muted) v.muted = false;
      if (v.paused && !v.ended) play(v);
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
    // The end of the loaded stretch the video is playing in.
    let b = 0;
    for (let i = 0; i < v.buffered.length; i++) {
      if (v.buffered.start(i) <= v.currentTime + 1) b = Math.max(b, v.buffered.end(i));
    }
    send({
      e: 'tick', t: v.currentTime, d: v.duration || 0, b, p: !v.paused, ad: isAd(),
      r: v.readyState, n: v.networkState, x: v.error ? v.error.code : null,
    });
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
    // Out of sight, and out of a screen reader's way.
    return IgnorePointer(
      child: ExcludeSemantics(
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
      ),
    );
  }
}
