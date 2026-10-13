import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// Picks the library folder and keeps it readable.
///
/// On iOS a folder from Files is only readable once the app starts
/// security-scoped access to it, which file_picker doesn't do; the native
/// FolderAccessPlugin (ios/Runner/AppDelegate.swift) does that and bookmarks
/// the folder so access survives relaunches.
class FolderAccess {
  static const _channel = MethodChannel('musify/folder_access');

  static Future<String?> pick() {
    if (Platform.isIOS) return _channel.invokeMethod<String>('pick');
    return FilePicker.getDirectoryPath(dialogTitle: 'Choose your music folder');
  }

  /// Returns the path to scan for a previously picked folder, or null if
  /// there is none. On iOS the bookmark, not [savedPath], is the source of
  /// truth.
  static Future<String?> restore(String? savedPath) {
    if (Platform.isIOS) return _channel.invokeMethod<String>('restore');
    return Future.value(savedPath);
  }
}
