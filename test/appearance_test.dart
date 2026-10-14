import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/services/appearance.dart';
import 'package:musify/tabs/settings_tab.dart';
import 'package:musify/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  for (final (name, size) in [
    ('phone', const Size(393, 852)),
    ('Mac', const Size(1440, 900)),
  ]) {
    testWidgets('changing the theme stays on Settings ($name)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      Appearance.mode.value = ThemeMode.dark;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MusifyApp());
      await tester.pump();
      if (name == 'phone') {
        await tester.tap(find.text('Settings').last);
      } else {
        await tester.tap(find.byTooltip('Settings'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SettingsTab), findsOneWidget);

      await tester.tap(find.text('Light'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(AppColors.dark, isFalse);
      expect(find.byType(SettingsTab), findsOneWidget);
      // Every widget picked the new colours up.
      final title = tester.widget<Text>(find.text('Light'));
      expect(
        DefaultTextStyle.of(tester.element(find.text('Light'))).style.color ??
            title.style?.color,
        isNot(Colors.white),
      );
      Appearance.mode.value = ThemeMode.dark;
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
