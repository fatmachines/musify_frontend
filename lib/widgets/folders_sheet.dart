import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/folder_access.dart';
import '../services/library.dart';
import '../theme.dart';

/// Android 13+ grants audio files through READ_MEDIA_AUDIO; older versions
/// use READ_EXTERNAL_STORAGE. Whichever applies to the device is the one
/// that can come back granted.
Future<bool> _ensurePermission(BuildContext context) async {
  if (!Platform.isAndroid) return true;
  final statuses = await [Permission.audio, Permission.storage].request();
  if (statuses.values.any((s) => s.isGranted || s.isLimited)) return true;

  if (!context.mounted) return false;
  final permanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text('Musify needs access to your music files.'),
      action: permanentlyDenied
          ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
          : null,
    ),
  );
  return false;
}

/// Asks for a music folder (and, on Android, permission to read music)
/// and adds it to the library.
Future<void> addMusicFolder(BuildContext context) async {
  if (!await _ensurePermission(context)) return;
  await Library.instance.addFolder();
}

/// The library folders (remove one, add one) and hidden folder playlists
/// (show them again).
void showManageFolders(BuildContext context) {
  final library = Library.instance;
  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      // Sized to its content, scrolling on screens too short for it.
      child: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: library,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Music folders',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (library.folders.isEmpty)
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No folders added yet.',
                    style: TextStyle(color: AppColors.subtle),
                  ),
                ),
              for (final folder in library.folders)
                ListTile(
                  leading: Icon(
                    library.folderErrors.containsKey(folder.id)
                        ? Icons.error_outline
                        : Icons.folder_outlined,
                  ),
                  title: Text(folder.name),
                  subtitle: Text(
                    library.folderErrors.containsKey(folder.id)
                        ? "Can't be opened. Remove it and add it again."
                        : folder.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _confirmRemove(context, folder),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add folder'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  addMusicFolder(context);
                },
              ),
              if (library.hidden.isNotEmpty) ...[
                Divider(color: AppColors.faint, height: 24),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Hidden playlists',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                for (final playlist in library.hidden)
                  ListTile(
                    leading: const Icon(Icons.visibility_off_outlined),
                    title: Text(playlist.name),
                    // Only nested folders need their path.
                    subtitle: playlist.location == playlist.name
                        ? null
                        : Text(
                            playlist.location ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: TextButton(
                      onPressed: () => library.unhidePlaylist(playlist),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.text,
                      ),
                      child: const Text('Show'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _confirmRemove(BuildContext context, LibraryFolder folder) async {
  final remove = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text('Remove "${folder.name}"?'),
      content: const Text(
        'Its playlists leave your library. The music files stay on your '
        'device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (remove == true) await Library.instance.removeFolder(folder);
}
