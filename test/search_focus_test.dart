import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  bool searchFocused(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

  testWidgets('tapping Search again starts a search', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MusifyApp());
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(searchFocused(tester), isFalse);

    await tester.tap(find.text('Search').last);
    await tester.pumpAndSettle();
    expect(searchFocused(tester), isTrue);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'keyboard shown');
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('the whole search bar opens the keyboard', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MusifyApp());
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    // The field's own magnifier, not the text line (or the tab bar's).
    final fieldRow = find.ancestor(
      of: find.byType(TextField),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(of: fieldRow.first, matching: find.byIcon(Icons.search)),
    );
    await tester.pumpAndSettle();
    expect(searchFocused(tester), isTrue);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'keyboard shown');
  });
}
