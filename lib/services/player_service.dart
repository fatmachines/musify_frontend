import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'equalizer_service.dart';
import 'library.dart';
import 'local_copies.dart';
import 'musify_server.dart';

/// An active sleep timer: either a time to stop at, or the end of the
/// current song.
class SleepTimer {
  final DateTime? endsAt;

  const SleepTimer.at(DateTime this.endsAt);
  const SleepTimer.endOfTrack() : endsAt = null;

  bool get endOfTrack => endsAt == null;
}

/// The one audio player in the app.
///
/// just_audio plays a flat list in order; Musify decides that order itself
/// (rather than using just_audio's shuffle) so queued songs land exactly
/// where Spotify puts them:
///
///   ...songs before | current | play next (newest first) | add to queue
///   (oldest first) | rest of the playlist
///
/// The playlist part holds each of its songs once, shuffled or not, so with
/// repeat-all the list loops. A queued song ([QueuedTrack]) plays once and is
/// removed as soon as playback moves off it, so it never comes round again.
class PlayerService {
  @visibleForTesting
  PlayerService.fresh();

  static final instance = PlayerService.fresh();

  // Created on first use so widget tests never touch the audio plugin.
  AudioPlayer? _player;
  AudioPlayer get player => _player ??= _create();

  Playlist? _loaded;

  /// Whether the playlist part plays shuffled.
  final shuffleOn = ValueNotifier<bool>(false);

  /// Queue edits run one at a time, in order.
  Future<void> _pending = Future.value();

  IndexedAudioSource? _lastSource;

  /// Repeat starts as "all" until the user (or a restored session) picks.
  bool _loopChosen = false;

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

  AudioPlayer _create() {
    final androidEq = EqualizerService.instance.android;
    final player = AudioPlayer(
      // Handled below, so YouTube's video starting doesn't pause us.
      handleInterruptions: false,
      audioPipeline: androidEq == null
          ? null
          : AudioPipeline(androidAudioEffects: [androidEq]),
    );
    player.currentIndexStream.listen((_) {
      _dropPlayedQueue();
      _warmNext(player);
    });
    player.errorStream.listen((e) => _streamFailed(player, e));
    _handleInterruptions(player);
    return player;
  }

  /// Whether [source] is a YouTube song played in YouTube's player (a
  /// silent stand-in), not streamed from the server.
  static bool isWebSource(IndexedAudioSource? source) =>
      source is ClippingAudioSource && source.tag is YouTubeTrack;

  /// The next YouTube songs to stream get fetched by the server ahead of
  /// time, so one starts as the last ends.
  static void _warmNext(AudioPlayer player) {
    final index = player.currentIndex;
    if (index == null) return;
    final sequence = player.sequence;
    var warmed = 0;
    for (var i = index + 1; i < sequence.length && warmed < 2; i++) {
      final source = sequence[i];
      final tag = source.tag;
      if (tag is YouTubeTrack && !isWebSource(source)) {
        MusifyServer.instance.warm(tag);
        warmed++;
      }
    }
  }

  /// A YouTube song the server couldn't stream (down, or YouTube said no)
  /// plays in YouTube's own player instead, from where it was.
  void _streamFailed(AudioPlayer player, PlayerException error) =>
      _serial(() async {
        final index = player.currentIndex;
        if (index == null || index >= player.sequence.length) return;
        final source = player.sequence[index];
        final track = source.tag;
        if (track is! YouTubeTrack || isWebSource(source)) return;
        AppLog.add(
          'player: streaming ${track.name} failed (${error.message}); '
          "YouTube's player instead",
        );
        final position = player.position;
        await player.removeAudioSourceAt(index);
        await player.insertAudioSource(index, _webSource(track));
        await player.seek(position, index: index);
        player.play();
      });

  /// Like just_audio's own handling (pause for a call or another app, play
  /// again after; pause when headphones come out), except while a YouTube
  /// song plays in the web view: its video starting counts as an
  /// interruption on iOS, which would pause the stand-in, and with it the
  /// video. The video looks after real interruptions itself.
  void _handleInterruptions(AudioPlayer player) {
    var interrupted = false;
    AudioSession.instance.then((session) {
      session.becomingNoisyEventStream.listen((_) {
        AppLog.add('player: headphones out, pausing');
        player.pause();
      });
      session.interruptionEventStream.listen((event) {
        if (event.type == AudioInterruptionType.duck) return;
        // Streamed YouTube songs are like any other.
        final youtube = isWebSource(player.sequenceState.currentSource);
        AppLog.add(
          'player: interruption ${event.begin ? 'began' : 'ended'} '
          '(${event.type.name})${youtube ? ', ignored for YouTube' : ''}',
        );
        if (event.begin) {
          interrupted = false;
          if (youtube || !player.playing) return;
          player.pause();
          interrupted = true;
        } else {
          if (interrupted && event.type == AudioInterruptionType.pause) {
            player.play();
          }
          interrupted = false;
        }
      });
    });
  }

