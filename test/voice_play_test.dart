import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/services/voice_play.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();

  late Directory music;
  final player = PlayerService.instance;
  String? playing() => player.currentTrack == null
      ? null
      : p.basename(player.currentTrack!.path);

  setUpAll(() async {
    music = await Directory.systemTemp.createTemp('musify_voice');
    for (final song in [
      'Rock/Kesariya.mp3',
      'Rock/Tum Hi Ho.mp3',
      'Lo-Fi/Rainy Window.mp3',
      'Lo-Fi/Kesariya (Lofi).mp3',
    ]) {
      await File(p.join(music.path, song)).create(recursive: true);
    }
    SharedPreferences.setMockInitialValues({
      'library_folders': [music.path],
    });
    await Library.instance.ensureLoaded();
  });

  tearDownAll(() => music.delete(recursive: true));

  test('nothing playing and nothing named: plays something', () async {
    expect(await VoicePlay.play(null), isTrue);
    expect(playing(), isNotNull);
  });

  test('a song by name, the exact title first', () async {
    expect(await VoicePlay.play('kesariya'), isTrue);
    expect(playing(), 'Kesariya.mp3');
    expect(player.current?.name, 'Rock');

    expect(await VoicePlay.play('tum hi ho', kind: VoiceKind.song), isTrue);
    expect(playing(), 'Tum Hi Ho.mp3');
  });

  test('a playlist by name', () async {
    expect(await VoicePlay.play('the Lo-Fi playlist'), isTrue);
    expect(player.current?.name, 'Lo-Fi');
  });

  test('liked songs', () async {
    final song = Library.instance.allSongs.firstWhere(
      (t) => t.path.endsWith('Rainy Window.mp3'),
    );
    Library.instance.toggleLike(song);
    expect(await VoicePlay.play('my liked songs'), isTrue);
    expect(player.current?.id, Library.likedId);
    expect(playing(), 'Rainy Window.mp3');
  });

  test('nothing matches', () async {
    expect(await VoicePlay.play('nonexistent tune'), isFalse);
  });
}
