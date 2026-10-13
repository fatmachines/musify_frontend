import '../models/playlist.dart';
import 'app_log.dart';
import 'folder_access.dart';
import 'library_scanner.dart';
import 'library_store.dart';

/// The playlists from the latest scan, shared by the Library tab and the
/// system media browser (Android Auto), which can ask for them before any
/// screen has been shown.
class Library {
  static List<Playlist>? _latest;
  static Future<List<Playlist>>? _loading;

  static void update(List<Playlist> playlists) => _latest = playlists;

  static Future<List<Playlist>> playlists() async {
    final latest = _latest;
    if (latest != null) return latest;
    return _loading ??= _loadSaved().whenComplete(() => _loading = null);
  }

  static Future<List<Playlist>> _loadSaved() async {
    final root = await FolderAccess.restore(await LibraryStore.loadRoot());
    if (root == null) return const [];
    final result = await LibraryScanner.scan(root);
    AppLog.addAll(result.log);
    _latest = result.playlists;
    return result.playlists;
  }
}