  /// Completes once queued edits so far have been applied.
  @visibleForTesting
  Future<void> get idle => _pending;

  Future<void> _serial(Future<void> Function() task) {
    final next = _pending.then((_) => task()).catchError((Object e) {
      AppLog.add('player: $e');
    });
    _pending = next;
    return next;
  }

  /// The playlist whose songs are in the queue.
  Playlist? get current => _loaded;

  bool isCurrent(Playlist playlist) =>
      _loaded?.id == playlist.id &&
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

  /// A YouTube song is a silent stand-in of its length (plus a moment, so
  /// it's the video's own end that moves on); YouTubeWebPlayer plays the
  /// real thing.
  ///
  /// With a Musify server, a YouTube song streams from it instead, played
  /// by the system's own player like any song: so it carries on after a
  /// call, from Control Center, and into the next song in the background,
  /// none of which a web view in the background can be relied on for.
  static AudioSource _source(Track track) {
    if (track is! YouTubeTrack) return AudioSource.file(track.path, tag: track);
    final stream = MusifyServer.instance.streamUri(track);
    if (stream != null) return AudioSource.uri(stream, tag: track);
    return _webSource(track);
  }

  /// A YouTube song played by YouTube's player (see [_source]).
  static AudioSource _webSource(YouTubeTrack track) {
    final length =
        (track.length ?? const Duration(minutes: 10)) +
        const Duration(seconds: 2);
    return ClippingAudioSource(
      child: AudioSource.asset('assets/audio/silence.m4a'),
      start: Duration.zero,
      // The silent file is two hours long.
      end: length > const Duration(hours: 2)
          ? const Duration(hours: 2)
          : length,
      tag: track,
    );
  }

  /// Songs queued after the current one, in the order they will play.
  List<QueuedTrack> get upcomingQueue {
    final current = player.currentIndex;
    if (current == null) return const [];
    return [
      for (final source in player.sequence.skip(current + 1))
        if (source.tag is QueuedTrack) source.tag as QueuedTrack,
    ];
  }

  /// The playlist's songs either side of the one at [index]: in playlist
  /// order, or all the others shuffled after it.
  static (List<Track>, List<Track>) _around(
    List<Track> tracks,
    int index,
    bool shuffle,
  ) {
    if (shuffle) {
      return (
        const [],
        [
          for (var i = 0; i < tracks.length; i++)
            if (i != index) tracks[i],
        ]..shuffle(Random()),
      );
    }
    return (tracks.sublist(0, index), tracks.sublist(index + 1));
  }

  /// Starts [playlist] at [startIndex]. Without one, it starts at the top,
  /// or on a random song when shuffling. Songs the user queued stay queued.
  Future<void> play(
    Playlist playlist, {
    required bool shuffle,
    int? startIndex,
  }) => _serial(() async {
    // YouTube songs on the device play from their files.
    final copies = LocalCopies.instance;
    final tracks = playlist.tracks.map(copies.resolve).toList();
    if (tracks.isEmpty) return;
    final index = startIndex ?? (shuffle ? Random().nextInt(tracks.length) : 0);
    final queued = upcomingQueue;
    final (before, after) = _around(tracks, index, shuffle);
    await player.setShuffleModeEnabled(false);
    _lastSource = null;
    await player.setAudioSources([
      ...before.map(_source),
      _source(tracks[index]),
      ...queued.map(_source),
      ...after.map(_source),
    ], initialIndex: before.length);
    _loaded = Playlist(
      id: playlist.id,
      name: playlist.name,
      tracks: tracks,
      location: playlist.location,
      artworkUrl: playlist.artworkUrl,
    );
    shuffleOn.value = shuffle;
    if (!_loopChosen) {
      _loopChosen = true;
      await player.setLoopMode(LoopMode.all);
    }
    AppLog.add('player: ${playlist.name} from #$index shuffle=$shuffle');
    // play() completes only when playback stops, so don't wait on it.
    player.play();
  });

  /// Plays [track] within its folder, so next and previous carry on there.
  /// Returns false if it's in no folder playlist.
  Future<bool> playSong(Track track, {bool? shuffle}) async {
    final home = Library.instance.all
        .where((p) => !p.isCustom && p.tracks.any((t) => t.path == track.path))
        .firstOrNull;
    if (home == null) return false;
    await play(
      home,
      shuffle: shuffle ?? shuffleOn.value,
      startIndex: home.tracks.indexWhere((t) => t.path == track.path),
    );
    return true;
  }

