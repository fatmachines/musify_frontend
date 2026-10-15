import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/services/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();

  test('shuffle is remembered from one launch to the next', () async {
    SharedPreferences.setMockInitialValues({'shuffle_on': true});
    await PlayerService.init();
    final shuffle = PlayerService.instance.shuffleOn;
    expect(shuffle.value, isTrue, reason: 'as left last time');

    shuffle.value = false;
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('shuffle_on'), isFalse);
  });
}
