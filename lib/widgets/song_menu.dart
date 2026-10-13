import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import 'add_to_playlist.dart';
import 'covers.dart';
import 'tag_sheet.dart';
import 'toast.dart';

/// A song's ••• menu. [onPlay] adds "Play"; [from] is the playlist the song
/// is listed in, which adds "Remove from this playlist" when it's one of
/// the user's.
Future<void> showSongMenu(
  BuildContext context,
  Track track, {
  VoidCallback? onPlay,
  Playlist? from,
}) {
  final library = Library.instance;
  final player = PlayerService.instance;
  final info = MetadataService.cachedInfo(track);
  final liked = library.isLiked(track);
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) {
      void then(VoidCallback action) {
        Navigator.of(sheet).pop();
        action();
      }

      return SafeArea(
        // Sized to its content, scrolling on screens too short for it.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: TrackCover(track: track, size: 48),
                title: Text(
                  info?.title ?? track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [info?.artist, info?.album].whereType<String>().join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(color: Colors.white12, height: 16),
              if (onPlay != null)
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('Play'),
                  onTap: () => then(onPlay),
                ),
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play next'),
                onTap: () => then(() {
                  player.playNext(track);
                  showToast(context, 'Playing next');
                }),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () => then(() {
                  player.addToQueue(track);
                  showToast(context, 'Added to queue');
                }),
              ),
              ListTile(
                leading: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  color: liked ? AppColors.green : null,
                ),
                title: Text(liked ? 'Remove from Liked Songs' : 'Like'),
                onTap: () => then(() => library.toggleLike(track)),
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Add to playlist'),
                onTap: () => then(() => showAddToPlaylist(context, track)),
              ),
              ListTile(
                leading: const Icon(Icons.sell_outlined),
                title: const Text('Tag'),
                onTap: () => then(() => showTagSheet(context, track)),
              ),
              if (from != null && from.isCustom)
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline),
                  title: const Text('Remove from this playlist'),
                  onTap: () => then(() {
                    library.removeTrack(from, track);
                    showToast(context, 'Removed from ${from.name}');
                  }),
                ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('File'),
                subtitle: Text(
                  '${track.title}.${track.extension.toLowerCase()}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
