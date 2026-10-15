import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('Back on Home sends the app to the background, once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('musify/app'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    await tester.pumpWidget(const MusifyApp());
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(calls, ['toBackground']);
    expect(find.text('Your Library'), findsOneWidget, reason: 'still there');
  });

  testWidgets('Back on another tab goes to Home first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('musify/app'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    await tester.pumpWidget(const MusifyApp());
    await tester.tap(find.text('Your Library'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });
}
