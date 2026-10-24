import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/playback_session.dart';
import 'package:musify/services/player_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

/// The play order as song names, queued songs marked with *, and the
/// current one in [brackets].
String order(PlayerService service) {
  final current = service.player.currentIndex;
  final sequence = service.player.sequence;
  return [
    for (var i = 0; i < sequence.length; i++)
      () {
        final track = sequence[i].tag as Track;
        final name =
            '${p.basenameWithoutExtension(track.path)}'
            '${track is QueuedTrack ? '*' : ''}';
        return i == current ? '[$name]' : name;
      }(),
  ].join(' ');
}

Future<void> settle(PlayerService service) async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await service.idle;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();

  late Directory dir;
  late Playlist abcde;
  Track song(String name) => Track(p.join(dir.path, '$name.mp3'));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musify_queue');
    for (final name in 'a b c d e x1 x2 q1 q2'.split(' ')) {
      await File(p.join(dir.path, '$name.mp3')).create();
    }
    abcde = Playlist(
      id: dir.path,
      name: 'Songs',
      location: '.',
      tracks: [for (final n in 'abcde'.split('')) song(n)],
    );
  });

  tearDown(() => dir.delete(recursive: true));

  test('play next goes right after the current song, newest first; '
      'add to queue goes after those', () async {
    final service = PlayerService.fresh();
    await service.play(abcde, shuffle: false, startIndex: 0);
    await service.playNext(song('x1'));
    await service.addToQueue(song('q1'));
    await service.playNext(song('x2'));
    await service.addToQueue(song('q2'));
    await settle(service);
    expect(order(service), '[a] x2* x1* q1* q2* b c d e');
  });

  test('manually queued songs always come before the playlist', () async {
    final service = PlayerService.fresh();
    await service.play(abcde, shuffle: false, startIndex: 0);
    await service.addToQueue(song('q1'));
    await service.addToQueue(song('q2'));
    await service.playNext(song('x1'));
    await settle(service);
    expect(order(service), '[a] x1* q1* q2* b c d e');

    // Queued while a queued song plays: still ahead of the playlist.
    await service.next();
    await settle(service);
    await service.addToQueue(song('x2'));
    await settle(service);
    expect(order(service), 'a [x1*] q1* q2* x2* b c d e');
  });

  test('queued songs play once and survive changing songs', () async {
    final service = PlayerService.fresh();
    await service.play(abcde, shuffle: false, startIndex: 0);
    await service.playNext(song('x1'));
    await service.playNext(song('x2'));
    await service.addToQueue(song('q1'));
    await settle(service);

    await service.next();
    await settle(service);
    expect(order(service), 'a [x2*] x1* q1* b c d e');

    // Moving off a queued song removes it.
    await service.next();
    await settle(service);
    expect(order(service), 'a [x1*] q1* b c d e');

    // Tapping another song keeps what's still queued, right after it.
    await service.play(abcde, shuffle: false, startIndex: 3);
    await settle(service);
    expect(order(service), 'a b c [d] q1* e');

    await service.next();
    await settle(service);
    await service.next();
    await settle(service);
    expect(order(service), 'a b c d [e]');

    // With repeat-all the playlist loops; the queued songs don't come back.
    await service.next();
    await settle(service);
    expect(order(service), '[a] b c d e');
  });

  test('shuffle reorders only the rest of the playlist', () async {
    final service = PlayerService.fresh();
    await service.play(abcde, shuffle: false, startIndex: 2);
    await service.playNext(song('x1'));
    await service.addToQueue(song('q1'));
    await settle(service);

    await service.setShuffle(true);
    await settle(service);
    final shuffled = order(service).split(' ');
    expect(shuffled.take(3), ['[c]', 'x1*', 'q1*']);
    expect(shuffled.skip(3).toSet(), {'a', 'b', 'd', 'e'});
    expect(service.shuffleOn.value, isTrue);

    await service.setShuffle(false);
    await settle(service);
    expect(order(service), 'a b [c] x1* q1* d e');
  });

  test('the session comes back paused where it was', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [dir.path],
      'playback_session_v1': jsonEncode({
        'playlist': dir.path,
        'name': 'Songs',
        'tracks': [
          [song('a').path],
          [song('b').path],
          [song('x1').path, 1],
          [p.join(dir.path, 'gone.mp3')],
          [song('c').path],
        ],
        'index': 1,
        'position': 42000,
        'shuffle': true,
        'loop': 'one',
      }),
    });
    addTearDown(PlaybackSession.reset);
    await PlaybackSession.start();
    final service = PlayerService.instance;
    await settle(service);

    expect(order(service), 'a [b] x1* c');
    expect(service.player.position, const Duration(seconds: 42));
    expect(service.player.playing, isFalse);
    expect(service.shuffleOn.value, isTrue);
    expect(service.player.loopMode.name, 'one');
    expect(service.current?.id, dir.path);

    // Changes are saved again.
    await service.addToQueue(song('q1'));
    await settle(service);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('playback_session_v1')!);
    expect(saved['tracks'], [
      [song('a').path],
      [song('b').path],
      [song('x1').path, 1],
      [song('q1').path, 1],
      [song('c').path],
    ]);
  });

  group('a big playlist goes to the player a window at a time', () {
    late Playlist big;
    setUp(() async {
      PlayerService.window = 4;
      for (var i = 0; i < 20; i++) {
        await File(p.join(dir.path, 's$i.mp3')).create();
      }
      big = Playlist(
        id: dir.path,
        name: 'Big',
        location: '.',
        tracks: [for (var i = 0; i < 20; i++) song('s$i')],
      );
    });
    tearDown(() => PlayerService.window = 50);

    test('it moves along with playback and wraps round', () async {
      final service = PlayerService.fresh();
      await service.play(big, shuffle: false, startIndex: 0);
      await settle(service);
      expect(order(service), 's18 s19 [s0] s1 s2 s3 s4');

      await service.next();
      await service.next();
      await service.next();
      await settle(service);
      expect(order(service), 's1 s2 [s3] s4 s5 s6 s7');

      for (var i = 0; i < 20; i++) {
        await service.next();
        await settle(service);
      }
      expect(service.currentTrack?.path, song('s3').path);
      expect(service.player.sequence.length, lessThanOrEqualTo(9));
      expect(service.order.length, 20);
    });

    test('queued songs stay put; shuffle still plays each song once', () async {
      final service = PlayerService.fresh();
      await service.play(big, shuffle: false, startIndex: 10);
      await service.playNext(song('x1'));
      await settle(service);
      expect(order(service), 's8 s9 [s10] x1* s11 s12 s13 s14');

      await service.setShuffle(true);
      await settle(service);
      expect(service.order.length, 20);
      expect(service.order.map((t) => t.path).toSet().length, 20);
      final shown = order(service).split(' ');
      expect(shown.skip(shown.indexOf('[s10]')).take(2), ['[s10]', 'x1*']);
    });

    test('repeat off stops at the end of the playlist', () async {
      final service = PlayerService.fresh();
      await service.play(big, shuffle: false, startIndex: 16);
      await service.player.setLoopMode(LoopMode.off);
      await settle(service);
      for (var i = 0; i < 5; i++) {
        await service.next();
        await settle(service);
      }
      expect(service.currentTrack?.path, song('s19').path);
      expect(service.neighbour(1), isNull);
    });

    test('the session keeps the whole playlist, not just the window', () async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(PlaybackSession.reset);
      await PlaybackSession.start();
      final service = PlayerService.instance;
      await service.clearQueue();
      await service.play(big, shuffle: false, startIndex: 5);
      await settle(service);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('playback_session_v1')!);
      final savedOrder = jsonDecode(prefs.getString('playback_order_v1')!);
      expect((saved['tracks'] as List).length, 7);
      expect((savedOrder as List).length, 20);

      await service.restore(
        playlist: big,
        sequence: [
          for (final t in saved['tracks'] as List) Track((t as List)[0]),
        ],
        order: [for (final t in savedOrder) Track((t as List)[0])],
        index: saved['index'] as int,
        position: Duration.zero,
        shuffle: false,
        loop: LoopMode.all,
      );
      await settle(service);
      expect(order(service), 's3 s4 [s5] s6 s7 s8 s9');
      expect(service.order.length, 20);
      for (var i = 0; i < 10; i++) {
        await service.next();
        await settle(service);
      }
      expect(service.currentTrack?.path, song('s15').path);
    });
  });
}
