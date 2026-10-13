import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../models/playlist.dart';
import '../app_log.dart';

/// Gets a YouTube song's audio the only way YouTube allows: through its own
/// player. YouTube refuses plain downloads, but its player is given the
/// audio, which it hands to the browser in pieces (Media Source
/// Extensions). In a second hidden web view, muted and sped up, every
/// piece of the audio track is copied as the player hands it over, until
/// the video has played to the end. Mp4Audio then makes a file of them.
class YouTubeCapture extends ChangeNotifier {
  YouTubeCapture._();

  static final instance = YouTubeCapture._();

  WebViewController? _controller;
  _Job? _job;

  /// Whether a capture is running: its web view is in the tree only then.
  bool get busy => _job != null;

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
      ..addJavaScriptChannel('MusifyGrab', onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          // As early and as often as possible, so the hooks are in before
          // YouTube's player sets up the audio.
          onProgress: (_) => _inject(),
          onPageFinished: (_) => _inject(),
          onWebResourceError: (e) {
            if (e.errorType ==
                WebResourceErrorType.webContentProcessTerminated) {
              _job?.fail('the web view stopped');
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

  /// The song's audio as captured (fragmented MP4), or an error.
  /// [onProgress] gets 0 to 1. One capture at a time.
  Future<Uint8List> capture(
    YouTubeTrack track, {
    void Function(double progress)? onProgress,
  }) async {
    if (_job != null) throw StateError('A capture is already running');
    final job = _Job(track, onProgress);
    _job = job;
    notifyListeners();
    AppLog.add('capture: ${track.videoId} (${track.name})');
    // Let the web view join the tree before loading.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.loadRequest(
      Uri.parse('https://m.youtube.com/watch?v=${track.videoId}'),
    );
    job.watch(onRestart: () => _command('restart'));
    try {
      return await job.done.future;
    } finally {
      job.dispose();
      _job = null;
      notifyListeners();
      controller.loadRequest(Uri.parse('about:blank'));
    }
  }

  void _command(String command) => controller
      .runJavaScript(
        'window.__musifyGrabCmd && window.__musifyGrabCmd(${jsonEncode(command)});',
      )
      .catchError((_) {});

  void _inject() {
    final job = _job;
    if (job == null) return;
    controller
        .runJavaScript(
          'window.__musifyVideoId = ${jsonEncode(job.track.videoId)};$_script',
        )
        .catchError((_) {});
  }

  void _onMessage(JavaScriptMessage message) {
    final job = _job;
    if (job == null) return;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    job.onMessage(data);
  }

  static const _script = r'''
(function () {
  if (window.__musifyGrab) return;
  window.__musifyGrab = true;
  const send = o => { try { MusifyGrab.postMessage(JSON.stringify(o)); } catch (e) {} };
  const sources = [window.MediaSource, window.ManagedMediaSource, window.WebKitMediaSource]
    .filter(s => s);

  // AAC in MP4 only: the file has to play on an iPhone, so no Opus/WebM.
  for (const MS of sources) {
    if (!MS.isTypeSupported) continue;
    const supported = MS.isTypeSupported.bind(MS);
    MS.isTypeSupported = t => /^audio\/webm/i.test(t) ? false : supported(t);
  }

  const kinds = new WeakMap();
  const ids = new WeakMap();
  let nextId = 1;
  for (const MS of sources) {
    const add = MS.prototype.addSourceBuffer;
    MS.prototype.addSourceBuffer = function (mime) {
      const buffer = add.call(this, mime);
      kinds.set(buffer, String(mime));
      return buffer;
    };
  }

  const isAd = () => {
    const p = document.querySelector('.html5-video-player, #movie_player');
    return !!(p && p.classList.contains('ad-showing'));
  };
  const has = (bytes, text) => {
    const c = [...text].map(ch => ch.charCodeAt(0));
    outer: for (let i = 0; i + 4 <= Math.min(bytes.length, 4096); i++) {
      for (let j = 0; j < 4; j++) if (bytes[i + j] !== c[j]) continue outer;
      return true;
    }
    return false;
  };
  const toBase64 = bytes => {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s);
  };

  const append = SourceBuffer.prototype.appendBuffer;
  SourceBuffer.prototype.appendBuffer = function (data) {
    try {
      const bytes = data instanceof ArrayBuffer
        ? new Uint8Array(data)
        : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      let kind = kinds.get(this);
      // Set up before the hooks went in: tell by the track setup.
      if (!kind && has(bytes, 'moov')) {
        kind = has(bytes, 'soun') ? 'audio/mp4' : has(bytes, 'vide') ? 'video/mp4' : null;
        if (kind) kinds.set(this, kind);
      }
      if (kind && kind.startsWith('audio') && !isAd()) {
        if (!ids.has(this)) ids.set(this, nextId++);
        send({ e: 'chunk', id: ids.get(this), kind, init: has(bytes, 'moov'), b: toBase64(bytes) });
      }
    } catch (e) {
      send({ e: 'log', m: 'capture failed: ' + e });
    }
    return append.call(this, data);
  };

  window.__musifyGrabCmd = cmd => {
    const v = document.querySelector('video');
    if (cmd === 'restart') {
      // The audio was set up before the hooks: start it over.
      const p = document.querySelector('#movie_player');
      if (p && p.loadVideoById) p.loadVideoById(window.__musifyVideoId, 0);
      else if (v) v.currentTime = 0;
    }
  };

  let ended = false;
  setInterval(() => {
    const v = document.querySelector('video');
    if (!v) return;
    if (!v.__musifyHooked) {
      v.__musifyHooked = true;
      v.addEventListener('ended', () => { if (!isAd()) { ended = true; send({ e: 'ended' }); } });
    }
    // Quiet, and as fast as it'll go: the player fetches ahead by time.
    v.muted = true;
    v.volume = 0;
    if (!isAd()) {
      try { if (v.playbackRate < 16) v.playbackRate = 16; } catch (e) {
        try { v.playbackRate = 4; } catch (e) {}
      }
    }
    const skip = document.querySelector(
      '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
    if (skip) skip.click();
    if (v.paused && !v.ended) v.play().catch(() => {});
    send({
      e: 'tick', t: v.currentTime, d: v.duration || 0, ad: isAd(),
      rate: v.playbackRate, src: String(v.src || '').slice(0, 40), ended,
    });
  }, 500);
})();
''';
}

class _Job {
  final YouTubeTrack track;
  final void Function(double)? onProgress;
  final done = Completer<Uint8List>();

  _Job(this.track, this.onProgress);

  /// The audio pieces, per source buffer (an ad may get its own).
  final _chunks = <int, BytesBuilder>{};
  final _hasInit = <int>{};
  DateTime _lastNews = DateTime.now();
  Timer? _timer;
  int _restarts = 0;
  bool _loggedSource = false;
  bool _loggedRate = false;

  void watch({required VoidCallback onRestart}) {
    final started = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      // No audio setup seen: the player set up before the hooks went in.
      if (_hasInit.isEmpty &&
          now.difference(started) > Duration(seconds: 8 + 10 * _restarts)) {
        if (_restarts < 2) {
          _restarts++;
          AppLog.add('capture: no audio setup yet, restarting the video');
          onRestart();
        } else {
          fail("YouTube's player didn't hand over the audio");
        }
      }
      if (now.difference(_lastNews) > const Duration(seconds: 45)) {
        fail('YouTube stopped loading');
      }
    });
  }

