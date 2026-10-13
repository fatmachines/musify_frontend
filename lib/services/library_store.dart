import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which folder the user picked as their music library.
class LibraryStore {
  static const _rootKey = 'library_root_path';

  static Future<String?> loadRoot() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_rootKey);
  }

  static Future<void> saveRoot(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rootKey, path);
  }
}
