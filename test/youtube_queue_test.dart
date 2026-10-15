import 'dart:io';

import 'package:flutter/services.dart';
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

  test('with a server, YouTube songs stream from it; if that fails, '
      "YouTube's player takes over where it was", () async {
    MusifyServer.instance.debugUse(key: 'secret', charts: const []);
    final service = PlayerService.fresh();
    await service.playYouTube([video('a'), video('b')], 0);
    final streamed = service.player.sequence[0] as UriAudioSource;
    expect(
      streamed.uri.toString(),
      'https://musify.example.com/audio/a.m4a?key=secret',
    );
    expect(PlayerService.isWebSource(streamed), isFalse);

    await service.player.seek(const Duration(seconds: 42));
    fake.last!.fail('stream failed');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.idle;
    final now = service.player.sequence;
    expect([for (final s in now) (s.tag as YouTubeTrack).videoId], ['a', 'b']);
    expect(PlayerService.isWebSource(now[0]), isTrue);
    expect(now[1], isA<UriAudioSource>(), reason: 'the rest still stream');
    expect(service.player.currentIndex, 0);
    expect(service.player.position.inSeconds, 42);
  });
}
