import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/name_playlist_screen.dart';
import '../services/library.dart';
import '../services/player_service.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/list_scrollbar.dart';
import '../widgets/folders_sheet.dart';
import '../widgets/navigation.dart';
import '../widgets/covers.dart';
import '../widgets/import_playlist.dart';
import '../widgets/offline_badge.dart';
import '../widgets/playlist_actions.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final _library = Library.instance;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _library.ensureLoaded();
  }

  Future<void> _createPlaylist() async {
    final name = await askPlaylistName(
      context,
      initial: 'My playlist #${_library.custom.length + 1}',
    );
    if (name == null || !mounted) return;
    final playlist = _library.createPlaylist(name);
    openPlaylist(context, playlist);
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
                  addMusicFolder(context);
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
              _MenuTile(
                icon: Icons.playlist_add,
                title: 'Import playlist',
                subtitle: 'From a YouTube, YouTube Music or Spotify link',
                onTap: () {
                  Navigator.of(sheet).pop();
                  importPlaylist(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.green,
              child: Icon(Icons.music_note, size: 18, color: Colors.black),
            ),
            SizedBox(width: 12),
            // Shrinks rather than overflowing a narrow sidebar.
            Flexible(
              child: Text('Your Library', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add',
            icon: const Icon(Icons.add, size: 30),
            onPressed: _showAddMenu,
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
        onAddFolder: () => addMusicFolder(context),
        onCreatePlaylist: _createPlaylist,
      );
    }
    final broken = _library.folderErrors.length;
    return RefreshIndicator(
      onRefresh: () async {
        await _library.rescan();
        // New or removed songs reach the other devices.
        SyncService.instance.filesChanged();
      },
      // Rebuilds tiles when playback moves to another playlist.
      child: StreamBuilder(
        stream: PlayerService.instance.player.sequenceStateStream,
        builder: (context, _) => ListScrollbar(
          controller: _scroll,
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.only(
              top: 8,
              bottom: MediaQuery.paddingOf(context).bottom + 8,
            ),
            children: [
              if (_library.scanning)
                const LinearProgressIndicator(minHeight: 2),
              if (broken > 0)
                ListTile(
                  leading: const Icon(
                    Icons.error_outline,
                    color: Colors.orange,
                  ),
                  title: Text(
                    broken == 1
                        ? "A folder can't be opened"
                        : "$broken folders can't be opened",
                  ),
                  subtitle: const Text('Tap to manage folders'),
                  onTap: () => showManageFolders(context),
                ),
              for (final playlist in playlists)
                _PlaylistTile(
                  playlist: playlist,
                  playing: PlayerService.instance.isCurrent(playlist),
                ),
            ],
          ),
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
      onTap: () => openPlaylist(context, playlist),
      onLongPress: () => showPlaylistActions(context, playlist),
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
                          style: TextStyle(
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
              Icon(Icons.volume_up, color: AppColors.green, size: 20),
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
              style: TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle, fontSize: 14),
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
