import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'folder_access.dart';
import 'library.dart';
import 'library_scanner.dart';
import 'library_store.dart';
import 'musify_server.dart';
import 'player_service.dart';

enum SyncStatus { off, waiting, on }

class SyncDevice {
  final String id;
  final String name;
  final String platform;
  final DateTime? seen;
  final bool me;

  const SyncDevice(this.id, this.name, this.platform, this.seen, this.me);
}

class SyncRequest {
  final String id;
  final String name;
  final String platform;

  const SyncRequest(this.id, this.name, this.platform);
}

/// Music files moving between this device and the others.
class FileSyncProgress {
  final int done;
  final int total;
  final String current;

  /// Of the current file, 0 to 1.
  final double fraction;

  const FileSyncProgress(this.done, this.total, this.current, this.fraction);
}

/// Keeps a user's devices in step through their Musify server (see the
/// backend's sync.py):
///
/// - the library: playlists, tags, Liked Songs and Home pins, merged item
///   by item, the latest change winning (deletions included)
/// - what's playing and where, so a song paused on one device can be
///   carried on from another
/// - the music files in one library folder per device ("Music to sync"):
///   each device's new songs are uploaded and the others download them
///   into the same place in their own folder; deleting one deletes it
///   everywhere
///
/// Songs on the device are named across devices by where they are in the
/// synced folder (`{"sync": "EDM/song.mp3"}`), else by their library
/// folder's name; YouTube songs by their video.
///
/// Joining: a device turns sync on (its own group and code) or asks to
/// join another's code; a device already in sync approves it. Then both
/// have the same code.
class SyncService extends ChangeNotifier {
  SyncService._();

  static final instance = SyncService._();

  static const _prefsKey = 'sync_v1';

  final _server = MusifyServer.instance;

  String _deviceId = '';
  String? _token;
  String? _code;
  String? _request;
  String? _requestCode;
  String? _musicFolderId;

  SyncStatus get status => _token != null
      ? SyncStatus.on
      : _request != null
      ? SyncStatus.waiting
      : SyncStatus.off;

  /// This device's group's code (or the one it asked to join).
  String? get code => _token != null ? _code : _requestCode;

  List<SyncDevice> devices = const [];
  List<SyncRequest> requests = const [];
  DateTime? lastSynced;
  String? lastError;
  bool busy = false;
  FileSyncProgress? files;

  /// The library folder whose music is synced, if any.
  LibraryFolder? get musicFolder =>
      Library.instance.folders.where((f) => f.id == _musicFolderId).firstOrNull;

  String get summary => switch (status) {
    SyncStatus.off => 'Off',
    SyncStatus.waiting => 'Waiting for approval…',
    SyncStatus.on =>
      requests.isNotEmpty
          ? '${requests.length} waiting for your approval'
          : '${devices.length} ${devices.length == 1 ? 'device' : 'devices'}'
                '${lastError != null ? ' • last sync failed' : ''}',
  };

  static String get deviceName {
    final host = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
    final kind = Platform.isIOS
        ? 'iPhone'
        : Platform.isMacOS
        ? 'Mac'
        : Platform.isAndroid
        ? 'Android'
        : 'Device';
    return host.isEmpty || host == 'localhost' ? kind : host;
  }

  static String get platform => Platform.operatingSystem;

