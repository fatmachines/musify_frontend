import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'library_store.dart';

/// A folder the user added to the library.
class LibraryFolder {
  /// Stable id: the bookmark's id on iOS, the path on Android.
  final String id;
  final String path;

  const LibraryFolder(this.id, this.path);

  String get name => p.basename(path);
}

/// Picks library folders and keeps them readable.
///
/// On iOS (a folder from Files) and the Mac (sandboxed) a folder is only
/// readable once the app starts security-scoped access to it, which
/// file_picker doesn't do; the native FolderAccessPlugin
/// (ios/Runner/AppDelegate.swift, macos/Runner/MainFlutterWindow.swift) does
/// that and bookmarks each folder so access survives relaunches. Android
/// keeps plain paths.
class FolderAccess {
  static const _channel = MethodChannel('musify/folder_access');

  static bool get _native => Platform.isIOS || Platform.isMacOS;

  static Future<LibraryFolder?> pick() async {
    if (_native) {
      final reply = await _callNative('pick');
      final folder = reply?['folder'];
      return folder is Map ? _folder(folder) : null;
    }
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a music folder',
    );
    AppLog.add('pick: file_picker returned $path');
    if (path == null) return null;
    final paths = await LibraryStore.loadFolderPaths();
    if (!paths.contains(path)) {
      await LibraryStore.saveFolderPaths([...paths, path]);
    }
    return LibraryFolder(path, path);
  }

  /// Every folder added before, opened for reading.
  static Future<List<LibraryFolder>> restoreAll() async {
    if (_native) {
      final reply = await _callNative('restoreAll');
      final folders = reply?['folders'];
      return [
        if (folders is List)
          for (final f in folders)
            if (f is Map) _folder(f),
      ];
    }
    final paths = await LibraryStore.loadFolderPaths();
    AppLog.add('restore: folders $paths');
    return [for (final path in paths) LibraryFolder(path, path)];
  }

  static Future<void> remove(LibraryFolder folder) async {
    if (_native) {
      await _callNative('remove', {'id': folder.id});
      return;
    }
    final paths = await LibraryStore.loadFolderPaths();
    await LibraryStore.saveFolderPaths(paths..remove(folder.path));
  }

  static LibraryFolder _folder(Map map) =>
      LibraryFolder(map['id'] as String, map['path'] as String);

  /// The native side answers with a map that includes its log lines.
  static Future<Map?> _callNative(String method, [Object? arguments]) async {
    try {
      final reply = await _channel.invokeMethod<Map>(method, arguments);
      final log = (reply?['log'] as List?)?.cast<String>() ?? const [];
      AppLog.addAll(log.map((line) => 'native: $line'));
      AppLog.add('$method: native replied');
      return reply;
    } catch (e) {
      // MissingPluginException included: it means the native plugin never
      // registered.
      AppLog.add('$method: native call failed: $e');
      return null;
    }
  }
}
