import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playlist.dart';
import 'app_log.dart';

/// The one audio player in the app. A playlist is loaded as a looping queue,
/// so both in-order and shuffled playback keep going until paused.
class PlayerService {
  PlayerService._();

  static final instance = PlayerService._();

  // Created on first use so widget tests never touch the audio plugin.
  late final player = AudioPlayer();

  Playlist? _loaded;

  static Future<void> init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      AppLog.add('player: audio session setup failed: $e');
    }
  }

  bool isCurrent(Playlist playlist) =>
      _loaded?.path == playlist.path &&
      _loaded?.tracks.length == playlist.tracks.length;

  /// Starts [playlist] at [startIndex]. Without one, it starts at the top,
  /// or on a random song when shuffling.
  Future<void> play(
    Playlist playlist, {
    required bool shuffle,
    int? startIndex,
  }) async {
    final tracks = playlist.tracks;
    if (tracks.isEmpty) return;
    final index =
        startIndex ?? (shuffle ? Random().nextInt(tracks.length) : 0);

    if (isCurrent(playlist)) {
      await player.seek(Duration.zero, index: index);
    } else {
      await player.setAudioSources(
        [for (final t in tracks) AudioSource.file(t.path, tag: t)],
        initialIndex: index,
      );
      _loaded = playlist;
    }
    await player.setLoopMode(LoopMode.all);
    await setShuffle(shuffle);
    AppLog.add('player: ${playlist.name} from #$index shuffle=$shuffle');
    // play() completes only when playback stops, so don't wait on it.
    player.play();
  }

  /// Turning shuffle on deals a fresh random order that keeps the current
  /// song first.
  Future<void> setShuffle(bool enabled) async {
    await player.setShuffleModeEnabled(enabled);
    if (enabled) await player.shuffle();
  }

  Future<void> togglePlayback() =>
      player.playing ? player.pause() : player.play();
}
