import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import 'app_log.dart';
import 'folder_access.dart';
import 'library_scanner.dart';
import 'library_store.dart';
import 'player_service.dart';

const _customPrefix = 'custom:';

/// Everything in Your Library: the folders the user added (each folder in
/// them that holds music becomes a playlist) and the playlists they made,
/// which can mix songs from any folder.
///
/// Shared by the Library tab, the player's "Add to playlist" and the system
/// media browser (Android Auto), which can ask before any screen is shown.
class Library extends ChangeNotifier {
  @visibleForTesting
  Library.fresh();

  static final instance = Library.fresh();

  /// For the media browser: waits for the first load.
  static Future<List<Playlist>> playlists() async {
    await instance.ensureLoaded();
    return instance.all;
  }

  List<LibraryFolder> _folders = [];
  List<Playlist> _folderPlaylists = [];
  List<SavedPlaylist> _saved = [];
  List<Playlist> _custom = [];

  /// Folders that couldn't be read on the last scan, by folder id.
  final folderErrors = <String, String>{};

  bool _scanning = false;
  bool _ready = false;
  Future<void>? _loading;

  List<LibraryFolder> get folders => List.unmodifiable(_folders);
  bool get scanning => _scanning;

  /// Whether the first scan has finished.
  bool get loaded => _ready;

  /// The user's playlists first, then folder playlists.
  List<Playlist> get all => [
    ..._custom,
    for (final p in _folderPlaylists)
      if (!_hidden.contains(_hideKeys[p.id])) p,
  ];

  /// Folder playlists the user hid from the library.
  List<Playlist> get hidden => [
    for (final p in _folderPlaylists)
      if (_hidden.contains(_hideKeys[p.id])) p,
  ];

  /// Hidden folder playlists, as `<folder id>|<location>`: stable even if
  /// iOS moves the folder's path.
  Set<String> _hidden = {};

  /// Each folder playlist's key in [_hidden], by playlist id.
  final _hideKeys = <String, String>{};

  List<Playlist> get custom => List.unmodifiable(_custom);

  Playlist? byId(String id) {
    for (final playlist in all) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    _folders = await FolderAccess.restoreAll();
    _saved = await LibraryStore.loadPlaylists();
    _hidden = await LibraryStore.loadHidden();
    await rescan();
  }

  Future<void> rescan() async {
    _scanning = true;
    notifyListeners();
    final playlists = <Playlist>[];
    folderErrors.clear();
    _hideKeys.clear();
    for (final folder in _folders) {
      final result = await LibraryScanner.scan(folder.path);
      AppLog.addAll(result.log);
      if (result.rootError != null) folderErrors[folder.id] = result.rootError!;
      for (final playlist in result.playlists) {
        _hideKeys[playlist.id] = '${folder.id}|${playlist.location}';
      }
      playlists.addAll(result.playlists);
    }
    playlists.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    _folderPlaylists = playlists;
    _resolveCustom();
    _scanning = false;
    _ready = true;
    notifyListeners();
  }

  // Folders -------------------------------------------------------------------

  /// Asks for a folder and adds it. Returns false if the user cancelled.
  Future<bool> addFolder() async {
    final folder = await FolderAccess.pick();
    if (folder == null) return false;
    if (!_folders.any((f) => f.id == folder.id || f.path == folder.path)) {
      _folders = [..._folders, folder];
    }
    await rescan();
    return true;
  }

  Future<void> removeFolder(LibraryFolder folder) async {
    await FolderAccess.remove(folder);
    _folders = [
      for (final f in _folders)
        if (f.id != folder.id) f,
    ];
    await rescan();
  }

  // Hiding and deleting folder playlists --------------------------------------

  void hidePlaylist(Playlist playlist) => _setHidden(playlist, true);

  void unhidePlaylist(Playlist playlist) => _setHidden(playlist, false);

  void _setHidden(Playlist playlist, bool hide) {
    final key = _hideKeys[playlist.id];
    if (key == null) return;
    _hidden = {..._hidden};
    hide ? _hidden.add(key) : _hidden.remove(key);
    LibraryStore.saveHidden(_hidden);
    notifyListeners();
  }

