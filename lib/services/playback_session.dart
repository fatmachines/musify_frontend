import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'musify_server.dart';
import 'player_service.dart';

/// Keeps what was playing across app launches: the playlist, the play order
/// with any queued songs, the current song and how far into it, shuffle and
/// repeat. On launch it comes back paused in the mini player.
class PlaybackSession {
  static const _key = 'playback_session_v1';

  /// A big playlist's play order in full (the player holds a window of it,
  /// which is what [_key] has), saved only when it changes.
  static const _orderKey = 'playback_order_v1';
  static List<Track>? _savedOrder;

  static bool _started = false;
  static Timer? _saveSoon;
  static Timer? _whilePlaying;
  static AppLifecycleListener? _lifecycle;

  /// Restores the last session, then keeps saving changes.
  static final _restored = Completer<void>();

  /// Done once last time's songs are back (or there were none): sync
  /// waits for it, so it doesn't pick up another device's song only to
  /// have it replaced by this.
  static Future<void> get restored => _restored.future;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    final service = PlayerService.instance;
    try {
      // Songs live in library folders, which on iOS must be opened first.
      await Library.instance.ensureLoaded();
      // YouTube songs stream from the server if there is one.
      await MusifyServer.instance.load();
      await _restore(service);
    } catch (e) {
      AppLog.add('session: restore failed: $e');
    } finally {
      if (!_restored.isCompleted) _restored.complete();
    }

    final player = service.player;
    player.sequenceStateStream.listen((_) => _saveLater());
    player.loopModeStream.listen((_) => _saveLater());
    player.playingStream.listen((_) => _saveLater());
    service.shuffleOn.addListener(_saveLater);
    _whilePlaying = Timer.periodic(const Duration(seconds: 5), (_) {
      if (player.playing) _save();
    });
    _lifecycle = AppLifecycleListener(
      onInactive: _save,
      onHide: _save,
      onPause: _save,
      onDetach: _save,
    );
  }

  static void _saveLater() {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(milliseconds: 500), _save);
  }

  static Future<void> _save() async {
    final service = PlayerService.instance;
    final player = service.player;
    final sequence = player.sequence;
    final index = player.currentIndex;
    final prefs = await SharedPreferences.getInstance();
    if (sequence.isEmpty || index == null) {
      await prefs.remove(_key);
      return;
    }
    final order = service.order;
    if (!identical(order, _savedOrder)) {
      _savedOrder = order;
      await prefs.setString(
        _orderKey,
        jsonEncode([for (final t in order) _entry(t)]),
      );
    }
    final playlist = service.current;
    await prefs.setString(
      _key,
      jsonEncode({
        'playlist': playlist?.id,
        'name': playlist?.name,
        'tracks': [
          for (final source in sequence)
            if (source.tag case final Track track) _entry(track),
        ],
        'index': index,
        'position': player.position.inMilliseconds,
        'shuffle': service.shuffleOn.value,
        'loop': player.loopMode.name,
      }),
    );
  }

  static Object _entry(Track track) => track is YouTubeTrack
      ? {...track.toJson(), if (track is QueuedTrack) 'queued': 1}
      : [track.path, if (track is QueuedTrack) 1];

  /// [entry] as saved by [_entry], or null for a file that's gone.
  static Track? _track(Object? entry) {
    if (entry is Map) {
      // A YouTube song.
      final json = entry.cast<String, Object?>();
      return YouTubeTrack.fromJson(json, queued: json['queued'] != null);
    }
    final path = (entry as List)[0] as String;
    if (!File(path).existsSync()) return null;
    return entry.length > 1 ? QueuedTrack(path) : Track(path);
  }

  static Future<void> _restore(PlayerService service) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    final data = jsonDecode(raw) as Map<String, dynamic>;

    // Songs deleted or moved since are dropped.
    final saved = data['tracks'] as List;
    final savedIndex = data['index'] as int;
    final sequence = <Track>[];
    var index = -1;
    var resume = true;
    for (var i = 0; i < saved.length; i++) {
      final track = _track(saved[i]);
      if (track == null) {
        if (i == savedIndex) resume = false;
        continue;
      }
      if (i >= savedIndex && index < 0) index = sequence.length;
      sequence.add(track);
    }
    if (sequence.isEmpty) return;
    if (index < 0) index = 0;

    final id = data['playlist'] as String?;
    final inOrder = [
      for (final t in sequence)
        if (t is! QueuedTrack) t,
    ];
    final playlist =
        (id == null ? null : Library.instance.byId(id)) ??
        (inOrder.isEmpty
            ? null
            : Playlist(
                id: id ?? 'restored',
                name: data['name'] as String? ?? 'Last played',
                tracks: inOrder,
              ));

    List<Track>? order;
    if (prefs.getString(_orderKey) case final String raw) {
      order = [
        for (final entry in jsonDecode(raw) as List)
          if (_track(entry) case final Track t) t,
      ];
    }

    await service.restore(
      playlist: playlist,
      sequence: sequence,
      order: order,
      index: index,
      position: resume
          ? Duration(milliseconds: data['position'] as int? ?? 0)
          : Duration.zero,
      shuffle: data['shuffle'] as bool? ?? false,
      loop: LoopMode.values.byName(data['loop'] as String? ?? 'all'),
    );
  }

  @visibleForTesting
  static void reset() {
    _started = false;
    _saveSoon?.cancel();
    _whilePlaying?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
    _savedOrder = null;
  }
}
