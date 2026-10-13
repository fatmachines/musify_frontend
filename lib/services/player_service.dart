import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playlist.dart';
import 'app_log.dart';

/// An active sleep timer: either a time to stop at, or the end of the
/// current song.
class SleepTimer {
  final DateTime? endsAt;

  const SleepTimer.at(DateTime this.endsAt);
  const SleepTimer.endOfTrack() : endsAt = null;

  bool get endOfTrack => endsAt == null;
}

/// The one audio player in the app. A playlist is loaded as a looping queue,
/// so both in-order and shuffled playback keep going until paused.
class PlayerService {
  PlayerService._();

  static final instance = PlayerService._();

  // Created on first use so widget tests never touch the audio plugin.
  late final player = AudioPlayer();

  Playlist? _loaded;

  final sleepTimer = ValueNotifier<SleepTimer?>(null);
  Timer? _sleepClock;
  StreamSubscription? _sleepTrackWatch;

  static Future<void> init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      AppLog.add('player: audio session setup failed: $e');
    }
  }

  /// The playlist whose songs are in the queue.
  Playlist? get current => _loaded;

  bool isCurrent(Playlist playlist) =>
      _loaded?.path == playlist.path &&
      _loaded?.tracks.length == playlist.tracks.length;

  Track? get currentTrack => _trackOf(player.sequenceState);

  /// The song playing (or paused), or null before anything was played.
  Stream<Track?> get trackStream => player.sequenceStateStream
      .map(_trackOf)
      .distinct((a, b) => a?.path == b?.path);

  static Track? _trackOf(SequenceState state) {
    final tag = state.currentSource?.tag;
    return tag is Track ? tag : null;
  }

  /// Starts [playlist] at [startIndex]. Without one, it starts at the top,
  /// or on a random song when shuffling.
  Future<void> play(
    Playlist playlist, {
    required bool shuffle,
    int? startIndex,
  }) async {
    final tracks = playlist.tracks;
    if (tracks.isEmpty) return;
    final index = startIndex ?? (shuffle ? Random().nextInt(tracks.length) : 0);

    if (isCurrent(playlist)) {
      await player.seek(Duration.zero, index: index);
    } else {
      await player.setAudioSources([
        for (final t in tracks) AudioSource.file(t.path, tag: t),
      ], initialIndex: index);
      _loaded = playlist;
      await player.setLoopMode(LoopMode.all);
    }
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

  /// The song [offset] places away from the current one in play order
  /// (shuffled or not), or null at either end with repeat off. Unlike
  /// just_audio's own next/previous, repeat-one still moves on, as Spotify
  /// does when you skip.
  Track? neighbour(int offset) {
    final index = _neighbourIndex(offset);
    if (index == null) return null;
    final tag = player.sequence[index].tag;
    return tag is Track ? tag : null;
  }

  int? _neighbourIndex(int offset) {
    final current = player.currentIndex;
    if (current == null) return null;
    final order = player.effectiveIndices;
    final position = order.indexOf(current);
    if (position < 0) return null;
    var target = position + offset;
    if (target < 0 || target >= order.length) {
      if (player.loopMode == LoopMode.off) return null;
      target %= order.length;
    }
    final index = order[target];
    return index == current ? null : index;
  }

  /// Moves [offset] songs along the play order, starting it from the top.
  Future<void> skip(int offset) async {
    final index = _neighbourIndex(offset);
    if (index != null) await player.seek(Duration.zero, index: index);
  }

  Future<void> next() => skip(1);

  /// Like Spotify: restarts the song unless it has only just begun.
  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) ||
        _neighbourIndex(-1) == null) {
      await player.seek(Duration.zero);
    } else {
      await skip(-1);
    }
  }

  /// Repeat cycles all → one → off.
  Future<void> cycleRepeat() {
    final next = switch (player.loopMode) {
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
      LoopMode.off => LoopMode.all,
    };
    return player.setLoopMode(next);
  }

  /// Pauses after [duration], or when the current song ends if [endOfTrack].
  /// Passing neither cancels the timer.
  void setSleepTimer({Duration? duration, bool endOfTrack = false}) {
    _sleepClock?.cancel();
    _sleepTrackWatch?.cancel();
    _sleepClock = null;
    _sleepTrackWatch = null;

    if (duration != null) {
      _sleepClock = Timer(duration, _sleep);
      sleepTimer.value = SleepTimer.at(DateTime.now().add(duration));
    } else if (endOfTrack) {
      final index = player.currentIndex;
      _sleepTrackWatch = player.positionDiscontinuityStream
          .where(
            (d) =>
                d.reason == PositionDiscontinuityReason.autoAdvance ||
                player.currentIndex != index,
          )
          .listen((_) => _sleep());
      sleepTimer.value = const SleepTimer.endOfTrack();
    } else {
      sleepTimer.value = null;
    }
  }

  void _sleep() {
    AppLog.add('player: sleep timer stopped playback');
    player.pause();
    setSleepTimer();
  }
}
