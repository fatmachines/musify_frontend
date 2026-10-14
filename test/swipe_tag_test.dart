import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/services/library.dart';
import 'package:musify/theme.dart';
import 'package:musify/widgets/song_tile.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('swipe left: the tag sheet, or off with the tags', (
    tester,
  ) async {
    final music = Directory.systemTemp.createTempSync('musify_swipetag');
    addTearDown(() => music.deleteSync(recursive: true));
    File(p.join(music.path, 'song.mp3')).createSync();
    SharedPreferences.setMockInitialValues({
      'library_folders': [music.path],
    });
    final library = Library.instance;
    await tester.runAsync(library.ensureLoaded);
    final song = library.allSongs.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: library,
            builder: (context, _) =>
                SongTile(track: song, onTap: () {}, onMore: () {}),
          ),
        ),
      ),
    );

    Future<void> swipeLeft() async {
      await tester.timedDrag(
        find.byType(SongTile),
        const Offset(-200, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    // Not tagged: the sheet to pick a tag; nothing tagged yet.
    await swipeLeft();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(library.tagsOf(song), isEmpty);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pump(const Duration(milliseconds: 500));

    // Tagged: the swipe takes the tag off, no sheet.
    library.toggleTag(song, library.tags.first);
    await tester.pump();
    await swipeLeft();
    expect(library.tagsOf(song), isEmpty);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}