  /// Plays YouTube search results from [index], carrying on through the
  /// rest of them.
  Future<void> playYouTube(List<YouTubeTrack> results, int index) => play(
    Playlist(id: 'youtube:search', name: 'YouTube', tracks: results),
    shuffle: false,
    startIndex: index,
  );

  /// Reorders the rest of the playlist, shuffled or back in playlist order,
  /// without interrupting the current song or the queue after it.
  Future<void> setShuffle(bool enabled) => _serial(() async {
    shuffleOn.value = enabled;
    final playlist = _loaded;
    final current = player.currentIndex;
    if (playlist == null || current == null) return;
    final sequence = player.sequence;

    // The playlist song we're at: the current one, or the last one before
    // the queued songs if one of those is playing.
    var anchorAt = current;
    while (anchorAt > 0 && sequence[anchorAt].tag is QueuedTrack) {
      anchorAt--;
    }
    final anchor = sequence[anchorAt].tag;
    if (anchor is! Track || anchor is QueuedTrack) return;
    final anchorIndex = playlist.tracks.indexWhere(
      (t) => t.path == anchor.path,
    );
    if (anchorIndex < 0) return;
    var queueEnd = current + 1;
    while (queueEnd < sequence.length &&
        sequence[queueEnd].tag is QueuedTrack) {
      queueEnd++;
    }

    final (before, after) = _around(playlist.tracks, anchorIndex, enabled);
    await player.removeAudioSourceRange(queueEnd, sequence.length);
    await player.addAudioSources(after.map(_source).toList());
    if (anchorAt > 0) await player.removeAudioSourceRange(0, anchorAt);
    if (before.isNotEmpty) {
      await player.insertAudioSources(0, before.map(_source).toList());
    }
  });

  /// Plays [track] right after the current song, ahead of anything queued
  /// before.
  Future<void> playNext(Track track) => _enqueue(track, next: true);

  /// Adds [track] after the songs already queued, ahead of the rest of the
  /// playlist.
  Future<void> addToQueue(Track track) => _enqueue(track, next: false);

  Future<void> _enqueue(Track track, {required bool next}) => _serial(() async {
    final source = _source(queuedCopy(LocalCopies.instance.resolve(track)));
    final current = player.currentIndex;
    if (current == null || player.sequence.isEmpty) {
      // Nothing loaded: the song waits, paused, in the mini player.
      await player.setAudioSources([source]);
      return;
    }
    var at = current + 1;
    if (!next) {
      final sequence = player.sequence;
      while (at < sequence.length && sequence[at].tag is QueuedTrack) {
        at++;
      }
    }
    await player.insertAudioSource(at, source);
  });

  Future<void> clearQueue() => _serial(() async {
    final current = player.currentIndex;
    if (current == null) return;
    final sequence = player.sequence;
    for (var i = sequence.length - 1; i > current; i--) {
      if (sequence[i].tag is QueuedTrack) await player.removeAudioSourceAt(i);
    }
  });

  /// Removes queued songs playback has moved past (or skipped), so they
  /// play only once.
  void _dropPlayedQueue() => _serial(() async {
    final current = player.currentIndex;
    if (current == null) return;
    final sequence = player.sequence;
    final playing = sequence[current];
    final left = _lastSource;
    _lastSource = playing;
    final stale = <int>{
      for (var i = 0; i < current; i++)
        if (sequence[i].tag is QueuedTrack) i,
      if (left != null && left != playing && left.tag is QueuedTrack)
        ?_indexOf(sequence, left),
    };
    for (final i in stale.toList()..sort((a, b) => b - a)) {
      await player.removeAudioSourceAt(i);
    }
  });

  static int? _indexOf(
    List<IndexedAudioSource> sequence,
    IndexedAudioSource s,
  ) {
    final i = sequence.indexOf(s);
    return i < 0 ? null : i;
  }

  /// Puts back a saved session, paused at [position].
  Future<void> restore({
    required Playlist? playlist,
    required List<Track> sequence,
    required int index,
    required Duration position,
    required bool shuffle,
    required LoopMode loop,
  }) => _serial(() async {
    await player.setShuffleModeEnabled(false);
    await player.setLoopMode(loop);
    _loopChosen = true;
    _lastSource = null;
    await player.setAudioSources(
      sequence.map(LocalCopies.instance.resolve).map(_source).toList(),
      initialIndex: index,
      initialPosition: position,
    );
    _loaded = playlist;
    shuffleOn.value = shuffle;
    AppLog.add('player: restored ${sequence.length} songs at #$index');
  });

