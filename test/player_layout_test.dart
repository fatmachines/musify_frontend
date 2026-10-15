import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/screens/now_playing.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/metadata_service.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/widgets/mini_player.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets("lyrics don't move the controls, and the player still "
      'drags closed', (tester) async {
    final music = Directory.systemTemp.createTempSync('musify_layout');
    addTearDown(() => music.deleteSync(recursive: true));
    File(p.join(music.path, 'Songs', 'Alpha.mp3')).createSync(recursive: true);
    // Has lyrics (and the title "Lyrical").
    File('test/fixtures/txxx_lyrics.mp3')
        .copySync(p.join(music.path, 'Songs', 'Bravo.mp3'));
    SharedPreferences.setMockInitialValues({
      'library_folders': [music.path],
    });
    await tester.runAsync(() async {
      await Library.instance.ensureLoaded();
      final songs = Library.instance.all.firstWhere((pl) => pl.name == 'Songs');
      await MetadataService.loadInfo(songs.tracks);
      await PlayerService.instance.play(songs, shuffle: false);
    });
    await tester.pumpWidget(const MusifyApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();

    Rect like() => tester.getRect(
      find.descendant(
        of: find.byType(NowPlaying),
        matching: find.byTooltip('Like'),
      ),
    );
    final without = like();
    await tester.runAsync(() => PlayerService.instance.skip(1));
    await tester.pumpAndSettle();
    expect(find.text('Lyrical'), findsWidgets);
    expect(find.text('Lyrics preview'), findsOneWidget);
    expect(like(), without, reason: 'same place with lyrics');

    // Pulled down from the title: closes.
    await tester.fling(find.text('Lyrical').last, const Offset(0, 400), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(NowPlaying), findsNothing);

    await tester.runAsync(PlayerService.instance.player.pause);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
