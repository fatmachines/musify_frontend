import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A song saved in a user's playlist. Besides its path it remembers which
/// library folder it came from and where inside it, so it can still be found
/// if that folder's path changes (iOS can move app data on reinstall). A
/// YouTube song keeps its details instead (see YouTubeTrack.toJson).
class SavedTrack {
  final String path;
  final String? folderId;
  final String? relative;
  final Map<String, Object?>? youtube;

  /// From another device (sync): how that device named the song, kept so
  /// it isn't lost while this device can't find the file.
  final Map<String, Object?>? ref;

  const SavedTrack(
    this.path, {
    this.folderId,
    this.relative,
    this.youtube,
    this.ref,
  });

  Map<String, Object?> toJson() => {
    'path': path,
    if (folderId != null) 'folder': folderId,
    if (relative != null) 'rel': relative,
    if (youtube != null) 'youtube': youtube,
    if (ref != null) 'ref': ref,
  };

  static SavedTrack fromJson(Map<String, Object?> json) => SavedTrack(
    json['path'] as String,
    folderId: json['folder'] as String?,
    relative: json['rel'] as String?,
    youtube: (json['youtube'] as Map?)?.cast<String, Object?>(),
    ref: (json['ref'] as Map?)?.cast<String, Object?>(),
  );
}

class SavedPlaylist {
  final String id;
  final String name;
  final List<SavedTrack> tracks;

  const SavedPlaylist(this.id, this.name, this.tracks);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tracks': [for (final t in tracks) t.toJson()],
  };

  static SavedPlaylist fromJson(Map<String, Object?> json) =>
      SavedPlaylist(json['id'] as String, json['name'] as String, [
        for (final t in json['tracks'] as List)
          SavedTrack.fromJson((t as Map).cast<String, Object?>()),
      ]);
}

class SavedTag {
  final String id;
  final String name;
  final int color;
  final List<SavedTrack> tracks;

  const SavedTag(this.id, this.name, this.color, this.tracks);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'color': color,
    'tracks': [for (final t in tracks) t.toJson()],
  };

  static SavedTag fromJson(Map<String, Object?> json) => SavedTag(
    json['id'] as String,
    json['name'] as String,
    json['color'] as int,
    [
      for (final t in json['tracks'] as List)
        SavedTrack.fromJson((t as Map).cast<String, Object?>()),
    ],
  );
}

/// What the library keeps between launches.
class LibraryStore {
  // Before several folders were supported there was a single one.
  static const _legacyRootKey = 'library_root_path';
  static const _foldersKey = 'library_folders';
  static const _playlistsKey = 'custom_playlists_v1';
  static const _hiddenKey = 'hidden_folder_playlists';
  static const _likedKey = 'liked_songs_v1';
  static const _tagsKey = 'song_tags_v1';
  static const _pinnedKey = 'home_pins_v1';

  /// Library folder paths (Android; iOS keeps bookmarks natively).
  static Future<List<String>> loadFolderPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final folders = prefs.getStringList(_foldersKey);
    if (folders != null) return folders;
    final legacy = prefs.getString(_legacyRootKey);
    return legacy == null ? [] : [legacy];
  }

  static Future<void> saveFolderPaths(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_foldersKey, paths);
    await prefs.remove(_legacyRootKey);
  }

  /// Folder playlists the user hid, as `<folder id>|<location>`.
  static Future<Set<String>> loadHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_hiddenKey) ?? const []).toSet();
  }

  static Future<void> saveHidden(Set<String> hidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, hidden.toList());
  }

  /// Liked songs, most recently liked first.
  static Future<List<SavedTrack>> loadLiked() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_likedKey);
    if (raw == null) return [];
    return [
      for (final t in jsonDecode(raw) as List)
        SavedTrack.fromJson((t as Map).cast<String, Object?>()),
    ];
  }

  static Future<void> saveLiked(List<SavedTrack> liked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _likedKey,
      jsonEncode([for (final t in liked) t.toJson()]),
    );
  }

  /// Tags in the order created, or null if tags were never saved (a fresh
  /// install).
  static Future<List<SavedTag>?> loadTags() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_tagsKey);
    if (raw == null) return null;
    return [
      for (final t in jsonDecode(raw) as List)
        SavedTag.fromJson((t as Map).cast<String, Object?>()),
    ];
  }

  static Future<void> saveTags(List<SavedTag> tags) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tagsKey,
      jsonEncode([for (final t in tags) t.toJson()]),
    );
  }

  /// Playlists pinned to Home, in the order pinned: a folder playlist as
  /// `<folder id>|<location>`, any other by its id.
  static Future<List<String>> loadPinned() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_pinnedKey) ?? [];
  }

  static Future<void> savePinned(List<String> pins) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_pinnedKey, pins);
  }

  static Future<List<SavedPlaylist>> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playlistsKey);
    if (raw == null) return [];
    return [
      for (final p in jsonDecode(raw) as List)
        SavedPlaylist.fromJson((p as Map).cast<String, Object?>()),
    ];
  }

  static Future<void> savePlaylists(List<SavedPlaylist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playlistsKey,
      jsonEncode([for (final p in playlists) p.toJson()]),
    );
  }
}
