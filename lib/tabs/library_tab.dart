import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../models/playlist.dart';
import '../screens/playlist_screen.dart';
import '../services/app_log.dart';
import '../services/folder_access.dart';
import '../services/library.dart';
import '../services/library_scanner.dart';
import '../services/library_store.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/offline_badge.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  String? _rootPath;
  List<Playlist> _playlists = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final root = await FolderAccess.restore(await LibraryStore.loadRoot());
    if (!mounted) return;
    if (root == null) {
      setState(() => _loading = false);
      return;
    }
    await _scan(root);
  }

  Future<void> _scan(String root) async {
    setState(() {
      _rootPath = root;
      _loading = true;
      _error = null;
    });
    final result = await LibraryScanner.scan(root);
    AppLog.addAll(result.log);
    Library.update(result.playlists);
    if (!mounted) return;
    setState(() {
      _playlists = result.playlists;
      _error = result.rootError == null
          ? null
          : "Musify can't open this folder. Choose it again to give access.";
      _loading = false;
    });
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

  Future<void> _pickFolder() async {
    if (!await _ensurePermission()) return;
    final path = await FolderAccess.pick();
    if (path == null) return;
    await LibraryStore.saveRoot(path);
    await _scan(path);
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
            tooltip: 'Choose folder',
            icon: const Icon(Icons.add, size: 30),
            onPressed: _loading ? null : _pickFolder,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'rescan':
                  if (_rootPath != null) _scan(_rootPath!);
                case 'log':
                  _copyLog();
              }
            },
            itemBuilder: (_) => [
              if (_rootPath != null)
                const PopupMenuItem(value: 'rescan', child: Text('Rescan')),
              const PopupMenuItem(value: 'log', child: Text('Copy debug log')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rootPath == null) {
      return _EmptyState(
        title: 'Add your music',
        message:
            'Pick a folder on your device. Every folder inside it with '
            'music becomes a playlist.',
        onPick: _pickFolder,
      );
    }
    if (_error != null) {
      return _EmptyState(
        title: "Can't open folder",
        message: _error!,
        onPick: _pickFolder,
      );
    }
    if (_playlists.isEmpty) {
      return _EmptyState(
        title: 'No music found',
        message: 'Nothing playable in "${p.basename(_rootPath!)}".',
        onPick: _pickFolder,
      );
    }
    return RefreshIndicator(
      onRefresh: () => _scan(_rootPath!),
      // Rebuilds tiles when playback moves to another playlist.
      child: StreamBuilder(
        stream: PlayerService.instance.player.sequenceStateStream,
        builder: (context, _) => ListView.builder(
          padding: EdgeInsets.only(
            top: 8,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
          ),
          itemCount: _playlists.length,
          itemBuilder: (context, index) => _PlaylistTile(
            playlist: _playlists[index],
            playing: PlayerService.instance.isCurrent(_playlists[index]),
          ),
        ),
      ),
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
    // Only nested folders need their path to tell them apart.
    final nested =
        playlist.relativePath != '.' && playlist.relativePath != playlist.name;
    final detail = nested
        ? playlist.relativePath
        : '$songs ${songs == 1 ? 'song' : 'songs'}';
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: playlist)),
      ),
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
                      const OfflineBadge(),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Playlist • $detail',
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
  final VoidCallback onPick;

  const _EmptyState({
    required this.title,
    required this.message,
    required this.onPick,
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
              onPressed: onPick,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
              ),
              child: const Text('Choose folder'),
            ),
          ],
        ),
      ),
    );
  }
}