  /// Stops and empties the queue, e.g. before its songs are deleted.
  Future<void> stop() => _serial(() async {
    await player.stop();
    await player.clearAudioSources();
    _loaded = null;
  });

  /// Set by sync while another device has the music: the controls here
  /// (play/pause, next, previous, seek) steer that one, and show its state.
  RemoteControl? remote;

  bool get _remote => remote?.active ?? false;

  /// Playing, as the controls show it: this device's, or the device being
  /// controlled.
  late final shownPlaying = () {
    final shown = ValueNotifier<bool>(player.playing);
    player.playingStream.listen((_) => refreshShown());
    return shown;
  }();

  /// Where the song is, as the seek bars show it (another device's,
  /// worked out between its reports, while controlling it).
  /// One stream for every bar; it ticks only while something listens. Bars
  /// read [shownPositionNow] when they redraw, so a redraw for another
  /// reason (letting go of the thumb) never shows a stale tick.
  late final Stream<Duration> shownPosition =
      Stream.periodic(
        const Duration(milliseconds: 250),
        (_) => shownPositionNow,
      ).asBroadcastStream(
        onListen: (ticks) => ticks.resume(),
        onCancel: (ticks) => ticks.pause(),
      );

  /// [shownPosition] right now. Just after a seek this is where the seek
  /// went, until the player gets there: seeking (YouTube's especially, or
  /// another device's) takes a moment, and the bar would otherwise jump
  /// back to where it was and then forward again.
  Duration get shownPositionNow {
    final reported = _remote
        ? remote!.position ?? player.position
        : player.position;
    final target = _seekTarget;
    if (target == null) return reported;
    final since = DateTime.now().difference(_seekAt);
    final expected = shownPlaying.value ? target + since : target;
    final arrived = (reported - expected).abs() < const Duration(seconds: 2);
    if (arrived ||
        since > const Duration(seconds: 6) ||
        currentTrack?.path != _seekTrack?.path) {
      _seekTarget = null;
      return reported;
    }
    return expected;
  }

  Duration? _seekTarget;
  DateTime _seekAt = DateTime.now();
  Track? _seekTrack;

  /// Works out [shownPlaying] again (sync calls this when the other
  /// device's state changes).
  void refreshShown() =>
      shownPlaying.value = _remote ? remote!.playing : player.playing;

  Future<void> togglePlayback() async {
    if (_remote) return remote!.send(remote!.playing ? 'pause' : 'play');
    return player.playing ? player.pause() : player.play();
  }

  Future<void> seekTo(Duration position) async {
    _seekTarget = position;
    _seekAt = DateTime.now();
    _seekTrack = currentTrack;
    if (_remote) return remote!.send('seek', position);
    return player.seek(position);
  }

  /// The song [offset] places away from the current one in play order, or
  /// null at either end with repeat off. Unlike just_audio's own
  /// next/previous, repeat-one still moves on, as Spotify does when you skip.
  Track? neighbour(int offset) {
    final index = _neighbourIndex(offset);
    if (index == null) return null;
    final tag = player.sequence[index].tag;
    return tag is Track ? tag : null;
  }

  int? _neighbourIndex(int offset) {
    final current = player.currentIndex;
    final length = player.sequence.length;
    if (current == null || length == 0) return null;
    var target = current + offset;
    if (target < 0 || target >= length) {
      if (player.loopMode == LoopMode.off) return null;
      target %= length;
    }
    return target == current ? null : target;
  }

  /// Moves [offset] songs along the play order, starting it from the top.
  Future<void> skip(int offset) async {
    final index = _neighbourIndex(offset);
    if (index != null) await player.seek(Duration.zero, index: index);
  }

  Future<void> next() async {
    if (_remote) return remote!.send('next');
    return skip(1);
  }

  /// Like Spotify: restarts the song unless it has only just begun.
  Future<void> previous() async {
    if (_remote) return remote!.send('previous');
    if (player.position > const Duration(seconds: 3) ||
        _neighbourIndex(-1) == null) {
      await player.seek(Duration.zero);
    } else {
      await skip(-1);
    }
  }

  /// Repeat cycles all → one → off.
  Future<void> cycleRepeat() {
    _loopChosen = true;
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

/// Another device being played from here (see SyncService).
abstract class RemoteControl {
  /// Whether the controls here steer it now.
  bool get active;

  bool get playing;

  /// Where its song has got to, by now.
  Duration? get position;

  /// 'play', 'pause', 'next', 'previous' or 'seek' (to [position]).
  Future<void> send(String action, [Duration? position]);
}
