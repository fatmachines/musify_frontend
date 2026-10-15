import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/widgets/mini_player.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('a screen reader finds the full player, not the page under it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final music = Directory.systemTemp.createTempSync('musify_semantics');
    addTearDown(() => music.deleteSync(recursive: true));
    File(
      p.join(music.path, 'Songs', 'Alpha.mp3'),
    ).createSync(recursive: true);
    SharedPreferences.setMockInitialValues({
      'library_folders': [music.path],
    });
    await tester.runAsync(() async {
      await Library.instance.ensureLoaded();
      await PlayerService.instance.play(
        Library.instance.all.firstWhere((pl) => pl.name == 'Songs'),
        shuffle: false,
      );
    });
    await tester.pumpWidget(const MusifyApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.semantics.byLabel('Your Library'), findsOne);

    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(find.semantics.byLabel('Your Library'), findsNothing);
    // The player's own controls are there.
    expect(
      find.semantics.byPredicate((node) => node.label.contains('Alpha')),
      findsWidgets,
    );

    await tester.runAsync(PlayerService.instance.player.pause);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    semantics.dispose();
  });
}
