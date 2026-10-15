import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/musify_server.dart';
import 'package:musify/services/player_service.dart';

import 'support/fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = FakeJustAudio();
  JustAudioPlatform.instance = fake;
  // just_audio copies the silent asset into the temporary folder.
  final temp = Directory.systemTemp.createTempSync('musify_yt');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => temp.path,
      );
  tearDownAll(() => temp.deleteSync(recursive: true));

  YouTubeTrack video(String id, {Duration? length}) => YouTubeTrack(
    videoId: id,
    name: 'Song $id',
    channel: 'Channel',
    length: length ?? const Duration(minutes: 3, seconds: 30),
  );

  test(
    'a YouTube song plays as silence its own length, plus a moment',
    () async {
      final service = PlayerService.fresh();
      await service.playYouTube([video('a'), video('b')], 1);
      final sequence = service.player.sequence;
      expect(
        [for (final s in sequence) (s.tag as YouTubeTrack).videoId],
        ['a', 'b'],
      );
      expect(service.player.currentIndex, 1);
      final source = sequence[1] as ClippingAudioSource;
      expect(source.child.uri.toString(), contains('silence.m4a'));
      expect(source.end, const Duration(minutes: 3, seconds: 32));
    },
  );

  test('queued YouTube songs play once, and stay YouTube songs', () async {
    final service = PlayerService.fresh();
    await service.playYouTube([video('a'), video('b')], 0);
    await service.playNext(video('x'));
    await service.idle;
    final tags = [for (final s in service.player.sequence) s.tag];
    expect(tags[1], isA<QueuedYouTubeTrack>());
    expect((tags[1] as YouTubeTrack).videoId, 'x');
    expect(tags[1], isA<QueuedTrack>());
  });

  test('with a server, the song playing and the next stream from it, the '
      "rest wait; if streaming fails, YouTube's player takes over", () async {
    MusifyServer.instance.debugUse(key: 'secret', charts: const []);
    // Songs the server has already.
    for (final id in 'abcdef'.split('')) {
      MusifyServer.instance.debugReady(id);
    }
    final service = PlayerService.fresh();
    final songs = [for (final id in 'abcdef'.split('')) video(id)];
    await service.playYouTube(songs, 0);
    await service.idle;
    List<bool> streamed() => [
      for (final s in service.player.sequence) !PlayerService.isWebSource(s),
    ];
    expect(streamed(), [true, true, false, false, false, false]);
    expect(
      (service.player.sequence[0] as UriAudioSource).uri.toString(),
      'https://musify.example.com/audio/a.m4a?key=secret',
    );

    // On to the next song: the one after it streams now too.
    await service.player.seekToNext();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.idle;
    expect(streamed(), [true, true, true, false, false, false]);

    await service.player.seek(const Duration(seconds: 42));
    fake.last!.fail('stream failed');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.idle;
    final now = service.player.sequence;
    expect([
      for (final s in now) (s.tag as YouTubeTrack).videoId,
    ], 'abcdef'.split(''));
    expect(PlayerService.isWebSource(now[1]), isTrue, reason: 'no retry');
    expect(service.player.currentIndex, 1);
    expect(service.player.position.inSeconds, 42);
  });

  test("a song the server hasn't got yet starts in YouTube's player", () async {
    MusifyServer.instance.debugUse(key: 'secret', charts: const []);
    final service = PlayerService.fresh();
    // The server (made up) can't be reached: it stays in YouTube's player.
    await service.playYouTube([video('new1'), video('new2')], 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await service.idle;
    expect(PlayerService.isWebSource(service.player.sequence[0]), isTrue);
    expect(PlayerService.isWebSource(service.player.sequence[1]), isTrue);
  });

  test('once the server has it, the song moves over to the stream', () async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    // A server that takes a moment to fetch the song from YouTube.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      request.response
        ..statusCode = 206
        ..headers.set('Content-Range', 'bytes 0-0/1')
        ..add([0]);
      await request.response.close();
    });
    await MusifyServer.instance.setUp('http://127.0.0.1:${server.port}', 'k');
    final service = PlayerService.fresh();
    await service.playYouTube([video('late1'), video('late2')], 0);
    // Not there within 600 ms: YouTube's player starts it.
    expect(PlayerService.isWebSource(service.player.sequence[0]), isTrue);
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.idle;
      if (!PlayerService.isWebSource(service.player.sequence[0]) &&
          !PlayerService.isWebSource(service.player.sequence[1])) {
        break;
      }
    }
    expect(PlayerService.isWebSource(service.player.sequence[0]), isFalse);
    expect(PlayerService.isWebSource(service.player.sequence[1]), isFalse);
    expect(service.player.currentIndex, 0);
    expect(
      [
        for (final s in service.player.sequence)
          (s.tag as YouTubeTrack).videoId,
      ],
      ['late1', 'late2'],
    );
  });
}