  // Starting -------------------------------------------------------------------

  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    await Library.instance.ensureLoaded();
    _watchPlayer();
    Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    AppLifecycleListener(
      onResume: () => _tick(pullPlayback: true),
      onPause: _pushPlaybackNow,
      onInactive: _pushPlaybackNow,
    );
    _tick(pullPlayback: true, filesNow: true);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final data = raw == null
        ? const <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    _deviceId = data['device'] as String? ?? _newId();
    _token = data['token'] as String?;
    _code = data['code'] as String?;
    _request = data['request'] as String?;
    _requestCode = data['requestCode'] as String?;
    _musicFolderId = data['music'] as String?;
    if (raw == null) await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'device': _deviceId,
        'token': _token,
        'code': _code,
        'request': _request,
        'requestCode': _requestCode,
        'music': _musicFolderId,
      }),
    );
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, Object?> get _me => {
    'device': _deviceId,
    'name': deviceName,
    'platform': platform,
  };

  // Joining ---------------------------------------------------------------------

  /// Turns sync on with this device's own code.
  Future<void> create() async {
    final (status, data) = await _server.syncCall(
      'POST',
      '/sync/create',
      body: _me,
    );
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    _token = data['token'] as String;
    _code = data['code'] as String;
    _request = _requestCode = null;
    await _clearMerged();
    await _save();
    AppLog.add('sync: on, code $_code');
    notifyListeners();
    _tick(filesNow: true);
  }

  /// Asks to join the devices using [code]; one of them has to approve.
  Future<void> join(String code) async {
    final (status, data) = await _server.syncCall(
      'POST',
      '/sync/join',
      body: {..._me, 'code': code},
    );
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    _request = data['request'] as String;
    _requestCode = data['code'] as String;
    await _save();
    AppLog.add('sync: asked to join $_requestCode');
    notifyListeners();
  }

  Future<void> cancelJoin() async {
    _request = _requestCode = null;
    await _save();
    notifyListeners();
  }

  Future<void> answer(SyncRequest request, {required bool approve}) async {
    final (status, data) = await _call(
      'POST',
      '/sync/requests/${request.id}',
      body: {'approve': approve},
    );
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    await _refreshGroup();
  }

  Future<void> removeDevice(SyncDevice device) async {
    final (status, data) = await _call('DELETE', '/sync/devices/${device.id}');
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    if (device.me) {
      await _turnedOff('left');
    } else {
      await _refreshGroup();
    }
  }

  /// Stops syncing this device (its songs and playlists stay).
  Future<void> leave() async {
    try {
      await _call('DELETE', '/sync/devices/$_deviceId');
    } catch (_) {}
    await _turnedOff('left');
  }

  Future<void> _turnedOff(String why) async {
    _token = _code = null;
    devices = const [];
    requests = const [];
    await _clearMerged();
    await _save();
    AppLog.add('sync: off ($why)');
    notifyListeners();
  }

  Future<(int, Map<String, dynamic>)> _call(
    String method,
    String path, {
    Object? body,
  }) async {
    final result = await _server.syncCall(
      method,
      path,
      body: body,
      token: _token,
    );
    if (result.$1 == 401 && _token != null) {
      await _turnedOff('removed from sync');
      throw const SyncFailed('This device was removed from sync');
    }
    return result;
  }

  // The loop ----------------------------------------------------------------

  DateTime _lastFiles = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void>? _running;

  /// Every 20 seconds while the app runs, and on coming back to it. With
  /// [queue], a sync already running is followed by another (Sync now);
  /// without, it's enough.
  Future<void> _tick({
    bool pullPlayback = false,
    bool filesNow = false,
    bool queue = false,
  }) {
    final running = _running;
    if (running != null) {
      return queue
          ? running.then(
              (_) => _tick(pullPlayback: pullPlayback, filesNow: filesNow),
            )
          : running;
    }
    final run = _sync(pullPlayback: pullPlayback, filesNow: filesNow);
    _running = run;
    return run.whenComplete(() => _running = null);
  }

  Future<void> _sync({
    required bool pullPlayback,
    required bool filesNow,
  }) async {
    try {
      if (!await _server.isSetUp()) return;
      if (status == SyncStatus.waiting) await _checkJoin();
      if (status != SyncStatus.on) return;
      busy = true;
      notifyListeners();
      await _refreshGroup();
      await _syncLibrary();
      if (pullPlayback) await _pullPlayback();
      final due =
          DateTime.now().difference(_lastFiles) > const Duration(minutes: 2);
      if (musicFolder != null && (filesNow || due)) {
        _lastFiles = DateTime.now();
        await _syncFiles();
      }
      lastError = null;
      lastSynced = DateTime.now();
    } catch (e) {
      lastError = '$e';
      AppLog.add('sync: failed: $e');
    } finally {
      busy = false;
      files = null;
      notifyListeners();
    }
  }

  int _watchers = 0;
  Timer? _quickTimer;
  bool _quickRunning = false;

  /// While the Sync screen is open: a quick look every 3 seconds, so a
  /// device asking to join, or being let in, shows up straight away.
  void watch() {
    _watchers++;
    _quickTimer ??= Timer.periodic(const Duration(seconds: 3), (_) => _quick());
    _quick();
  }

  void unwatch() {
    if (--_watchers > 0) return;
    _watchers = 0;
    _quickTimer?.cancel();
    _quickTimer = null;
  }

  Future<void> _quick() async {
    if (_quickRunning || _running != null || !_server.setUpNow) return;
    _quickRunning = true;
    try {
      if (status == SyncStatus.waiting) {
        await _checkJoin();
        // Let in: sync everything now.
        if (status == SyncStatus.on) {
          unawaited(_tick(pullPlayback: true, filesNow: true));
        }
      } else if (status == SyncStatus.on) {
        await _refreshGroup();
      }
    } catch (_) {
      // The full sync reports problems.
    } finally {
      _quickRunning = false;
    }
  }

  /// Syncs everything now, music files included.
  Future<void> syncNow() =>
      _tick(pullPlayback: true, filesNow: true, queue: true);

  Future<void> _checkJoin() async {
    final (status, data) = await _server.syncCall(
      'GET',
      '/sync/join/$_request',
    );
    if (status == 404 || data['status'] == 'denied') {
      AppLog.add('sync: join refused');
      lastError = 'Your request to join was declined';
      _request = _requestCode = null;
      await _save();
      notifyListeners();
      return;
    }
    if (data['status'] == 'approved' && data['token'] is String) {
      _token = data['token'] as String;
      _code = data['code'] as String;
      _request = _requestCode = null;
      await _clearMerged();
      await _save();
      AppLog.add('sync: joined $_code');
      notifyListeners();
    }
  }

  Future<void> _refreshGroup() async {
    final (status, data) = await _call('GET', '/sync/me');
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    _code = data['code'] as String;
    devices = [
      for (final d in data['devices'] as List)
        SyncDevice(
          d['id'] as String,
          d['name'] as String? ?? 'Device',
          d['platform'] as String? ?? '',
          d['seen'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  ((d['seen'] as num) * 1000).round(),
                )
              : null,
          d['me'] == true,
        ),
    ];
    requests = [
      for (final r in data['requests'] as List)
        SyncRequest(
          r['id'] as String,
          r['name'] as String? ?? 'Device',
          r['platform'] as String? ?? '',
        ),
    ];
    notifyListeners();
  }

  // Naming songs across devices -------------------------------------------------

  static String _posix(String path) => path.replaceAll(r'\', '/');

  /// How the other devices find [saved]: by its place in the synced folder,
  /// its library folder's name, or its video.
  Map<String, Object?> _refOf(SavedTrack saved) {
    if (saved.youtube case final youtube?) return {'yt': youtube};
    final library = Library.instance;
    final path = library.resolve(saved);
    if (path == null) {
      return saved.ref ?? {'rel': saved.relative ?? p.basename(saved.path)};
    }
    final music = musicFolder;
    if (music != null && p.isWithin(music.path, path)) {
      return {'sync': _posix(p.relative(path, from: music.path))};
    }
    for (final folder in library.folders) {
      if (p.isWithin(folder.path, path)) {
        return {
          'folder': folder.name,
          'rel': _posix(p.relative(path, from: folder.path)),
        };
      }
    }
    return {'rel': p.basename(path)};
  }

  /// [ref] as saved here: where the song is (or would be) on this device.
  SavedTrack _savedOf(Map<String, Object?> ref) {
    if (ref['yt'] case final Map youtube) {
      final json = youtube.cast<String, Object?>();
      return SavedTrack('youtube:${json['id']}', youtube: json);
    }
    final library = Library.instance;
    if (ref['sync'] case final String rel) {
      final music = musicFolder;
      if (music != null) {
        return SavedTrack(
          p.joinAll([music.path, ...rel.split('/')]),
          folderId: music.id,
          relative: p.joinAll(rel.split('/')),
          ref: ref,
        );
      }
    }
    if (ref case {'folder': final String name, 'rel': final String rel}) {
      for (final folder in library.folders) {
        if (folder.name == name) {
          return SavedTrack(
            p.joinAll([folder.path, ...rel.split('/')]),
            folderId: folder.id,
            relative: p.joinAll(rel.split('/')),
            ref: ref,
          );
        }
      }
    }
    // Anywhere in the library with the same name.
    final rel = (ref['sync'] ?? ref['rel']) as String?;
    if (rel != null) {
      final tail = p.joinAll(rel.split('/'));
      for (final song in library.allSongs) {
        if (song.path.endsWith(tail)) return SavedTrack(song.path, ref: ref);
      }
    }
    return SavedTrack('', ref: ref);
  }

  Object _pinRefOf(String key) {
    if (key.startsWith('ref:')) return jsonDecode(key.substring(4)) as Object;
    final bar = key.indexOf('|');
    if (bar < 0) return {'id': key};
    final folderId = key.substring(0, bar);
    final location = key.substring(bar + 1);
    if (folderId == _musicFolderId) return {'sync': location};
    final folder = Library.instance.folders
        .where((f) => f.id == folderId)
        .firstOrNull;
    return folder == null
        ? {'id': key}
        : {'folder': folder.name, 'loc': location};
  }

  String _pinKeyOf(Object ref) {
    if (ref case {'id': final String id}) return id;
    if (ref case {'sync': final String location}) {
      final music = musicFolder;
      if (music != null) return '${music.id}|$location';
    }
    if (ref case {'folder': final String name, 'loc': final String location}) {
      for (final folder in Library.instance.folders) {
        if (folder.name == name) return '${folder.id}|$location';
      }
    }
    return 'ref:${jsonEncode(ref)}';
  }

  // The library -----------------------------------------------------------------

  static const _mergedKey = 'sync_library_merged';

  /// The library as the other devices see it: an item per playlist and
  /// tag, Liked Songs and the pins.
  Map<String, Object?> _localItems() {
    final library = Library.instance;
    return {
      for (final playlist in library.savedPlaylists)
        'p:${playlist.id}': {
          'name': playlist.name,
          'tracks': [for (final t in playlist.tracks) _refOf(t)],
        },
      for (final tag in library.savedTags)
        't:${tag.id}': {
          'name': tag.name,
          'color': tag.color,
          'tracks': [for (final t in tag.tracks) _refOf(t)],
        },
      'liked': {
        'tracks': [for (final t in library.savedLiked) _refOf(t)],
      },
      'pins': {
        'items': [for (final key in library.pinKeys) _pinRefOf(key)],
      },
    };
  }

  Future<Map<String, dynamic>> _loadMerged() async {
    final raw = (await SharedPreferences.getInstance()).getString(_mergedKey);
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _saveMerged(Map<String, dynamic> items) async {
    await (await SharedPreferences.getInstance()).setString(
      _mergedKey,
      jsonEncode(items),
    );
  }

  /// A new group starts from this device's library as it is.
  Future<void> _clearMerged() async =>
      (await SharedPreferences.getInstance()).remove(_mergedKey);

  Future<void> _syncLibrary() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = _localItems();
    final before = await _loadMerged();

    final mine = stampChanges(local, before, now);

    for (var attempt = 0; attempt < 4; attempt++) {
      final (status, data) = await _call('GET', '/sync/state/library');
      if (status != 200) {
        throw SyncFailed(data['error'] as String? ?? '$status');
      }
      final remote =
          ((data['data'] as Map?)?['items'] as Map?)?.cast<String, dynamic>() ??
          {};
      final merged = mergeItems(mine, remote);
      if (jsonEncode(merged) != jsonEncode(remote)) {
        final (put, latest) = await _call(
          'PUT',
          '/sync/state/library',
          body: {
            'rev': data['rev'],
            'data': {'v': 1, 'items': merged},
          },
        );
        if (put == 409) continue;
        if (put != 200) {
          throw SyncFailed(latest['error'] as String? ?? '$put');
        }
      }
      _applyLibrary(merged, local);
      await _saveMerged(merged);
      return;
    }
    throw const SyncFailed('The library kept changing; trying again soon');
  }

  void _applyLibrary(Map<String, dynamic> merged, Map<String, Object?> local) {
    final live = <String, dynamic>{
      for (final e in merged.entries)
        if ((e.value as Map)['del'] != true) e.key: (e.value as Map)['v'],
    };
    if (jsonEncode(live) == jsonEncode(local)) return;
    List<SavedTrack> tracks(Object? list) => [
      if (list is List)
        for (final ref in list)
          if (ref is Map) _savedOf(ref.cast<String, Object?>()),
    ];
    final playlists = <SavedPlaylist>[];
    final tags = <SavedTag>[];
    for (final e in live.entries) {
      final value = e.value as Map;
      if (e.key.startsWith('p:')) {
        playlists.add(
          SavedPlaylist(
            e.key.substring(2),
            value['name'] as String? ?? 'Playlist',
            tracks(value['tracks']),
          ),
        );
      } else if (e.key.startsWith('t:')) {
        tags.add(
          SavedTag(
            e.key.substring(2),
            value['name'] as String? ?? 'Tag',
            value['color'] as int? ?? 0xFF1ED760,
            tracks(value['tracks']),
          ),
        );
      }
    }
    // Keep the order this device had, new ones after.
    int order(List<String> keys, String key) {
      final i = keys.indexOf(key);
      return i < 0 ? keys.length : i;
    }

    final localKeys = local.keys.toList();
    playlists.sort(
      (a, b) => order(localKeys, 'p:${a.id}') - order(localKeys, 'p:${b.id}'),
    );
    tags.sort(
      (a, b) => order(localKeys, 't:${a.id}') - order(localKeys, 't:${b.id}'),
    );
    AppLog.add(
      'sync: library from other devices: ${playlists.length} playlists, '
      '${tags.length} tags',
    );
    Library.instance.applySync(
      playlists: playlists,
      tags: tags,
      liked: tracks((live['liked'] as Map?)?['tracks']),
      pins: [
        for (final ref in ((live['pins'] as Map?)?['items'] as List?) ?? [])
          _pinKeyOf(ref as Object),
      ],
    );
  }

  // What's playing --------------------------------------------------------------

  int _playbackRev = 0;

  /// When this device last played or changed song: newer than the other
  /// devices' playing, it isn't replaced by theirs.
  int _lastLocalPlayback = 0;
  Timer? _pushSoon;

  void _watchPlayer() {
    final player = PlayerService.instance.player;
    player.playingStream.listen((_) => _playbackChanged());
    player.currentIndexStream.listen((_) => _playbackChanged());
    Timer.periodic(const Duration(seconds: 30), (_) {
      if (player.playing) _pushPlaybackNow();
    });
  }

  void _playbackChanged() {
    if (_applyingPlayback) return;
    _lastLocalPlayback = DateTime.now().millisecondsSinceEpoch;
    _pushSoon?.cancel();
    _pushSoon = Timer(const Duration(seconds: 2), _pushPlaybackNow);
  }

  Map<String, Object?>? _playlistRefOf(Playlist? playlist) {
    if (playlist == null) return null;
    if (Library.isRemote(playlist)) {
      return {
        'remote': playlist.id,
        'name': playlist.name,
        'tracks': [
          for (final t in playlist.tracks.take(300))
            _refOf(Library.instance.saveForm(t)),
        ],
      };
    }
    return {'pin': _pinRefOf(Library.instance.stableKey(playlist))};
  }

  Future<void> _pushPlaybackNow() async {
    if (status != SyncStatus.on) return;
    final service = PlayerService.instance;
    final track = service.currentTrack;
    if (track == null) return;
    try {
      final doc = {
        'track': _refOf(Library.instance.saveForm(track)),
        'pos': service.player.position.inMilliseconds,
        'playing': service.player.playing,
        'playlist': _playlistRefOf(service.current),
        't': _lastLocalPlayback == 0
            ? DateTime.now().millisecondsSinceEpoch
            : _lastLocalPlayback,
        'device': _deviceId,
        'name': deviceName,
      };
      for (var attempt = 0; attempt < 2; attempt++) {
        final (status, data) = await _call(
          'PUT',
          '/sync/state/playback',
          body: {'rev': _playbackRev, 'data': doc},
        );
        if (status == 200) {
          _playbackRev = data['rev'] as int;
          return;
        }
        if (status != 409) return;
        _playbackRev = ((data['latest'] as Map?)?['rev'] as int?) ?? 0;
      }
    } catch (e) {
      AppLog.add('sync: playback not saved: $e');
    }
  }

  bool _applyingPlayback = false;

  /// What another device played last, picked up here (paused, where it
  /// got to) if it's newer than what this device did.
  Future<void> _pullPlayback() async {
    final (status, data) = await _call('GET', '/sync/state/playback');
    if (status != 200) return;
    _playbackRev = data['rev'] as int? ?? 0;
    final doc = (data['data'] as Map?)?.cast<String, dynamic>();
    if (doc == null || doc['device'] == _deviceId) return;
    final when = doc['t'] as int? ?? 0;
    final service = PlayerService.instance;
    if (when <= _lastLocalPlayback || service.player.playing) return;
    final saved = _savedOf((doc['track'] as Map).cast<String, Object?>());
    final library = Library.instance;
    Track? track;
    if (saved.youtube case final youtube?) {
      track = YouTubeTrack.fromJson(youtube);
    } else if (library.resolve(saved) case final path?) {
      track = Track(path);
    }
    if (track == null) {
      AppLog.add('sync: ${doc['name']} played a song not on this device');
      return;
    }
    Playlist? playlist;
    final ref = (doc['playlist'] as Map?)?.cast<String, dynamic>();
    if (ref?['pin'] case final Object pin) {
      final key = _pinKeyOf(pin);
      playlist =
          library.byId(key) ??
          library.all.where((pl) => library.stableKey(pl) == key).firstOrNull;
    } else if (ref?['remote'] case final String id) {
      playlist = Playlist(
        id: id,
        name: ref!['name'] as String? ?? 'YouTube',
        tracks: [
          for (final r in (ref['tracks'] as List?) ?? [])
            if (_savedOf((r as Map).cast<String, Object?>()) case final s)
              if (s.youtube != null)
                YouTubeTrack.fromJson(s.youtube!)
              else if (library.resolve(s) case final path?)
                Track(path),
        ],
      );
    }
    final tracks = playlist?.tracks ?? [track];
    var index = tracks.indexWhere((t) => t.path == track!.path);
    if (index < 0) {
      playlist = null;
      index = 0;
    }
    _applyingPlayback = true;
    try {
      await service.restore(
        playlist: playlist,
        sequence: index < 0 || playlist == null ? [track] : tracks,
        index: playlist == null ? 0 : index,
        position: Duration(milliseconds: doc['pos'] as int? ?? 0),
        shuffle: false,
        loop: service.player.loopMode == LoopMode.off
            ? LoopMode.all
            : service.player.loopMode,
      );
      _lastLocalPlayback = when;
      AppLog.add('sync: carried on from ${doc['name']}');
      handoff.value = doc['name'] as String?;
    } finally {
      _applyingPlayback = false;
    }
  }

  /// Set to the other device's name when its song was picked up here.
  final handoff = ValueNotifier<String?>(null);

  // Music files -----------------------------------------------------------------

  static const _hashesKey = 'sync_file_hashes';
  static const _syncedKey = 'sync_files_synced';

  /// Picks the library folder whose music is synced (null: none).
  Future<void> setMusicFolder(LibraryFolder? folder) async {
    _musicFolderId = folder?.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncedKey);
    await _save();
    notifyListeners();
    if (folder != null) _tick(filesNow: true);
  }

  /// A song was saved or deleted here: sync the files soon.
  void filesChanged() {
    _lastFiles = DateTime.fromMillisecondsSinceEpoch(0);
    Timer(const Duration(seconds: 3), () => _tick(filesNow: true));
  }

  Future<void> _syncFiles() async {
    final folder = musicFolder;
    if (folder == null) return;
    final prefs = await SharedPreferences.getInstance();
    final hashes = (jsonDecode(prefs.getString(_hashesKey) ?? '{}') as Map)
        .cast<String, dynamic>();
    final synced = (jsonDecode(prefs.getString(_syncedKey) ?? '{}') as Map)
        .cast<String, dynamic>();

    // This device's songs, hashed (unchanged ones remembered).
    final local = await _hashInBackground(folder.path, {...hashes});
    hashes
      ..clear()
      ..addAll({
        for (final e in local.entries)
          e.key: [e.value.size, e.value.modified, e.value.sha1],
      });
    await prefs.setString(_hashesKey, jsonEncode(hashes));

    final (status, data) = await _call('GET', '/sync/files');
    if (status != 200) throw SyncFailed(data['error'] as String? ?? '$status');
    final remote = {
      for (final f in data['files'] as List)
        (f as Map)['path'] as String: f.cast<String, dynamic>(),
    };

    final plan = planFiles(
      {for (final e in local.entries) e.key: e.value.sha1},
      remote,
      synced,
    );
    final FilePlan(:upload, :download, :deleteHere, :deleteThere) = plan;

    // A folder that's suddenly empty-ish is likelier unreadable than
    // emptied on purpose: don't delete everything everywhere.
    if (deleteThere.length > 10 && deleteThere.length > synced.length / 2) {
      throw SyncFailed(
        '${deleteThere.length} synced songs are missing from '
        '${folder.name}; not deleting them on your other devices',
      );
    }

    final total = upload.length + download.length;
    var done = 0;
    void progress(String name, double fraction) {
      files = FileSyncProgress(done, total, name, fraction);
      notifyListeners();
    }

    if (upload.isNotEmpty) {
      final (s, missing) = await _call(
        'POST',
        '/sync/blobs/missing',
        body: {
          'sha1s': [for (final rel in upload) local[rel]!.sha1],
        },
      );
      if (s != 200) throw SyncFailed(missing['error'] as String? ?? '$s');
      final needed = {...(missing['missing'] as List).cast<String>()};
      for (final rel in upload) {
        final file = local[rel]!;
        if (needed.remove(file.sha1)) {
          progress(p.basename(rel), 0);
          await _upload(
            File(p.joinAll([folder.path, ...rel.split('/')])),
            file.sha1,
            (f) => progress(p.basename(rel), f),
          );
        }
        done++;
      }
      final (added, result) = await _call(
        'POST',
        '/sync/files',
        body: {
          'add': [
            for (final rel in upload)
              {'path': rel, 'sha1': local[rel]!.sha1, 'size': local[rel]!.size},
          ],
        },
      );
      if (added != 200) {
        throw SyncFailed(result['error'] as String? ?? '$added');
      }
      for (final rel in upload) {
        synced[rel] = local[rel]!.sha1;
      }
      AppLog.add('sync: uploaded ${upload.length} songs');
    }

    for (final rel in download) {
      final sha1 = remote[rel]!['sha1'] as String;
      progress(p.basename(rel), 0);
      final target = File(p.joinAll([folder.path, ...rel.split('/')]));
      await _download(sha1, target, (f) => progress(p.basename(rel), f));
      synced[rel] = sha1;
      done++;
    }
    if (download.isNotEmpty) {
      AppLog.add('sync: downloaded ${download.length} songs');
    }

    for (final rel in deleteHere) {
      try {
        await File(p.joinAll([folder.path, ...rel.split('/')])).delete();
      } catch (_) {}
      synced.remove(rel);
    }
    if (deleteThere.isNotEmpty) {
      await _call('POST', '/sync/files', body: {'delete': deleteThere});
      for (final rel in deleteThere) {
        synced.remove(rel);
      }
    }
    if (deleteHere.isNotEmpty || deleteThere.isNotEmpty) {
      AppLog.add(
        'sync: deleted ${deleteHere.length} here, '
        '${deleteThere.length} elsewhere',
      );
    }
    await prefs.setString(_syncedKey, jsonEncode(synced));
    if (download.isNotEmpty || deleteHere.isNotEmpty) {
      await Library.instance.rescan();
      // Playlists naming the new songs can find them now.
      await _syncLibrary();
    }
  }

  Future<void> _upload(
    File file,
    String sha1,
    void Function(double) onProgress,
  ) async {
    final size = await file.length();
    final request =
        http.StreamedRequest('PUT', await _server.syncUri('/sync/blobs/$sha1'))
          ..headers.addAll(await _server.syncHeaders(_token))
          ..contentLength = size;
    var sent = 0;
    final response = request.send();
    await for (final chunk in file.openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      onProgress(sent / max(size, 1));
    }
    await request.sink.close();
    final result = await response.timeout(const Duration(minutes: 2));
    if (result.statusCode != 200) {
      throw SyncFailed(
        'Upload of ${p.basename(file.path)} failed '
        '(${result.statusCode})',
      );
    }
  }

  Future<void> _download(
    String sha1,
    File target,
    void Function(double) onProgress,
  ) async {
    final client = http.Client();
    final part = File('${target.path}.part');
    try {
      final request = http.Request(
        'GET',
        await _server.syncUri('/sync/blobs/$sha1'),
      )..headers.addAll(await _server.syncHeaders(_token));
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) {
        throw SyncFailed('Download failed (${response.statusCode})');
      }
      await target.parent.create(recursive: true);
      final total = response.contentLength ?? 0;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
      } finally {
        await sink.close();
      }
      await part.rename(target.path);
    } catch (e) {
      if (part.existsSync()) part.deleteSync();
      rethrow;
    } finally {
      client.close();
    }
  }
}

