import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/playlist.dart';
import '../screens/name_playlist_screen.dart';
import '../screens/playlist_screen.dart';
import '../services/app_log.dart';
import '../services/folder_access.dart';
import '../services/library.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/offline_badge.dart';
import '../widgets/playlist_actions.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _library = Library.instance;

  @override
  void initState() {
    super.initState();
    _library.ensureLoaded();
  }

  /// Android 13+ grants audio files through READ_MEDIA_AUDIO; older versions
  /// use READ_EXTERNAL_STORAGE. Whichever applies to the device is the one
  /// that can come back granted.
  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [Permission.audio, Permission.storage].request();
    if (statuses.values.any((s) => s.isGranted || s.isLimited)) return true;

    if (!mounted) return false;
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

  Future<void> _addFolder() async {
    if (!await _ensurePermission()) return;
    await _library.addFolder();
  }

  Future<void> _createPlaylist() async {
    final name = await askPlaylistName(
      context,
      initial: 'My playlist #${_library.custom.length + 1}',
    );
    if (name == null || !mounted) return;
    final playlist = _library.createPlaylist(name);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: playlist)),
    );
  }

  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        // Sized to its content, scrolling on screens too short for it.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuTile(
                icon: Icons.create_new_folder_outlined,
                title: 'Add folder',
                subtitle: 'Every folder in it with music becomes a playlist',
                onTap: () {
                  Navigator.of(sheet).pop();
                  _addFolder();
                },
              ),
              _MenuTile(
                icon: Icons.queue_music,
                title: 'Create playlist',
                subtitle: 'Mix songs from any of your folders',
                onTap: () {
                  Navigator.of(sheet).pop();
                  _createPlaylist();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _showFolders() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        // Sized to its content, scrolling on screens too short for it.
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: _library,
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
                if (_library.folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No folders added yet.',
                      style: TextStyle(color: AppColors.subtle),
                    ),
                  ),
                for (final folder in _library.folders)
                  ListTile(
                    leading: Icon(
                      _library.folderErrors.containsKey(folder.id)
                          ? Icons.error_outline
                          : Icons.folder_outlined,
                    ),
                    title: Text(folder.name),
                    subtitle: Text(
                      _library.folderErrors.containsKey(folder.id)
                          ? "Can't be opened. Remove it and add it again."
                          : folder.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _confirmRemove(folder),
                    ),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Add folder'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _addFolder();
                  },
                ),
                if (_library.hidden.isNotEmpty) ...[
                  const Divider(color: Colors.white12, height: 24),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Hidden playlists',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final playlist in _library.hidden)
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
                        onPressed: () => _library.unhidePlaylist(playlist),
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

  Future<void> _confirmRemove(LibraryFolder folder) async {
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
    if (remove == true) await _library.removeFolder(folder);
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: AppLog.dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Debug log copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.green,
              child: Icon(Icons.music_note, size: 18, color: Colors.black),
            ),
            SizedBox(width: 12),
            Text('Your Library'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add, size: 30),
            onPressed: _showAddMenu,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'rescan':
                  _library.rescan();
                case 'folders':
                  _showFolders();
                case 'log':
                  _copyLog();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rescan', child: Text('Rescan')),
              PopupMenuItem(value: 'folders', child: Text('Manage folders')),
              PopupMenuItem(value: 'log', child: Text('Copy debug log')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _library,
        builder: (context, _) => _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final playlists = _library.all;
    if (playlists.isEmpty) {
      if (_library.scanning || !_library.loaded) {
        return const Center(child: CircularProgressIndicator());
      }
      return _EmptyState(
        title: _library.folders.isEmpty ? 'Add your music' : 'No music found',
        message: _library.folders.isEmpty
            ? 'Add a folder from your device. Every folder in it with music '
                  'becomes a playlist.'
            : 'Nothing playable in your folders.',
        onAddFolder: _addFolder,
        onCreatePlaylist: _createPlaylist,
      );
    }
    final broken = _library.folderErrors.length;
    return RefreshIndicator(
      onRefresh: _library.rescan,
      // Rebuilds tiles when playback moves to another playlist.
      child: StreamBuilder(
        stream: PlayerService.instance.player.sequenceStateStream,
        builder: (context, _) => ListView(
          padding: EdgeInsets.only(
            top: 8,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
          ),
          children: [
            if (_library.scanning) const LinearProgressIndicator(minHeight: 2),
            if (broken > 0)
              ListTile(
                leading: const Icon(Icons.error_outline, color: Colors.orange),
                title: Text(
                  broken == 1
                      ? "A folder can't be opened"
                      : "$broken folders can't be opened",
                ),
                subtitle: const Text('Tap to manage folders'),
                onTap: _showFolders,
              ),
            for (final playlist in playlists)
              _PlaylistTile(
                playlist: playlist,
                playing: PlayerService.instance.isCurrent(playlist),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.chip,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Icon(icon, color: AppColors.text),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(subtitle),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool playing;

  const _PlaylistTile({required this.playlist, required this.playing});

  @override
  Widget build(BuildContext context) {
    final songs = playlist.tracks.length;
    final count = '$songs ${songs == 1 ? 'song' : 'songs'}';
    final location = playlist.location;
    // Only nested folders need their path to tell them apart.
    final detail = playlist.isCustom
        ? 'Playlist • $count'
        : location != '.' && location != playlist.name
        ? 'Folder • $location'
        : 'Folder • $count';
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: playlist)),
      ),
      onLongPress: Library.isSystem(playlist)
          ? null
          : () => showPlaylistActions(context, playlist),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            PlaylistCover(playlist: playlist, size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: playing ? AppColors.green : AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (!playlist.isCustom) ...[
                        const OfflineBadge(),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.subtle,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (playing)
              const Icon(Icons.volume_up, color: AppColors.green, size: 20),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onAddFolder;
  final VoidCallback onCreatePlaylist;

  const _EmptyState({
    required this.title,
    required this.message,
    required this.onAddFolder,
    required this.onCreatePlaylist,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.subtle, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAddFolder,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
              ),
              child: const Text('Add folder'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onCreatePlaylist,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.text,
                textStyle: const TextStyle(
                  fontFamily: 'Figtree',
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              child: const Text('Create playlist'),
            ),
          ],
        ),
      ),
    );
  }
}
