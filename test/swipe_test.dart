import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/main.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/widgets/mini_player.dart';
import 'package:musify/widgets/track_swiper.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('swiping the mini player never flicks back', (tester) async {
    final music = Directory.systemTemp.createTempSync('musify_swipe');
    addTearDown(() => music.deleteSync(recursive: true));
    for (final name in ['Alpha', 'Bravo', 'Charlie']) {
      File(p.join(music.path, 'Songs', '$name.mp3'))
          .createSync(recursive: true);
    }
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

    final swiper = find.descendant(
      of: find.byType(MiniPlayer),
      matching: find.byType(TrackSwiper),
    );
    final centre = tester.getCenter(swiper);
    final left = tester.getRect(swiper).left;

    /// The song whose title sits where a settled page puts it, just right
    /// of the cover.
    String shown() {
      for (final name in ['Alpha', 'Bravo', 'Charlie']) {
        final hits = find.descendant(of: swiper, matching: find.text(name));
        for (final e in hits.evaluate()) {
          final x = (e.renderObject as RenderBox).localToGlobal(Offset.zero).dx;
          if ((x - left - 50).abs() < 20) return name;
        }
      }
      return '?';
    }

    expect(shown(), 'Alpha');
    await tester.timedDragFrom(
      centre,
      const Offset(-220, 0),
      const Duration(milliseconds: 250),
    );
    final seen = <String>[];
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      seen.add(shown());
    }
    expect(PlayerService.instance.currentTrack?.title, 'Bravo');
    final arrived = seen.indexOf('Bravo');
    expect(arrived, isNonNegative, reason: '$seen');
    expect(
      seen.skip(arrived).where((s) => s == 'Alpha'),
      isEmpty,
      reason: 'flicked back to the old song: $seen',
    );

    // Pausing stops the player's position updates (a periodic timer).
    await tester.runAsync(PlayerService.instance.player.pause);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
