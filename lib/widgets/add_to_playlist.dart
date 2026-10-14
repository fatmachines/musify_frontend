import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/name_playlist_screen.dart';
import '../services/library.dart';
import '../theme.dart';
import 'covers.dart';
import 'toast.dart';

/// Lets the user put [track] in Liked Songs, one of their playlists, or a
/// new one.
Future<void> showAddToPlaylist(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: ListenableBuilder(
        listenable: Library.instance,
        builder: (sheet, _) {
          final library = Library.instance;
          final playlists = library.custom;
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Add to playlist',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Center(
                child: FilledButton(
                  onPressed: () async {
                    final name = await askPlaylistName(
                      context,
                      initial: 'My playlist #${playlists.length + 1}',
                    );
                    if (name == null || !sheet.mounted) return;
                    final playlist = library.createPlaylist(name);
                    library.addTrack(playlist, track);
                    Navigator.of(sheet).pop();
                    if (context.mounted) showToast(context, 'Added to $name');
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('New playlist'),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const LikedCover(size: 48),
                title: const Text('Liked Songs'),
                subtitle: Text(_songs(library.liked.tracks.length)),
                trailing: library.isLiked(track)
                    ? Icon(Icons.check_circle, color: AppColors.green)
                    : const Icon(Icons.add_circle_outline),
                onTap: () {
                  final already = library.isLiked(track);
                  if (!already) library.toggleLike(track);
                  Navigator.of(sheet).pop();
                  showToast(
                    context,
                    already ? 'Already in Liked Songs' : 'Added to Liked Songs',
                  );
                },
              ),
              if (playlists.isEmpty)
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'You have no playlists yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.subtle),
                  ),
                ),
              for (final playlist in playlists)
                ListTile(
                  leading: PlaylistCover(playlist: playlist, size: 48),
                  title: Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_songs(playlist.tracks.length)),
                  trailing: library.contains(playlist, track)
                      ? Icon(Icons.check_circle, color: AppColors.green)
                      : const Icon(Icons.add_circle_outline),
                  onTap: () {
                    final already = library.contains(playlist, track);
                    if (!already) library.addTrack(playlist, track);
                    Navigator.of(sheet).pop();
                    showToast(
                      context,
                      already
                          ? 'Already in ${playlist.name}'
                          : 'Added to ${playlist.name}',
                    );
                  },
                ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    ),
  );
}

String _songs(int n) => '$n ${n == 1 ? 'song' : 'songs'}';
