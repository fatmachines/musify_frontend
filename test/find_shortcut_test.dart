import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/services/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('Cmd+F: the playlist\'s own search, else the top bar\'s', (
    tester,
  ) async {
    final music = Directory.systemTemp.createTempSync('musify_find');
    addTearDown(() => music.deleteSync(recursive: true));
    File('${music.path}/Rock/song.mp3').createSync(recursive: true);
    SharedPreferences.setMockInitialValues({
      'library_folders': [music.path],
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Library.instance.ensureLoaded);
    await tester.pumpWidget(const MusifyApp());
    await tester.pump();
    Future<void> cmdF() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    // Home: the top bar's search.
    await cmdF();
    final top = tester.widget<TextField>(find.byType(TextField).first);
    expect(top.focusNode!.hasFocus, isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    // In a playlist: its "Find on this page".
    await tester.tap(find.text('Rock').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await cmdF();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<TextField>()?.decoration?.hintText,
      'Find on this page',
    );
    await tester.pump(const Duration(seconds: 1));
  });
}
