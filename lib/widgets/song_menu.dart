import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import 'add_to_playlist.dart';
import 'covers.dart';
import 'download_sheet.dart';
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
  // YouTube songs can be liked and put in playlists, but not tagged.
  final youtube = track is YouTubeTrack;
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
                  [
                    if (youtube) 'YouTube',
                    info?.artist,
                    info?.album,
                  ].whereType<String>().join(' • '),
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
              if (!youtube)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: const Text('Tag'),
                  onTap: () => then(() => showTagSheet(context, track)),
                ),
              if (track is YouTubeTrack)
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Download'),
                  subtitle: const Text('Save to a folder on this phone'),
                  onTap: () => then(() => downloadWithPicker(context, track)),
                ),
              if (from != null && from.isCustom && !Library.isRemote(from))
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline),
                  title: const Text('Remove from this playlist'),
                  onTap: () => then(() {
                    library.removeTrack(from, track);
                    showToast(context, 'Removed from ${from.name}');
                  }),
                ),
              // On the device: delete the file. A YouTube song has none, so
              // it can only leave a playlist (above).
              if (!youtube)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Color(0xFFF15E6C),
                  ),
                  title: const Text(
                    'Delete from device',
                    style: TextStyle(color: Color(0xFFF15E6C)),
                  ),
                  onTap: () => then(() => _confirmDelete(context, track)),
                ),
              if (!youtube)
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

Future<void> _confirmDelete(BuildContext context, Track track) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final name = MetadataService.cachedInfo(track)?.title ?? track.title;
  final delete = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text('Delete "$name"?'),
      content: const Text(
        'The file is deleted from this phone, and the song leaves every '
        'playlist. This can\'t be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFF15E6C)),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (delete != true) return;
  final deleted = await Library.instance.deleteSong(track);
  showToastOn(overlay, deleted ? 'Deleted $name' : "Couldn't delete $name");
}