/// Gives what changed in [local] since [before] (the last merged state)
/// the time [now]; what's gone becomes a deletion. Items are {t, v} or
/// {t, del: true}.
@visibleForTesting
Map<String, dynamic> stampChanges(
  Map<String, Object?> local,
  Map<String, dynamic> before,
  int now,
) {
  final mine = <String, dynamic>{};
  local.forEach((key, value) {
    final last = before[key] as Map?;
    final same =
        last != null &&
        last['del'] != true &&
        jsonEncode(last['v']) == jsonEncode(value);
    mine[key] = same ? last : {'t': now, 'v': value};
  });
  before.forEach((key, last) {
    if (local.containsKey(key)) return;
    mine[key] = (last as Map)['del'] == true ? last : {'t': now, 'del': true};
  });
  return mine;
}

/// Each item as last changed, here or on another device (a tie goes to
/// theirs, already shared).
@visibleForTesting
Map<String, dynamic> mergeItems(
  Map<String, dynamic> mine,
  Map<String, dynamic> theirs,
) {
  final merged = <String, dynamic>{...theirs};
  mine.forEach((key, item) {
    final other = theirs[key] as Map?;
    if (other == null || ((item as Map)['t'] as num) > (other['t'] as num)) {
      merged[key] = item;
    }
  });
  return merged;
}

