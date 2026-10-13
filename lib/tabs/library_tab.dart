import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/playlist.dart';
import '../screens/playlist_screen.dart';
import '../services/library_scanner.dart';
import '../services/library_store.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  String? _rootPath;
  List<Playlist> _playlists = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final root = await LibraryStore.loadRoot();
    if (root == null || !await Directory(root).exists()) {
      setState(() => _loading = false);
      return;
    }
    await _scan(root);
  }

  Future<void> _scan(String root) async {
    setState(() {
      _rootPath = root;
      _loading = true;
    });
    final playlists = await LibraryScanner.scan(root);
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Musify needs access to your music files.'),
      action: permanentlyDenied
          ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
          : null,
    ));
    return false;
  }

  Future<void> _pickFolder() async {
    if (!await _ensurePermission()) return;
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose your music folder',
    );
    if (path == null) return;
    await LibraryStore.saveRoot(path);
    await _scan(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Library'),
        actions: [
          if (_rootPath != null)
            IconButton(
              tooltip: 'Rescan',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _scan(_rootPath!),
            ),
          IconButton(
            tooltip: 'Choose folder',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _loading ? null : _pickFolder,
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
        message: 'Pick a folder on your device. Every folder inside it with '
            'music becomes a playlist.',
        onPick: _pickFolder,
      );
    }
    if (_playlists.isEmpty) {
      return _EmptyState(
        message: 'No music found in $_rootPath',
        onPick: _pickFolder,
      );
    }
    return RefreshIndicator(
      onRefresh: () => _scan(_rootPath!),
      child: ListView.builder(
        itemCount: _playlists.length,
        itemBuilder: (context, index) {
          final playlist = _playlists[index];
          final songs = playlist.tracks.length;
          // Only nested folders need their path to tell them apart.
          final nested = playlist.relativePath != '.' &&
              playlist.relativePath != playlist.name;
          final location = nested ? ' • ${playlist.relativePath}' : '';
          return ListTile(
            leading: const _PlaylistArt(),
            title: Text(playlist.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '$songs ${songs == 1 ? 'song' : 'songs'}$location',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PlaylistScreen(playlist: playlist),
            )),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  final VoidCallback onPick;

  const _EmptyState({required this.message, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistArt extends StatelessWidget {
  const _PlaylistArt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(Icons.queue_music, color: scheme.onPrimaryContainer),
    );
  }
}
