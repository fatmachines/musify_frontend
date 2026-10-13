import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A song saved in a user's playlist. Besides its path it remembers which
/// library folder it came from and where inside it, so it can still be found
/// if that folder's path changes (iOS can move app data on reinstall).
class SavedTrack {
  final String path;
  final String? folderId;
  final String? relative;

  const SavedTrack(this.path, {this.folderId, this.relative});

  Map<String, Object?> toJson() => {
    'path': path,
    if (folderId != null) 'folder': folderId,
    if (relative != null) 'rel': relative,
  };

  static SavedTrack fromJson(Map<String, Object?> json) => SavedTrack(
    json['path'] as String,
    folderId: json['folder'] as String?,
    relative: json['rel'] as String?,
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

/// What the library keeps between launches.
class LibraryStore {
  // Before several folders were supported there was a single one.
  static const _legacyRootKey = 'library_root_path';
  static const _foldersKey = 'library_folders';
  static const _playlistsKey = 'custom_playlists_v1';

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