/// What to do with the synced folder's files.
class FilePlan {
  final List<String> upload;
  final List<String> download;
  final List<String> deleteHere;
  final List<String> deleteThere;

  const FilePlan(this.upload, this.download, this.deleteHere, this.deleteThere);
}

/// Compares this device's files ([local]: path to SHA-1) with the group's
/// ([remote]) and how they last agreed ([synced], updated for files that
/// already match). Changed here: upload; changed there: download; gone
/// here since they agreed: delete there; deleted there and unchanged here:
/// delete here.
@visibleForTesting
FilePlan planFiles(
  Map<String, String> local,
  Map<String, Map<String, dynamic>> remote,
  Map<String, dynamic> synced,
) {
  final upload = <String>[];
  final download = <String>[];
  final deleteHere = <String>[];
  final deleteThere = <String>[];
  for (final MapEntry(key: rel, value: sha1) in local.entries) {
    final there = remote[rel];
    final unchanged = synced[rel] == sha1;
    if (there == null) {
      upload.add(rel);
    } else if (there['deleted'] == true) {
      // Deleted elsewhere: this copy goes too, unless it changed here.
      (unchanged ? deleteHere : upload).add(rel);
    } else if (there['sha1'] == sha1) {
      synced[rel] = sha1;
    } else {
      (unchanged ? download : upload).add(rel);
    }
  }
  for (final MapEntry(key: rel, value: there) in remote.entries) {
    if (there['deleted'] == true || local.containsKey(rel)) continue;
    // Here before and gone now: deleted on this device.
    (synced[rel] == there['sha1'] ? deleteThere : download).add(rel);
  }
  return FilePlan(upload, download, deleteHere, deleteThere);
}