  void onMessage(Map<String, dynamic> data) {
    if (done.isCompleted) return;
    switch (data['e']) {
      case 'chunk':
        final id = data['id'] as int;
        final bytes = base64.decode(data['b'] as String);
        if (data['init'] == true) _hasInit.add(id);
        (_chunks[id] ??= BytesBuilder(copy: false)).add(bytes);
        _lastNews = DateTime.now();
      case 'tick':
        final t = (data['t'] as num?)?.toDouble() ?? 0;
        final d = (data['d'] as num?)?.toDouble() ?? 0;
        if (!_loggedSource && d > 0) {
          _loggedSource = true;
          AppLog.add(
            'capture: video source ${data['src']}, '
            '${_chunks.isEmpty ? 'no audio pieces yet' : 'audio coming'}',
          );
        }
        if (!_loggedRate && t > 5) {
          _loggedRate = true;
          AppLog.add('capture: playing at ${data['rate']}x');
        }
        if (data['ad'] != true && d > 0) {
          onProgress?.call((t / d).clamp(0.0, 1.0));
          _lastNews = DateTime.now();
        }
        if (data['ended'] == true) _finish();
      case 'ended':
        _finish();
      case 'log':
        AppLog.add('capture: ${data['m']}');
    }
  }

  void _finish() {
    if (done.isCompleted) return;
    // The source buffer with the most audio is the song's (not an ad's).
    final best = _chunks.entries
        .where((e) => _hasInit.contains(e.key))
        .fold<MapEntry<int, BytesBuilder>?>(
          null,
          (best, e) =>
              best == null || e.value.length > best.value.length ? e : best,
        );
    if (best == null) {
      fail('no audio was handed over');
      return;
    }
    AppLog.add('capture: done, ${best.value.length} bytes');
    done.complete(best.value.takeBytes());
  }

  void fail(String why) {
    if (done.isCompleted) return;
    AppLog.add('capture: failed: $why');
    done.completeError(CaptureFailed(why));
  }

  void dispose() => _timer?.cancel();
}

class CaptureFailed implements Exception {
  final String reason;

  CaptureFailed(this.reason);

  @override
  String toString() => reason;
}

/// The capture's web view: in the tree only while one runs, out of sight.
class YouTubeCaptureHost extends StatelessWidget {
  const YouTubeCaptureHost({super.key});

  @override
  Widget build(BuildContext context) {
    if (WebViewPlatform.instance == null) return const SizedBox.shrink();
    final capture = YouTubeCapture.instance;
    return ListenableBuilder(
      listenable: capture,
      builder: (context, _) => !capture.busy
          ? const SizedBox.shrink()
          : IgnorePointer(
              child: Opacity(
                opacity: 0.01,
                child: SizedBox(
                  width: 2,
                  height: 2,
                  child: WebViewWidget(controller: capture.controller),
                ),
              ),
            ),
    );
  }
}
