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
import 'playback_session.dart';
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
  /// What's happening: "Checking songs" (reading them, the first time),
  /// "Uploading" or "Downloading".
  final String action;
  final int done;
  final int total;
  final String current;

  /// Of the current file, 0 to 1.
  final double fraction;

  const FileSyncProgress(
    this.action,
    this.done,
    this.total,
    this.current,
    this.fraction,
  );

  /// "Uploading 3/40", for the banner.
  String get label => '$action ${min(done + 1, total)}/$total';
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
class SyncService extends ChangeNotifier implements RemoteControl {
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
  bool _syncing = false;

  /// Syncing anything: the library, or music files.
  bool get busy => _syncing || _filesRunning != null;
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
    // Last time's songs first: what another device played comes after.
    await PlaybackSession.restored;
    _watchPlayer();
    // While another device plays, the controls here steer it.
    PlayerService.instance.remote = this;
    Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    // A device waiting to be let in (and the Sync screen) look every 3 s.
    Timer.periodic(const Duration(seconds: 3), (_) => _quick());
    _watchFolder();
    AppLifecycleListener(
      // Back in the app: everything, music files too, straight away.
      onResume: () => _tick(pullPlayback: true, filesNow: true),
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

  /// Requests answered here: gone from the screen at once, and not
  /// brought back by an answer from the server that left before.
  final _answered = <String>{};

  Future<void> answer(SyncRequest request, {required bool approve}) async {
    final (status, data) = await _call(
      'POST',
      '/sync/requests/${request.id}',
      body: {'approve': approve},
    );
    // 404: already answered (on another device, or a press before).
    if (status != 200 && status != 404) {
      throw SyncFailed(data['error'] as String? ?? '$status');
    }
    _answered.add(request.id);
    requests = [
      for (final r in requests)
        if (r.id != request.id) r,
    ];
    notifyListeners();
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
      _syncing = true;
      notifyListeners();
      await _refreshGroup();
      await _syncLibrarySerially();
      // An idle device follows what another plays (song and position).
      if (pullPlayback || !PlayerService.instance.player.playing) {
        await _pullPlayback();
      }
      lastError = null;
      lastSynced = DateTime.now();
      // Music files go on in the background, so playlists and tags keep
      // syncing (and the screens refreshing) while songs move. Sync now
      // waits for them.
      final due =
          DateTime.now().difference(_lastFiles) > const Duration(minutes: 2);
      if (musicFolder != null && (filesNow || due)) {
        _lastFiles = DateTime.now();
        final run = _runFiles();
        if (filesNow) {
          _syncing = false;
          notifyListeners();
          await run;
        }
      }
    } catch (e) {
      lastError = '$e';
      AppLog.add('sync: failed: $e');
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void>? _filesRunning;

  /// Something changed while files were syncing: go again after.
  bool _filesAgain = false;

  Future<void> _runFiles() {
    if (_filesRunning != null) {
      _filesAgain = true;
      return _filesRunning!;
    }
    return _filesRunning = () async {
      try {
        do {
          _filesAgain = false;
          await _syncFiles();
        } while (_filesAgain);
        lastSynced = DateTime.now();
      } catch (e) {
        lastError = '$e';
        AppLog.add('sync: files failed: $e');
      } finally {
        _filesRunning = null;
        _filesEnded = DateTime.now();
        files = null;
        notifyListeners();
      }
    }();
  }

  Future<void> _libraryChain = Future.value();

  /// One library sync at a time (the loop and the files' both start one).
  Future<void> _syncLibrarySerially() {
    final run = _libraryChain.then((_) => _syncLibrary());
    _libraryChain = run.catchError((_) {});
    return run;
  }

  int _watchers = 0;
  bool _quickRunning = false;

  /// While the Sync screen is open: a quick look at the devices every 3
  /// seconds, so one asking to join shows up straight away. (A device
  /// waiting to be let in looks that often anyway.)
  void watch() {
    _watchers++;
    _quick();
  }

  void unwatch() {
    if (--_watchers < 0) _watchers = 0;
  }

  Future<void> _quick() async {
    if (_quickRunning || !_server.setUpNow) return;
    final waiting = status == SyncStatus.waiting;
    if (!waiting && !(_watchers > 0 && status == SyncStatus.on)) return;
    _quickRunning = true;
    try {
      if (waiting) {
        await _checkJoin();
        // Let in: sync everything now.
        if (status == SyncStatus.on) {
          unawaited(_tick(pullPlayback: true, filesNow: true, queue: true));
        }
      } else {
        await _refreshGroup();
      }
    } catch (_) {
      // The full sync reports problems.
    } finally {
      _quickRunning = false;
    }
  }

  /// Sets what the Sync screen shows, without a server, for tests.
  @visibleForTesting
  void debugShow({
    String? token,
    String? code,
    List<SyncDevice> devices = const [],
    List<SyncRequest> requests = const [],
    String? musicFolderId,
    FileSyncProgress? files,
  }) {
    _token = token;
    _code = code;
    this.devices = devices;
    this.requests = requests;
    _musicFolderId = musicFolderId;
    this.files = files;
    notifyListeners();
  }

  /// Pull to refresh: whether this device was let in yet, or a full sync.
  Future<void> refresh() async {
    if (status == SyncStatus.waiting) {
      await _checkJoin();
      if (status != SyncStatus.on) return;
    }
    if (status == SyncStatus.on) await syncNow();
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

  int _groupAsked = 0;

  Future<void> _refreshGroup() async {
    // Only the latest answer counts: an older one, still on its way, would
    // bring back what's changed since (like a request just approved).
    final asked = ++_groupAsked;
    final (status, data) = await _call('GET', '/sync/me');
    if (asked != _groupAsked) return;
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
    // Music files waiting for this device (to download, or to upload for
    // another): sync them now rather than at the next file round.
    final waiting = data['files'] as Map?;
    if (musicFolder != null &&
        _filesRunning == null &&
        ((waiting?['incoming'] as int? ?? 0) > 0 ||
            (waiting?['wanted'] as int? ?? 0) > 0)) {
      _lastFiles = DateTime.now();
      unawaited(_runFiles());
    }
    requests = [
      for (final r in data['requests'] as List)
        if (!_answered.contains(r['id']))
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
    // An artist or album: its name and picture come along for the tile.
    if (Library.instance.page(key) case final page?) {
      return {'id': key, 'name': page.name, 'art': ?page.artworkUrl};
    }
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
    if (ref case {'id': final String id, 'name': final String name}) {
      Library.instance.rememberPage(
        Playlist(
          id: id,
          name: name,
          tracks: const [],
          artworkUrl: ref['art'] as String?,
        ),
      );
      return id;
    }
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

  /// Only playing counts as this device's activity: pressing play or
  /// pause, or the song changing while playing. Songs loaded paused (last
  /// time's at launch, another device's) don't, or the device would take
  /// over what's playing just by opening.
  void _watchPlayer() {
    final player = PlayerService.instance.player;
    var wasPlaying = player.playing;
    player.playingStream.listen((playing) {
      if (playing == wasPlaying) return;
      wasPlaying = playing;
      // Pressing play here while another device plays takes over from it,
      // where it has got to.
      if (playing && !_applyingPlayback) {
        final there = _elsewherePosition();
        if (there != null &&
            (player.position - there).abs() > const Duration(seconds: 2)) {
          player.seek(there);
        }
      }
      _playbackChanged();
    });
    player.currentIndexStream.listen((_) {
      if (player.playing) _playbackChanged();
    });
    Timer.periodic(const Duration(seconds: 15), (_) {
      if (player.playing) _pushPlaybackNow();
    });
    // Who's playing, every few seconds: a device taken over from pauses,
    // an idle one follows (and shows "Playing on …"), the playing one
    // obeys the others' controls.
    Timer.periodic(const Duration(seconds: 3), (_) => _checkPlayback());
  }

  /// The other device playing right now (its name), shown as "Playing on
  /// …" with a way to play here instead; null if none.
  final playingElsewhere = ValueNotifier<String?>(null);

  Map<String, dynamic>? _remoteDoc;

  /// Where the song playing on another device has got to by now.
  Duration? _elsewherePosition() {
    final doc = _remoteDoc;
    if (doc == null || playingElsewhere.value == null) return null;
    final at = doc['at'] as int? ?? doc['t'] as int? ?? 0;
    final elapsed = playing
        ? max<int>(0, DateTime.now().millisecondsSinceEpoch - at)
        : 0;
    return Duration(milliseconds: (doc['pos'] as int? ?? 0) + elapsed);
  }

  /// "Play here": what another device is playing carries on on this one,
  /// and that one pauses.
  Future<void> playHere() async {
    final player = PlayerService.instance.player;
    final there = _elsewherePosition();
    if (there != null) await player.seek(there);
    unawaited(player.play());
  }

  bool _checking = false;

  Future<void> _checkPlayback() async {
    if (_checking || status != SyncStatus.on || !_server.setUpNow) return;
    _checking = true;
    try {
      final (code, data) = await _call('GET', '/sync/state/playback');
      if (code != 200) return;
      _playbackRev = data['rev'] as int? ?? _playbackRev;
      final doc = (data['data'] as Map?)?.cast<String, dynamic>();
      _noteElsewhere(doc);
      await _obeyCommand();
      if (doc == null || doc['device'] == _deviceId) return;
      final player = PlayerService.instance.player;
      final when = doc['t'] as int? ?? 0;
      if (player.playing) {
        // Another device started playing after this one did: it has the
        // music now. Paused here without that counting as this device's
        // doing (or it would take it back).
        if (doc['playing'] == true && when > _lastLocalPlayback) {
          _appliedAt = DateTime.now();
          await player.pause();
          AppLog.add('sync: ${doc['name']} took over playing');
          handoff.value = 'Now playing on ${doc['name']}';
        }
      } else {
        await _followPlayback(doc);
      }
    } catch (_) {
      // The next check tries again.
    } finally {
      _checking = false;
    }
  }

  void _noteElsewhere(Map<String, dynamic>? doc) {
    _remoteDoc = doc;
    final gone =
        DateTime.now().millisecondsSinceEpoch - (doc?['at'] as int? ?? 0);
    // Playing there and still reporting, or paused there a little while
    // ago: that device has the music (and the controls here steer it).
    final current =
        doc != null &&
        doc['device'] != _deviceId &&
        (doc['playing'] == true
            ? gone < const Duration(seconds: 45).inMilliseconds
            : gone < const Duration(minutes: 10).inMilliseconds);
    playingElsewhere.value = current
        ? doc['name'] as String? ?? 'another device'
        : null;
    PlayerService.instance.refreshShown();
  }

  // Remote control -------------------------------------------------------------

  /// Pressed here, not yet reported back by the other device: shown
  /// straight away.
  ({bool playing, DateTime until})? _pressed;

  @override
  bool get active =>
      playingElsewhere.value != null && !PlayerService.instance.player.playing;

  @override
  bool get playing {
    final pressed = _pressed;
    if (pressed != null && DateTime.now().isBefore(pressed.until)) {
      return pressed.playing;
    }
    return _remoteDoc?['playing'] == true;
  }

  @override
  Duration? get position => _elsewherePosition();

  int _commandRev = 0;
  String? _lastCommand;

  @override
  Future<void> send(String action, [Duration? position]) async {
    final to = _remoteDoc?['device'] as String?;
    if (to == null) return;
    if (action == 'play' || action == 'pause') {
      _pressed = (
        playing: action == 'play',
        until: DateTime.now().add(const Duration(seconds: 8)),
      );
      PlayerService.instance.refreshShown();
    }
    if (action == 'seek' && position != null) {
      // Shown there at once; the other device reports it soon.
      _remoteDoc = {
        ...?_remoteDoc,
        'pos': position.inMilliseconds,
        'at': DateTime.now().millisecondsSinceEpoch,
      };
    }
    final command = {
      'id': _newId(),
      'to': to,
      'action': action,
      'pos': position?.inMilliseconds,
      'from': deviceName,
      't': DateTime.now().millisecondsSinceEpoch,
    };
    for (var attempt = 0; attempt < 3; attempt++) {
      final (code, data) = await _call(
        'PUT',
        '/sync/state/command',
        body: {'rev': _commandRev, 'data': command},
      );
      if (code == 200) {
        _commandRev = data['rev'] as int;
        AppLog.add('sync: asked ${_remoteDoc?['name']} to $action');
        return;
      }
      if (code != 409) {
        throw SyncFailed(data['error'] as String? ?? '$code');
      }
      _commandRev = ((data['latest'] as Map?)?['rev'] as int?) ?? 0;
    }
  }

  /// Does what another device asked this one (the one playing) to do.
  Future<void> _obeyCommand() async {
    final (code, data) = await _call('GET', '/sync/state/command');
    if (code != 200) return;
    _commandRev = data['rev'] as int? ?? _commandRev;
    final command = (data['data'] as Map?)?.cast<String, dynamic>();
    if (command == null ||
        command['to'] != _deviceId ||
        command['id'] == _lastCommand) {
      return;
    }
    _lastCommand = command['id'] as String?;
    final sent = command['t'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - sent >
        const Duration(seconds: 30).inMilliseconds) {
      return;
    }
    final service = PlayerService.instance;
    final player = service.player;
    AppLog.add('sync: ${command['from']} asked to ${command['action']}');
    switch (command['action']) {
      case 'play':
        unawaited(player.play());
      case 'pause':
        await player.pause();
      case 'next':
        await service.skip(1);
      case 'previous':
        await service.previous();
      case 'seek':
        await player.seek(Duration(milliseconds: command['pos'] as int? ?? 0));
    }
    // Told back straight away, so the other device's controls catch up.
    _lastLocalPlayback = DateTime.now().millisecondsSinceEpoch;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _pushPlaybackNow();
  }

  /// When another device's song was last picked up here: the player's own
  /// events from that aren't this device playing.
  DateTime _appliedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The other device's latest report already followed here.
  int _lastPulledAt = 0;

  void _playbackChanged() {
    if (_applyingPlayback ||
        DateTime.now().difference(_appliedAt) < const Duration(seconds: 2)) {
      return;
    }
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
        // When this was sent: where it got to by now can be worked out.
        'at': DateTime.now().millisecondsSinceEpoch,
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
        final latest = (data['latest'] as Map?)?.cast<String, dynamic>();
        _playbackRev = (latest?['rev'] as int?) ?? 0;
        // Someone else's newer one: theirs stands (the check pauses here).
        final theirs = (latest?['data'] as Map?)?.cast<String, dynamic>();
        if (theirs != null &&
            theirs['device'] != _deviceId &&
            (theirs['t'] as int? ?? 0) > (doc['t'] as int)) {
          return;
        }
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
    _noteElsewhere(doc);
    await _followPlayback(doc);
  }

  Future<void> _followPlayback(Map<String, dynamic>? doc) async {
    if (doc == null || doc['device'] == _deviceId) return;
    final when = doc['t'] as int? ?? 0;
    final at = doc['at'] as int? ?? when;
    final service = PlayerService.instance;
    // Played (or changed) here since: this device's own, kept.
    if (when < _lastLocalPlayback || service.player.playing) return;
    if (at <= _lastPulledAt) return;
    _lastPulledAt = at;
    // Where it is now, if it's still playing there.
    var position = doc['pos'] as int? ?? 0;
    if (doc['playing'] == true) {
      position += max(0, DateTime.now().millisecondsSinceEpoch - at);
    }
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
    // The same song here already: just move to where it got to.
    if (service.currentTrack?.path == track.path) {
      final target = Duration(milliseconds: position);
      if ((service.player.position - target).abs() >
          const Duration(seconds: 3)) {
        _appliedAt = DateTime.now();
        await service.player.seek(target);
      }
      _lastLocalPlayback = when;
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
        position: Duration(milliseconds: position),
        shuffle: false,
        loop: service.player.loopMode == LoopMode.off
            ? LoopMode.all
            : service.player.loopMode,
      );
      _lastLocalPlayback = when;
      _appliedAt = DateTime.now();
      AppLog.add('sync: carried on from ${doc['name']}');
      handoff.value = 'Picked up where you left off on ${doc['name']}';
    } finally {
      _applyingPlayback = false;
    }
  }

  /// A message for the user when playing moves between devices ("Picked
  /// up where you left off on …", "Now playing on …").
  final handoff = ValueNotifier<String?>(null);

  // Music files -----------------------------------------------------------------

  static const _hashesKey = 'sync_file_hashes';
  static const _syncedKey = 'sync_files_synced';

  final _folderWatches = <StreamSubscription<FileSystemEvent>>[];
  Timer? _folderSettle;
  DateTime _filesEnded = DateTime.fromMillisecondsSinceEpoch(0);

  /// Songs added or deleted in the synced folder outside Musify (Finder):
  /// synced a few seconds after things settle. Where the system can watch
  /// folders (the Mac, Android); elsewhere, on coming back to the app.
  void _watchFolder() {
    for (final watch in _folderWatches) {
      watch.cancel();
    }
    _folderWatches.clear();
    final folder = musicFolder;
    if (folder == null || !FileSystemEntity.isWatchSupported) return;
    // Linux (and so Android) can't watch a whole tree: each folder then.
    final deep = !(Platform.isLinux || Platform.isAndroid);
    void onEvent(FileSystemEvent event) {
      // A new subfolder needs watching too (where watching isn't deep),
      // Musify's own downloads' included.
      if (event is FileSystemCreateEvent && event.isDirectory && !deep) {
        _watchFolder();
      }
      // Musify's own downloads aren't news.
      if (_filesRunning != null ||
          DateTime.now().difference(_filesEnded) < const Duration(seconds: 5)) {
        return;
      }
      final name = p.basename(event.path);
      if (name.startsWith('.') || name.endsWith('.part')) return;
      _folderSettle?.cancel();
      _folderSettle = Timer(const Duration(seconds: 5), filesChanged);
    }

    void watch(Directory dir, {required bool recursive}) {
      try {
        _folderWatches.add(
          dir
              .watch(recursive: recursive)
              .listen(
                onEvent,
                onError: (Object e) =>
                    AppLog.add('sync: folder watch stopped: $e'),
              ),
        );
      } catch (e) {
        AppLog.add('sync: can\'t watch ${dir.path}: $e');
      }
    }

    final root = Directory(folder.path);
    if (!deep) {
      watch(root, recursive: false);
      try {
        for (final entity in root.listSync(recursive: true)) {
          if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
            watch(entity, recursive: false);
          }
        }
      } catch (_) {}
    } else {
      watch(root, recursive: true);
    }
  }

  /// Picks the library folder whose music is synced (null: none).
  Future<void> setMusicFolder(LibraryFolder? folder) async {
    _musicFolderId = folder?.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_syncedKey);
    await _save();
    notifyListeners();
    _watchFolder();
    if (folder != null) _tick(filesNow: true);
  }

  /// A song was saved or deleted here: sync the files soon.
  void filesChanged() {
    Timer(const Duration(seconds: 3), () {
      if (status != SyncStatus.on || musicFolder == null) return;
      if (!_server.setUpNow) return;
      _lastFiles = DateTime.now();
      unawaited(_runFiles());
    });
  }

  Future<void> _syncFiles() async {
    final folder = musicFolder;
    if (folder == null) return;
    final prefs = await SharedPreferences.getInstance();
    final hashes = (jsonDecode(prefs.getString(_hashesKey) ?? '{}') as Map)
        .cast<String, dynamic>();
    final synced = (jsonDecode(prefs.getString(_syncedKey) ?? '{}') as Map)
        .cast<String, dynamic>();

    // This device's songs, fingerprinted (unchanged ones remembered).
    final local = await _hashFolderWithProgress(folder.path, hashes);
    hashes
      ..clear()
      ..addAll({
        for (final e in local.entries)
          e.key: [e.value.size, e.value.modified, e.value.sha1],
      });
    await prefs.setString(_hashesKey, jsonEncode(hashes));

    // What this device has: songs every device has never need uploading.
    Future<void> reportHoldings() async {
      final (said, result) = await _call(
        'POST',
        '/sync/have',
        body: {
          'sha1s': [for (final f in local.values) f.sha1],
        },
      );
      if (said != 200) throw SyncFailed(result['error'] as String? ?? '$said');
    }

    Future<(Map<String, Map<String, dynamic>>, Set<String>)> listing() async {
      final (status, data) = await _call('GET', '/sync/files');
      if (status != 200) {
        throw SyncFailed(data['error'] as String? ?? '$status');
      }
      return (
        {
          for (final f in data['files'] as List)
            (f as Map)['path'] as String: f.cast<String, dynamic>(),
        },
        {...((data['wanted'] as List?) ?? const []).cast<String>()},
      );
    }

    await reportHoldings();
    var (remote, wanted) = await listing();

    final plan = planFiles(
      {for (final e in local.entries) e.key: e.value.sha1},
      remote,
      synced,
    );
    final FilePlan(:upload, :download, :deleteHere, :deleteThere) = plan;

    // A folder that's suddenly empty-ish is likelier unreadable than
    // emptied on purpose: don't delete everything everywhere. Songs only
    // moved (a folder renamed) are still here, under another name.
    final held = {for (final f in local.values) f.sha1};
    final missing = deleteThere.where((rel) => !held.contains(synced[rel]));
    if (missing.length > 10 && missing.length > synced.length / 2) {
      throw SyncFailed(
        '${missing.length} synced songs are missing from '
        '${folder.name}; not deleting them on your other devices',
      );
    }

    // New or changed here: listed for the others (not uploaded: only songs
    // another device lacks are, below).
    for (var i = 0; i < upload.length; i += 200) {
      final batch = upload.sublist(i, min(i + 200, upload.length));
      final (added, result) = await _call(
        'POST',
        '/sync/files',
        body: {
          'add': [
            for (final rel in batch)
              {'path': rel, 'sha1': local[rel]!.sha1, 'size': local[rel]!.size},
          ],
        },
      );
      if (added != 200) {
        throw SyncFailed(result['error'] as String? ?? '$added');
      }
      for (final rel in batch) {
        synced[rel] = local[rel]!.sha1;
      }
    }
    if (upload.isNotEmpty) {
      await prefs.setString(_syncedKey, jsonEncode(synced));
      (remote, wanted) = await listing();
    }

    // Upload what another device lacks; download what's on the server.
    final byHash = {for (final e in local.entries) e.value.sha1: e.key};
    final sending = [for (final sha1 in wanted) ?byHash[sha1]];

    // A song wanted somewhere this device already has it (moved to another
    // folder, or its folder renamed, on another device): moved here too,
    // or copied, not fetched.
    final placed = <String>[];
    final emptied = <String>[];
    for (final rel in download) {
      final sha1 = remote[rel]!['sha1'] as String;
      final source = byHash[sha1];
      if (source == null || source == rel) continue;
      final from = File(p.joinAll([folder.path, ...source.split('/')]));
      final to = File(p.joinAll([folder.path, ...rel.split('/')]));
      if (!from.existsSync()) continue;
      try {
        await to.parent.create(recursive: true);
        if (deleteHere.remove(source)) {
          await from.rename(to.path);
          emptied.add(source);
          synced.remove(source);
          final file = local.remove(source)!;
          local[rel] = file;
          byHash[sha1] = rel;
        } else {
          await from.copy(to.path);
          local[rel] = local[source]!;
        }
        synced[rel] = sha1;
        placed.add(rel);
      } on FileSystemException catch (e) {
        AppLog.add('sync: couldn\'t place $rel from $source: ${e.message}');
      }
    }
    if (placed.isNotEmpty) {
      AppLog.add('sync: placed ${placed.length} songs from ones already here');
      await prefs.setString(_syncedKey, jsonEncode(synced));
    }
    final fetching = [
      for (final rel in download)
        if (!placed.contains(rel) && remote[rel]?['available'] == true) rel,
    ];
    AppLog.add(
      'sync: files: ${local.length} here, ${remote.length} listed; '
      'listing ${upload.length} new here, uploading ${sending.length} '
      'another device lacks, downloading ${fetching.length} '
      '(${download.length - fetching.length} not uploaded yet), deleting '
      '${deleteHere.length} here and ${deleteThere.length} elsewhere',
    );

    var done = 0;
    var total = sending.length;
    var action = 'Uploading';
    void progress(String name, double fraction) {
      files = FileSyncProgress(action, done, total, name, fraction);
      notifyListeners();
    }

    for (final rel in sending) {
      progress(p.basename(rel), 0);
      await _upload(
        File(p.joinAll([folder.path, ...rel.split('/')])),
        local[rel]!.sha1,
        (f) => progress(p.basename(rel), f),
      );
      done++;
    }
    if (sending.isNotEmpty) {
      AppLog.add('sync: uploaded ${sending.length} songs');
    }

    done = 0;
    total = fetching.length;
    action = 'Downloading';
    for (final rel in fetching) {
      final sha1 = remote[rel]!['sha1'] as String;
      progress(p.basename(rel), 0);
      final target = File(p.joinAll([folder.path, ...rel.split('/')]));
      await _download(sha1, target, (f) => progress(p.basename(rel), f));
      synced[rel] = sha1;
      done++;
      if (done % 10 == 0) await prefs.setString(_syncedKey, jsonEncode(synced));
    }
    if (fetching.isNotEmpty) {
      AppLog.add('sync: downloaded ${fetching.length} songs');
      // Now held here too: no one uploads them for this device again.
      for (final rel in fetching) {
        final sha1 = remote[rel]!['sha1'] as String;
        local[rel] = _LocalFile(remote[rel]!['size'] as int? ?? 0, 0, sha1);
      }
      await reportHoldings();
    }

    for (final rel in deleteHere) {
      try {
        await File(p.joinAll([folder.path, ...rel.split('/')])).delete();
      } catch (_) {}
      emptied.add(rel);
      synced.remove(rel);
    }
    // Folders left empty by that go too: a renamed one isn't left behind
    // under its old name.
    _removeEmptyFolders(folder.path, emptied);
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
    if (fetching.isNotEmpty || placed.isNotEmpty || deleteHere.isNotEmpty) {
      await Library.instance.rescan();
      // Playlists naming the new songs can find them now.
      await _syncLibrarySerially();
    }
  }

  /// Every song in [root], by its path inside it, fingerprinted (SHA-1).
  /// Songs unchanged since [known] (size and time) keep theirs; the rest
  /// are read a few at a time, shown as "Checking songs".
  Future<Map<String, _LocalFile>> _hashFolderWithProgress(
    String root,
    Map<String, dynamic> known,
  ) async {
    final found = <String, _LocalFile>{};
    final toRead = <(String, int, int)>[];
    for (final (rel, size, modified) in await _listInBackground(root)) {
      final cached = known[rel];
      if (cached is List &&
          cached.length == 3 &&
          cached[0] == size &&
          cached[1] == modified) {
        found[rel] = _LocalFile(size, modified, cached[2] as String);
      } else {
        toRead.add((rel, size, modified));
      }
    }
    if (toRead.isNotEmpty) {
      AppLog.add('sync: checking ${toRead.length} songs');
    }
    for (var i = 0; i < toRead.length; i += 8) {
      final batch = toRead.sublist(i, min(i + 8, toRead.length));
      files = FileSyncProgress(
        'Checking songs',
        i,
        toRead.length,
        p.basename(batch.first.$1),
        0,
      );
      notifyListeners();
      final sums = await _sha1InBackground([
        for (final (rel, _, _) in batch) p.joinAll([root, ...rel.split('/')]),
      ]);
      for (var k = 0; k < batch.length; k++) {
        final (rel, size, modified) = batch[k];
        found[rel] = _LocalFile(size, modified, sums[k]);
      }
    }
    return found;
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

/// Deletes the folders inside [root] holding [rels] (paths in it) once
/// they're empty, but for hidden files like .DS_Store, and their parents
/// after them; never [root] itself.
void _removeEmptyFolders(String root, List<String> rels) {
  final folders = <String>{
    for (final rel in rels)
      if (rel.contains('/')) rel.substring(0, rel.lastIndexOf('/')),
  };
  // Deepest first, so a parent is empty by the time it's looked at.
  final queue = folders.toList()
    ..sort((a, b) => b.split('/').length - a.split('/').length);
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final rel = queue.removeAt(0);
    if (!seen.add(rel)) continue;
    final dir = Directory(p.joinAll([root, ...rel.split('/')]));
    try {
      if (!dir.existsSync()) continue;
      final left = dir.listSync().where(
        (e) => !p.basename(e.path).startsWith('.'),
      );
      if (left.isNotEmpty) continue;
      dir.deleteSync(recursive: true);
      AppLog.add('sync: removed empty folder $rel');
      if (rel.contains('/')) queue.add(rel.substring(0, rel.lastIndexOf('/')));
    } on FileSystemException catch (e) {
      AppLog.add('sync: couldn\'t remove folder $rel: ${e.message}');
    }
  }
}

class _LocalFile {
  final int size;
  final int modified;
  final String sha1;

  const _LocalFile(this.size, this.modified, this.sha1);
}

/// The songs in [root] (path inside it, size, time), in another isolate.
/// A function of its own so the closure sent there holds only [root] (not
/// the sync service and its timers).
Future<List<(String, int, int)>> _listInBackground(String root) =>
    Isolate.run(() => _listFolder(root));

Future<List<String>> _sha1InBackground(List<String> paths) => Isolate.run(
  () => [
    for (final path in paths)
      sha1.convert(File(path).readAsBytesSync()).toString(),
  ],
);

List<(String, int, int)> _listFolder(String root) {
  final found = <(String, int, int)>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return found;
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final rel = p.relative(entity.path, from: root).replaceAll(r'\', '/');
    if (rel.split('/').any((part) => part.startsWith('.'))) continue;
    if (!audioExtensions.contains(p.extension(rel).toLowerCase())) continue;
    final stat = entity.statSync();
    found.add((rel, stat.size, stat.modified.millisecondsSinceEpoch));
  }
  return found;
}

class SyncFailed implements Exception {
  final String message;

  const SyncFailed(this.message);

  @override
  String toString() => message;
}
