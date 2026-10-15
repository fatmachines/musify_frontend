import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/name_playlist_screen.dart';
import '../services/library.dart';
import '../theme.dart';
import 'covers.dart';
import 'download_sheet.dart';
import 'folders_sheet.dart';
import 'toast.dart';

const _danger = Color(0xFFF15E6C);

/// The menu for a whole playlist, from its page's ••• or a long press in
/// Your Library or on Home. Liked Songs and tags can only be pinned.
Future<void> showPlaylistActions(BuildContext context, Playlist playlist) {
  final songs = playlist.tracks.length;
  final library = Library.instance;
  final system = Library.isSystem(playlist);
  final pinned = library.isPinned(playlist);
  final remote = Library.isRemote(playlist);
  final youtube = playlist.tracks.whereType<YouTubeTrack>().length;
  final page = Library.isPage(playlist);
  final kind = playlist.id.startsWith('youtube:artist:')
      ? 'Artist'
      : playlist.id.startsWith('youtube:album:')
      ? 'Album'
      : playlist.isCustom
      ? 'Playlist'
      : 'Folder';
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: PlaylistCover(playlist: playlist, size: 48),
              title: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // A pinned page's songs load when it opens.
              subtitle: Text(
                page && songs == 0
                    ? kind
                    : '$kind • $songs ${songs == 1 ? 'song' : 'songs'}',
              ),
            ),
            Divider(color: AppColors.faint, height: 16),
            if (youtube > 0)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Download playlist'),
                subtitle: Text(
                  '$youtube YouTube ${youtube == 1 ? 'song' : 'songs'} into '
                  'a new folder',
                ),
                onTap: () {
                  Navigator.of(sheet).pop();
                  downloadPlaylistWithPicker(context, playlist);
                },
              ),
            // YouTube playlists aren't in the library to pin or change;
            // artists and albums can be pinned.
            if (!remote || page)
              ListTile(
                leading: Icon(
                  pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: pinned ? AppColors.green : null,
                ),
                title: Text(pinned ? 'Unpin from Home' : 'Pin to Home'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  library.togglePin(playlist);
                  showToast(
                    context,
                    pinned ? 'Unpinned from Home' : 'Pinned to Home',
                  );
                },
              ),
            if (playlist.isCustom && !system && !remote)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  final name = await askPlaylistName(
                    context,
                    title: 'Rename playlist',
                    initial: playlist.name,
                    action: 'Save',
                  );
                  if (name != null) {
                    Library.instance.renamePlaylist(playlist, name);
                  }
                },
              ),
            // A folder the user added says to rename it in Files.
            if (!playlist.isCustom)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename folder'),
                subtitle: const Text('Renames it on this device too'),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  final name = await askPlaylistName(
                    context,
                    title: 'Rename folder',
                    initial: playlist.name,
                    action: 'Save',
                    validate: (name) => name == playlist.name
                        ? null
                        : Library.instance.folderNameError(playlist, name),
                  );
                  if (name == null || name.trim() == playlist.name) return;
                  if (!context.mounted || !await ensureFileAccess(context)) {
                    return;
                  }
                  final error = await Library.instance.renameFolder(
                    playlist,
                    name,
                  );
                  if (context.mounted) {
                    showToast(context, error ?? 'Renamed to ${name.trim()}');
                  }
                },
              ),
            if (!system && !remote)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete playlist'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  confirmDeletePlaylist(context, playlist);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

/// Your playlists are simply deleted. A folder playlist asks whether to
/// hide it from Musify or delete its songs from the device.
Future<void> confirmDeletePlaylist(BuildContext context, Playlist playlist) {
  return playlist.isCustom
      ? _deleteCustom(context, playlist)
      : _deleteFolder(context, playlist);
}

Future<void> _deleteCustom(BuildContext context, Playlist playlist) async {
  // The playlist's own page closes once it's gone.
  final overlay = Overlay.of(context, rootOverlay: true);
  final delete = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text('Delete "${playlist.name}"?'),
      content: const Text('The songs stay in your folders.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          style: TextButton.styleFrom(foregroundColor: _danger),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (delete != true) return;
  Library.instance.deletePlaylist(playlist);
  showToastOn(overlay, 'Deleted ${playlist.name}');
}

enum _FolderChoice { hide, delete }

Future<void> _deleteFolder(BuildContext context, Playlist playlist) async {
  final songs = playlist.tracks.length;
  final count = '$songs ${songs == 1 ? 'song' : 'songs'}';
  // The playlist's own page closes once it's gone.
  final overlay = Overlay.of(context, rootOverlay: true);
  final choice = await showDialog<_FolderChoice>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text('Delete "${playlist.name}"?'),
      content: Text(
        'This playlist is a folder on your device.\n\n'
        'Hide it to remove it from Musify only; its files stay where they '
        'are and you can show it again from Manage folders.\n\n'
        'Delete from device permanently deletes its $count. This can\'t be '
        'undone.',
      ),
      actionsOverflowDirection: VerticalDirection.up,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_FolderChoice.hide),
          child: const Text('Hide from Musify'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(_FolderChoice.delete),
          style: TextButton.styleFrom(foregroundColor: _danger),
          child: const Text('Delete from device'),
        ),
      ],
    ),
  );
  switch (choice) {
    case null:
      return;
    case _FolderChoice.hide:
      Library.instance.hidePlaylist(playlist);
      showToastOn(overlay, 'Hid ${playlist.name}');
    case _FolderChoice.delete:
      if (!context.mounted || !await ensureFileAccess(context)) return;
      final deleted = await Library.instance.deleteFromDevice(playlist);
      showToastOn(
        overlay,
        deleted == songs
            ? 'Deleted ${playlist.name}'
            : 'Deleted $deleted of $songs songs',
      );
  }
}