class _LocalFile {
  final int size;
  final int modified;
  final String sha1;

  const _LocalFile(this.size, this.modified, this.sha1);
}

/// [_hashFolder] in another isolate. A function of its own so the closure
/// sent there holds only these two (not the sync service and its timers).
Future<Map<String, _LocalFile>> _hashInBackground(
  String root,
  Map<String, dynamic> known,
) => Isolate.run(() => _hashFolder(root, known));

/// Every song in [root], by its path inside it (with /), hashed; files
/// whose size and time match [known] keep their hash.
Map<String, _LocalFile> _hashFolder(String root, Map<String, dynamic> known) {
  final found = <String, _LocalFile>{};
  final dir = Directory(root);
  if (!dir.existsSync()) return found;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: root).replaceAll(r'\', '/');
    if (rel.split('/').any((part) => part.startsWith('.'))) continue;
    if (!audioExtensions.contains(p.extension(rel).toLowerCase())) continue;
    final stat = entity.statSync();
    final size = stat.size;
    final modified = stat.modified.millisecondsSinceEpoch;
    final cached = known[rel];
    if (cached is List &&
        cached.length == 3 &&
        cached[0] == size &&
        cached[1] == modified) {
      found[rel] = _LocalFile(size, modified, cached[2] as String);
      continue;
    }
    final digest = sha1.convert(entity.readAsBytesSync());
    found[rel] = _LocalFile(size, modified, digest.toString());
  }
  return found;
}

class SyncFailed implements Exception {
  final String message;

  const SyncFailed(this.message);

  @override
  String toString() => message;
}
