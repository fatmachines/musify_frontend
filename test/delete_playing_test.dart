import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/player_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();

  late Directory dir;
  late Playlist songs;
  Track song(String name) => Track(p.join(dir.path, '$name.mp3'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('musify_delete');
    for (final name in 'abc'.split('')) {
      await File(p.join(dir.path, '$name.mp3')).create();
    }
    songs = Playlist(
      id: dir.path,
      name: 'Songs',
      location: '.',
      tracks: [for (final n in 'abc'.split('')) song(n)],
    );
    await PlayerService.instance.play(songs, shuffle: false, startIndex: 0);
    await PlayerService.instance.idle;
  });

  tearDown(() async {
    await PlayerService.instance.stop();
    await dir.delete(recursive: true);
  });

  test("a delete that fails doesn't touch what's playing", () async {
    final player = PlayerService.instance;
    // Gone already, so deleting it fails (as Android refuses it).
    await File(song('a').path).delete();
    expect(await Library.instance.deleteSong(song('a')), isFalse);
    expect(player.currentTrack?.path, song('a').path);
    expect(player.player.playing, isTrue);
  });

  test('deleting the song playing moves on to the next', () async {
    final player = PlayerService.instance;
    expect(await Library.instance.deleteSong(song('a')), isTrue);
    await player.idle;
    expect(File(song('a').path).existsSync(), isFalse);
    expect(player.currentTrack?.path, song('b').path);
  });
}