  /// Deletes a folder playlist's songs from the device, then its folder if
  /// nothing else is left in it. Subfolders (their own playlists) and other
  /// files are kept, and so is a folder the user added to the library.
  /// Returns how many songs were deleted.
  Future<int> deleteFromDevice(Playlist playlist) async {
    final player = PlayerService.instance;
    final playing = player.currentTrack;
    if (player.current?.id == playlist.id ||
        (playing != null &&
            playlist.tracks.any((t) => t.path == playing.path))) {
      await player.stop();
    }

    var deleted = 0;
    for (final track in playlist.tracks) {
      try {
        await File(track.path).delete();
        deleted++;
      } on FileSystemException catch (e) {
        AppLog.add('delete: ${track.path} failed: ${e.message}');
      }
    }

    final dir = Directory(playlist.id);
    final isLibraryFolder = _folders.any((f) => p.equals(f.path, playlist.id));
    if (!isLibraryFolder && await dir.exists()) {
      try {
        final left = dir.listSync().where(
          (e) => !p.basename(e.path).startsWith('.'),
        );
        if (left.isEmpty) await dir.delete(recursive: true);
      } on FileSystemException catch (e) {
        AppLog.add('delete: folder ${dir.path} failed: ${e.message}');
      }
    }
    AppLog.add('delete: ${playlist.name}, $deleted songs');
    await rescan();
    return deleted;
  }

  // The user's playlists ------------------------------------------------------

  Playlist createPlaylist(String name) {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}'
        '${Random().nextInt(1 << 20)}';
    _saved = [..._saved, SavedPlaylist(id, name, const [])];
    _commit();
    return byId('$_customPrefix$id')!;
  }

  void renamePlaylist(Playlist playlist, String name) {
    _update(playlist, (s) => SavedPlaylist(s.id, name, s.tracks));
  }

  void deletePlaylist(Playlist playlist) {
    _saved = [
      for (final s in _saved)
        if (_idOf(s) != playlist.id) s,
    ];
    _commit();
  }

  /// Checks the latest version: [playlist] may be a copy from before songs
  /// were added.
  bool contains(Playlist playlist, Track track) =>
      (byId(playlist.id) ?? playlist).tracks.any((t) => t.path == track.path);

  void addTrack(Playlist playlist, Track track) {
    if (contains(playlist, track)) return;
    _update(
      playlist,
      (s) => SavedPlaylist(s.id, s.name, [...s.tracks, _save(track)]),
    );
  }

  void removeTrack(Playlist playlist, Track track) {
    _update(
      playlist,
      (s) => SavedPlaylist(s.id, s.name, [
        for (final t in s.tracks)
          if (_resolve(t) != track.path) t,
      ]),
    );
  }

  void _update(
    Playlist playlist,
    SavedPlaylist Function(SavedPlaylist) change,
  ) {
    _saved = [for (final s in _saved) _idOf(s) == playlist.id ? change(s) : s];
    _commit();
  }

  void _commit() {
    _resolveCustom();
    notifyListeners();
    LibraryStore.savePlaylists(_saved);
  }

  static String _idOf(SavedPlaylist s) => '$_customPrefix${s.id}';

  SavedTrack _save(Track track) {
    for (final folder in _folders) {
      if (p.isWithin(folder.path, track.path)) {
        return SavedTrack(
          track.path,
          folderId: folder.id,
          relative: p.relative(track.path, from: folder.path),
        );
      }
    }
    return SavedTrack(track.path);
  }

  /// Where a saved song is now, or null if it can't be found.
  String? _resolve(SavedTrack saved) {
    if (File(saved.path).existsSync()) return saved.path;
    if (saved.folderId == null || saved.relative == null) return null;
    for (final folder in _folders) {
      if (folder.id == saved.folderId) {
        final moved = p.join(folder.path, saved.relative);
        if (File(moved).existsSync()) return moved;
      }
    }
    return null;
  }

  void _resolveCustom() {
    _custom = [
      for (final s in _saved)
        Playlist(
          id: _idOf(s),
          name: s.name,
          tracks: [
            for (final t in s.tracks)
              if (_resolve(t) case final path?) Track(path),
          ],
        ),
    ];
  }
}
