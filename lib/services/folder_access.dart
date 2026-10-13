import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';

/// Picks the library folder and keeps it readable.
///
/// On iOS a folder from Files is only readable once the app starts
/// security-scoped access to it, which file_picker doesn't do; the native
/// FolderAccessPlugin (ios/Runner/AppDelegate.swift) does that and bookmarks
/// the folder so access survives relaunches.
class FolderAccess {
  static const _channel = MethodChannel('musify/folder_access');

  static Future<String?> pick() async {
    if (!Platform.isIOS) {
      final path = await FilePicker.getDirectoryPath(
          dialogTitle: 'Choose your music folder');
      AppLog.add('pick: file_picker returned $path');
      return path;
    }
    return _callNative('pick');
  }

  /// Returns the path to scan for a previously picked folder, or null if
  /// there is none. On iOS the bookmark, not [savedPath], is the source of
  /// truth.
  static Future<String?> restore(String? savedPath) async {
    if (!Platform.isIOS) {
      AppLog.add('restore: saved path $savedPath');
      return savedPath;
    }
    return _callNative('restore');
  }

  /// The native side answers with {path, log}; its log joins ours.
  static Future<String?> _callNative(String method) async {
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(method);
      final log = (reply?['log'] as List?)?.cast<String>() ?? const [];
      AppLog.addAll(log.map((line) => 'ios: $line'));
      final path = reply?['path'] as String?;
      AppLog.add('$method: native returned $path');
      return path;
    } catch (e) {
      // MissingPluginException included: it means the native plugin never
      // registered.
      AppLog.add('$method: native call failed: $e');
      return null;
    }
  }
}
