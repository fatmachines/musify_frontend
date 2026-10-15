import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/screens/playlist_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('tapping the open tab again goes back to its first page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MusifyApp());
    await tester.tap(find.text('Your Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Liked Songs').first);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistScreen), findsOneWidget);

    await tester.tap(find.text('Your Library').last);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistScreen), findsNothing);
  });
}
