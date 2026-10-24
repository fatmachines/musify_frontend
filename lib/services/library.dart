import 'dart:io';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import '../models/song_tag.dart';
import 'app_log.dart';
import 'cover_files.dart';
import 'downloads.dart';
import 'folder_access.dart';
import 'library_scanner.dart';
import 'library_store.dart';
import 'metadata_service.dart';
import 'player_service.dart';
import 'sync_service.dart';

const _customPrefix = 'custom:';
const _tagPrefix = 'tag:';

/// Offered on first launch for the main use of tags: marking songs whose
/// file should be swapped for a better version.
const _defaultTag = SavedTag('to-replace', 'To replace', 0xFFFF9F43, []);

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

  /// The permanent "Liked Songs" playlist's id.
  static const likedId = 'liked';

  /// For the media browser: waits for the first load.
  static Future<List<Playlist>> playlists() async {
    await instance.ensureLoaded();
    return instance.all;
  }

  List<LibraryFolder> _folders = [];
  List<Playlist> _folderPlaylists = [];
  List<SavedPlaylist> _saved = [];
  List<Playlist> _custom = [];

  List<SavedTrack> _likedSaved = [];
  Playlist _liked = const Playlist(
    id: likedId,
    name: 'Liked Songs',
    tracks: [],
  );

  List<SavedTag> _tagsSaved = [];
  List<SongTag> _tags = [];

  /// Resolved song paths per tag id.
  // Home --------------------------------------------------------------------

  /// See [LibraryStore.loadPinned].
  List<String> _pins = [];

  /// Folder playlists by folder and location, which survive iOS moving the
  /// folder's path; anything else by id.
  String _pinKey(Playlist playlist) => _hideKeys[playlist.id] ?? playlist.id;

  /// The playlists pinned to Home, in the order pinned. Ones gone or
  /// hidden since are left out.
  List<Playlist> get pinned {
    final byKey = {
      for (final p in [...all, for (final t in _tags) tagPlaylist(t)])
        _pinKey(p): p,
      ..._pages,
    };
    return [for (final key in _pins) ?byKey[key]];
  }

  bool isPinned(Playlist playlist) => _pins.contains(_pinKey(playlist));

  void togglePin(Playlist playlist) {
    final key = _pinKey(playlist);
    final pinning = !_pins.contains(key);
    _pins = pinning
        ? [..._pins, key]
        : [
            for (final k in _pins)
              if (k != key) k,
          ];
    if (isPage(playlist)) {
      pinning ? rememberPage(playlist) : _pages.remove(playlist.id);
      LibraryStore.savePages(_pages.values.toList());
    }
    notifyListeners();
    LibraryStore.savePinned(_pins);
  }

  /// YouTube Music artists and albums pinned to Home, by page id: enough
  /// to show the tile and open the page (the songs load when it opens).
  Map<String, Playlist> _pages = {};

  /// An artist's or album's page, which can be pinned though it isn't in
  /// the library.
  static bool isPage(Playlist playlist) =>
      playlist.id.startsWith('youtube:artist:') ||
      playlist.id.startsWith('youtube:album:');

  /// The pinned page [id] (its name and picture), or null.
  Playlist? page(String id) => _pages[id];

  /// Keeps [playlist]'s name and picture for its Home tile.
  void rememberPage(Playlist playlist) => _pages[playlist.id] = Playlist(
    id: playlist.id,
    name: playlist.name,
    tracks: const [],
    artworkUrl: playlist.artworkUrl,
  );

  Map<String, Set<String>> _tagged = {};

  /// Folders that couldn't be read on the last scan, by folder id.
  final folderErrors = <String, String>{};

  bool _scanning = false;
  bool _ready = false;
  Future<void>? _loading;

  List<LibraryFolder> get folders => List.unmodifiable(_folders);
  bool get scanning => _scanning;

  /// Whether the first scan has finished.
  bool get loaded => _ready;

  /// Liked Songs, the user's playlists, then folder playlists.
  List<Playlist> get all => [
    _liked,
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

  /// Your playlists replaced by a folder here (see [replaceWithFolder]).
  Set<String> _foldered = {};

  /// Each folder playlist's key in [_hidden], by playlist id.
  final _hideKeys = <String, String>{};

  List<Playlist> get custom => List.unmodifiable(_custom);

  /// Every song in the library folders, once each (hidden folders left
  /// out), by title.
  List<Track> get allSongs {
    final seen = <String>{};
    return [
      for (final playlist in all)
        if (!playlist.isCustom)
          for (final track in playlist.tracks)
            if (seen.add(track.path)) track,
    ];
  }

  /// Liked Songs and tag playlists: made by Musify, not renamed or deleted.
  /// A YouTube playlist (charts, search results): not in the library, so
  /// nothing to rename, delete, pin or remove songs from.
  static bool isRemote(Playlist playlist) => playlist.id.startsWith('youtube:');

  static bool isSystem(Playlist playlist) =>
      playlist.id == likedId || playlist.id.startsWith(_tagPrefix);

  /// Every song with [tag], across the whole library, as a playlist.
  Playlist tagPlaylist(SongTag tag) => Playlist(
    id: '$_tagPrefix${tag.id}',
    name: tag.name,
    tracks: [
      for (final track in allSongs)
        if (hasTag(track, tag)) track,
    ],
  );

  /// Where [track] lives: its folder, then the playlists the user made
  /// that hold it (shown on a tag's songs).
  List<String> placesOf(Track track) {
    final folder = p.dirname(track.path);
    return [
      for (final playlist in _folderPlaylists)
        if (p.equals(playlist.id, folder)) playlist.name,
      for (final playlist in _custom)
        if (playlist.tracks.any((t) => t.path == track.path)) playlist.name,
    ];
  }

  Playlist? byId(String id) {
    if (id.startsWith(_tagPrefix)) {
      final tagId = id.substring(_tagPrefix.length);
      final tag = _tags.where((t) => t.id == tagId).firstOrNull;
      return tag == null ? null : tagPlaylist(tag);
    }
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
    _foldered = await LibraryStore.loadFoldered();
    _pins = await LibraryStore.loadPinned();
    _pages = {for (final p in await LibraryStore.loadPages()) p.id: p};
    _likedSaved = await LibraryStore.loadLiked();
    _tagsSaved = await LibraryStore.loadTags() ?? const [_defaultTag];
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
    // Songs changed in another app show their new tags, length and cover.
    for (final path in await MetadataService.forgetChanged()) {
      CoverFiles.forget(path);
    }
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

  /// Moves a song's file into [folder] (a name taken there gets " (2)"),
  /// keeping it in its playlists, Liked Songs and tags. Returns where it is
  /// now, or null if it couldn't be moved.
  Future<String?> moveSong(Track track, String folder) async {
    if (track is YouTubeTrack) return null;
    final from = File(track.path);
    if (p.equals(p.dirname(track.path), folder)) return track.path;
    final base = p.basenameWithoutExtension(track.path);
    final ext = p.extension(track.path);
    var target = p.join(folder, '$base$ext');
    for (var n = 2; File(target).existsSync(); n++) {
      target = p.join(folder, '$base ($n)$ext');
    }
    // What names this song, found while it's still where they say.
    bool names(SavedTrack saved) =>
        saved.path == track.path || _resolve(saved) == track.path;
    final naming = <SavedTrack>{
      for (final s in _saved) ...s.tracks.where(names),
      ..._likedSaved.where(names),
      for (final t in _tagsSaved) ...t.tracks.where(names),
    };
    try {
      await Directory(folder).create(recursive: true);
      try {
        await from.rename(target);
      } on FileSystemException {
        // Another folder on another disk (or iOS location): copy, then
        // delete.
        await from.copy(target);
        await from.delete();
      }
    } on FileSystemException catch (e) {
      AppLog.add('move: ${track.path} failed: ${e.message}');
      return null;
    }
    AppLog.add('move: ${track.path} -> $target');
    // Everything that named the old place names the new one.
    final moved = _save(Track(target));
    SavedTrack follow(SavedTrack saved) =>
        naming.contains(saved) ? moved : saved;
    _saved = [
      for (final s in _saved)
        SavedPlaylist(s.id, s.name, [for (final t in s.tracks) follow(t)]),
    ];
    _likedSaved = [for (final t in _likedSaved) follow(t)];
    _tagsSaved = [
      for (final t in _tagsSaved)
        SavedTag(t.id, t.name, t.color, [for (final s in t.tracks) follow(s)]),
    ];
    LibraryStore.savePlaylists(_saved);
    LibraryStore.saveLiked(_likedSaved);
    LibraryStore.saveTags(_tagsSaved);
    await rescan();
    // The other devices move theirs too.
    SyncService.instance.filesChanged();
    return target;
  }

  /// Folder playlists renamed this run: old id to new, so a page showing
  /// one stays on it.
  final _renamed = <String, String>{};

  /// Where the folder playlist [id] went if it was renamed, else [id].
  String currentId(String id) {
    var at = id;
    for (var i = 0; i < 20 && _renamed.containsKey(at); i++) {
      at = _renamed[at]!;
    }
    return at;
  }

  /// Renames a folder playlist's folder on the device; its subfolders go
  /// along. Its songs stay in playlists, Liked Songs and tags, it keeps its
  /// pin (or stays hidden), what's playing carries on, and the other
  /// devices rename theirs. Returns null once done, else why it couldn't.
  Future<String?> renameFolder(Playlist playlist, String name) async {
    final location = playlist.location;
    final key = _hideKeys[playlist.id];
    if (location == null || key == null) return "It isn't a folder";
    if (location == '.') {
      return 'This is a folder you added to Musify: rename it in Files '
          '(Finder on a Mac), then add it again';
    }
    name = name.trim();
    if (name.isEmpty || name.startsWith('.')) return 'Type a name';
    if (name.contains(RegExp(r'[/\\:]'))) {
      return r"Folder names can't have / \ or : in them";
    }
    final from = playlist.id;
    final to = p.join(p.dirname(from), name);
    if (from == to) return null;
    // Only the case changing is the same folder on a Mac or iPhone.
    if (from.toLowerCase() != to.toLowerCase() &&
        FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) {
      return 'There already is a "$name" there';
    }
    String follow(String path) => p.isWithin(from, path)
        ? p.join(to, p.relative(path, from: from))
        : path;

    // What names songs in it, found while they're still where they say.
    final moved = <SavedTrack, SavedTrack>{};
    for (final saved in [
      for (final s in _saved) ...s.tracks,
      ..._likedSaved,
      for (final t in _tagsSaved) ...t.tracks,
    ]) {
      final path = saved.youtube == null ? _resolve(saved) : null;
      if (path != null && p.isWithin(from, path)) {
        moved[saved] = _save(Track(follow(path)));
      }
    }

    // What's playing from it picks up where it was, from the new place.
    final player = PlayerService.instance;
    final sequence = [
      for (final source in player.player.sequence) source.tag as Track,
    ];
    final affected = sequence.any(
      (t) => t is! YouTubeTrack && p.isWithin(from, t.path),
    );
    final order = player.order;
    final index = player.player.currentIndex;
    final position = player.player.position;
    final wasPlaying = player.player.playing;
    final loop = player.player.loopMode;
    final current = player.current;
    if (affected) await player.player.pause();

    try {
      await Directory(from).rename(to);
    } on FileSystemException catch (e) {
      AppLog.add('rename: $from failed: ${e.message}');
      if (affected && wasPlaying) player.player.play();
      return "Couldn't rename it: ${e.message}";
    }
    AppLog.add('rename: $from -> $to');
    _renamed[from] = to;
    for (final old in _folderPlaylists) {
      if (p.isWithin(from, old.id)) _renamed[old.id] = follow(old.id);
    }

    SavedTrack again(SavedTrack saved) => moved[saved] ?? saved;
    _saved = [
      for (final s in _saved)
        SavedPlaylist(s.id, s.name, [for (final t in s.tracks) again(t)]),
    ];
    _likedSaved = [for (final t in _likedSaved) again(t)];
    _tagsSaved = [
      for (final t in _tagsSaved)
        SavedTag(t.id, t.name, t.color, [for (final s in t.tracks) again(s)]),
    ];
    // Pins and hiding go by place in the folder: this one's and those of
    // the folders inside it.
    final bar = key.indexOf('|');
    final oldKey = key;
    final newKey =
        '${key.substring(0, bar)}|'
        '${p.normalize(p.join(p.dirname(location), name))}';
    String rekey(String k) => k == oldKey
        ? newKey
        : k.startsWith('$oldKey/')
        ? '$newKey${k.substring(oldKey.length)}'
        : k;
    _pins = [for (final k in _pins) rekey(k)];
    _hidden = {for (final k in _hidden) rekey(k)};
    LibraryStore.savePlaylists(_saved);
    LibraryStore.saveLiked(_likedSaved);
    LibraryStore.saveTags(_tagsSaved);
    LibraryStore.savePinned(_pins);
    LibraryStore.saveHidden(_hidden);
    await Downloads.followRename(from, to);
    await rescan();

    if (affected && index != null) {
      Track there(Track t) => t is YouTubeTrack || !p.isWithin(from, t.path)
          ? t
          : t is QueuedTrack
          ? QueuedTrack(follow(t.path))
          : Track(follow(t.path));
      await player.restore(
        playlist: current == null ? null : byId(currentId(current.id)),
        sequence: sequence.map(there).toList(),
        order: order.map(there).toList(),
        index: index,
        position: position,
        shuffle: player.shuffleOn.value,
        loop: loop,
      );
      if (wasPlaying) player.player.play();
    }
    // The other devices rename theirs too.
    SyncService.instance.filesChanged();
    return null;
  }

  /// Deletes a song's file from the device, then rescans; it leaves every
  /// playlist with it. Stops the player if it's the one playing. False if
  /// the file couldn't be deleted.
  Future<bool> deleteSong(Track track) async {
    if (track is YouTubeTrack) return false;
    final player = PlayerService.instance;
    if (player.currentTrack?.path == track.path) await player.stop();
    try {
      await File(track.path).delete();
    } on FileSystemException catch (e) {
      AppLog.add('delete: ${track.path} failed: ${e.message}');
      return false;
    }
    AppLog.add('delete: ${track.path}');
    await rescan();
    // Gone from the user's other devices too, if it was a synced song.
    SyncService.instance.filesChanged();
    return true;
  }

  // Sync ----------------------------------------------------------------------

  /// What the user's other devices share (see SyncService): the saved
  /// form, songs this device can't find included.
  List<SavedPlaylist> get savedPlaylists => List.unmodifiable(_saved);
  List<SavedTag> get savedTags => List.unmodifiable(_tagsSaved);
  List<SavedTrack> get savedLiked => List.unmodifiable(_likedSaved);
  List<String> get pinKeys => List.unmodifiable(_pins);

  /// [playlist]'s name that survives the folder moving (see pins).
  String stableKey(Playlist playlist) => _pinKey(playlist);

  /// Where a saved song is on this device, or null.
  String? resolve(SavedTrack saved) => _resolve(saved);

  /// The saved form of [track] here (which folder, where inside it).
  SavedTrack saveForm(Track track) => _save(track);

  /// Takes on what sync merged from all devices.
  void applySync({
    List<SavedPlaylist>? playlists,
    List<SavedTag>? tags,
    List<SavedTrack>? liked,
    List<String>? pins,
  }) {
    if (playlists != null) {
      _saved = playlists;
      LibraryStore.savePlaylists(_saved);
    }
    if (tags != null) {
      _tagsSaved = tags;
      LibraryStore.saveTags(_tagsSaved);
    }
    if (liked != null) {
      _likedSaved = liked;
      LibraryStore.saveLiked(_likedSaved);
    }
    if (pins != null) {
      _pins = pins;
      LibraryStore.savePinned(_pins);
      LibraryStore.savePages(_pages.values.toList());
    }
    _resolveCustom();
    notifyListeners();
  }

  // Liked Songs -----------------------------------------------------------------

  Playlist get liked => _liked;

  bool isLiked(Track track) => _liked.tracks.any((t) => t.path == track.path);

  /// Likes or unlikes [track]; newly liked songs go to the top.
  void toggleLike(Track track) {
    if (isLiked(track)) {
      _likedSaved = [
        for (final t in _likedSaved)
          if (_resolve(t) != track.path) t,
      ];
    } else {
      _likedSaved = [_save(track), ..._likedSaved];
    }
    _resolveCustom();
    notifyListeners();
    LibraryStore.saveLiked(_likedSaved);
  }

  // Tags --------------------------------------------------------------------------

  List<SongTag> get tags => List.unmodifiable(_tags);

  List<SongTag> tagsOf(Track track) => [
    for (final tag in _tags)
      if (_tagged[tag.id]?.contains(track.path) ?? false) tag,
  ];

  bool hasTag(Track track, SongTag tag) =>
      _tagged[tag.id]?.contains(track.path) ?? false;

  SongTag createTag(String name, Color color) {
    final id = 'tag${DateTime.now().microsecondsSinceEpoch}';
    _tagsSaved = [
      ..._tagsSaved,
      SavedTag(id, name, color.toARGB32(), const []),
    ];
    _commitTags();
    return _tags.firstWhere((t) => t.id == id);
  }

  void deleteTag(SongTag tag) {
    _tagsSaved = [
      for (final t in _tagsSaved)
        if (t.id != tag.id) t,
    ];
    _commitTags();
  }

  void toggleTag(Track track, SongTag tag) {
    final on = hasTag(track, tag);
    _tagsSaved = [
      for (final t in _tagsSaved)
        t.id != tag.id
            ? t
            : SavedTag(t.id, t.name, t.color, [
                for (final saved in t.tracks)
                  if (_resolve(saved) != track.path) saved,
                if (!on) _save(track),
              ]),
    ];
    _commitTags();
  }

  void _commitTags() {
    _resolveTags();
    notifyListeners();
    LibraryStore.saveTags(_tagsSaved);
  }

  void _resolveTags() {
    _tags = [
      for (final t in _tagsSaved)
        SongTag(id: t.id, name: t.name, color: Color(t.color)),
    ];
    _tagged = {
      for (final t in _tagsSaved)
        t.id: {for (final saved in t.tracks) ?_resolve(saved)},
    };
  }

  // The user's playlists ------------------------------------------------------

  /// A new playlist of yours, empty or with [tracks].
  Playlist createPlaylist(String name, {List<Track> tracks = const []}) {
    final id =
        '${DateTime.now().microsecondsSinceEpoch}'
        '${Random().nextInt(1 << 20)}';
    final seen = <String>{};
    _saved = [
      ..._saved,
      SavedPlaylist(id, name, [
        for (final t in tracks)
          if (seen.add(t.path)) _save(t),
      ]),
    ];
    _commit();
    return byId('$_customPrefix$id')!;
  }

  void renamePlaylist(Playlist playlist, String name) {
    _update(playlist, (s) => SavedPlaylist(s.id, name, s.tracks));
  }

  /// [playlist] (one of yours) is now [folder] on this device, Download
  /// playlist having saved its songs there: it's no longer shown here and
  /// its pin moves to the folder, but it's kept, so other devices, which
  /// may not have the folder, keep the playlist.
  void replaceWithFolder(Playlist playlist, Playlist folder) {
    final pinned = isPinned(playlist);
    final key = playlist.id.substring(_customPrefix.length);
    _foldered = {..._foldered, key};
    LibraryStore.saveFoldered(_foldered);
    if (pinned && !isPinned(folder)) togglePin(folder);
    _resolveCustom();
    notifyListeners();
  }

  void deletePlaylist(Playlist playlist) {
    if (playlist.id == likedId) return;
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
    if (playlist.id.startsWith(_tagPrefix)) {
      final tag = _tags
          .where((t) => '$_tagPrefix${t.id}' == playlist.id)
          .firstOrNull;
      if (tag != null && hasTag(track, tag)) toggleTag(track, tag);
      return;
    }
    if (playlist.id == likedId) {
      if (isLiked(track)) toggleLike(track);
      return;
    }
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
    if (track is YouTubeTrack) {
      return SavedTrack(track.path, youtube: track.toJson());
    }
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
    if (saved.youtube != null) return saved.path;
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

  /// A saved song as it is now, or null if it can't be found.
  Track? _trackOf(SavedTrack saved) {
    if (saved.youtube case final youtube?) {
      try {
        return YouTubeTrack.fromJson(youtube);
      } catch (_) {
        return null;
      }
    }
    final path = _resolve(saved);
    return path == null ? null : Track(path);
  }

  void _resolveCustom() {
    _liked = Playlist(
      id: likedId,
      name: 'Liked Songs',
      tracks: [for (final t in _likedSaved) ?_trackOf(t)],
    );
    _resolveTags();
    _custom = [
      for (final s in _saved)
        if (!_foldered.contains(s.id))
          Playlist(
            id: _idOf(s),
            name: s.name,
            tracks: [for (final t in s.tracks) ?_trackOf(t)],
          ),
    ];
  }
}
