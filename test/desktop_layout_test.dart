import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/desktop/desktop_shell.dart';
import 'package:musify/main.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/tabs/search_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  test('only wide windows that are not phones get the desktop layout', () {
    expect(DesktopShell.fits(const Size(1440, 900)), isTrue); // Mac
    expect(DesktopShell.fits(Size(1194, 834)), isTrue); // iPad, wide
    expect(DesktopShell.fits(Size(834, 1194)), isFalse); // iPad, tall
    expect(DesktopShell.fits(Size(932, 430)), isFalse); // iPhone, wide
    expect(DesktopShell.fits(Size(393, 852)), isFalse); // iPhone
  });

  testWidgets('typing in the top bar opens Search in the main panel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MusifyApp());
    await tester.pump();
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(SearchTab), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'love');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SearchTab), findsOneWidget);

    // Home goes back to the start and clears the search.
    await tester.tap(find.byTooltip('Home'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SearchTab), findsNothing);
    expect(find.text('love'), findsNothing);
    // Let the YouTube search's wait run out.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('space in the search field is typed, not play/pause', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MusifyApp());
    await tester.pump();
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    // ignore: avoid_print
    print(
      'focus: ${FocusManager.instance.primaryFocus} playing before: ${PlayerService.instance.player.playing}',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    // The field kept the keyboard (opening Search didn't take it), and
    // space didn't reach the player.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(PlayerService.instance.player.playing, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('space plays and pauses after leaving the search field', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MusifyApp());
    await tester.pump();
    // In and out of the search field: the keyboard focus goes up a level.
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // Space still reaches play/pause.
    var pressed = 0;
    DesktopShell.debugSpace = () => pressed++;
    addTearDown(() => DesktopShell.debugSpace = null);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isTrue);
    expect(pressed, 1);
    // Typing in the search field again: space is the field's.
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 1);
    await tester.pump(const Duration(seconds: 1));
  });
}
