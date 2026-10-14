import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import 'covers.dart';
import 'offline_badge.dart';
import 'swipe_actions.dart';
import 'tag_sheet.dart';
import 'toast.dart';

/// A song row: cover, title, tag dots and artist, and a ••• button.
/// Swipe right to queue it; left to tag it (the tag sheet), or, if tagged,
/// to take its tags off.
class SongTile extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final VoidCallback onMore;

  /// The song is the one loaded in the player: its title turns green.
  final bool current;

  /// ...and it's playing: an equaliser shows next to the artist.
  final bool playing;

  /// Before the artist, e.g. "Song • ".
  final String subtitlePrefix;

  /// After the ••• button.
  final Widget? trailing;

  const SongTile({
    super.key,
    required this.track,
    required this.onTap,
    required this.onMore,
    this.current = false,
    this.playing = false,
    this.subtitlePrefix = '',
    this.trailing,
  });

  /// Swiping left on a song without tags opens the tag sheet to pick one;
  /// on a tagged song it takes its tags off.
  void _swipeTag(BuildContext context) {
    final library = Library.instance;
    final tags = library.tagsOf(track);
    if (tags.isEmpty) {
      showTagSheet(context, track);
      return;
    }
    for (final tag in tags) {
      library.toggleTag(track, tag);
    }
    showToast(
      context,
      tags.length == 1
          ? 'Removed ${tags.single.name}'
          : 'Removed ${tags.length} tags',
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    final youtube = track is YouTubeTrack;
    // Tagged: swiping takes the tags off; else it opens the tag sheet.
    final tagged = Library.instance.tagsOf(track);
    return SwipeActions(
      rightIcon: Icons.queue_music,
      onSwipeRight: () {
        PlayerService.instance.addToQueue(track);
        showToast(context, 'Added to queue');
      },
      leftIcon: tagged.isEmpty ? Icons.sell_outlined : Icons.label_off_outlined,
      leftColor: tagged.isEmpty ? AppColors.green : tagged.first.color,
      // YouTube songs aren't in the library, so they can't be tagged.
      onSwipeLeft: youtube ? null : () => _swipeTag(context),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              TrackCover(track: track, size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info?.title ?? track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: current ? AppColors.green : AppColors.text,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (current && playing) ...[
                          Icon(
                            Icons.graphic_eq,
                            size: 14,
                            color: AppColors.green,
                          ),
                          const SizedBox(width: 4),
                        ],
                        if (youtube)
                          const YouTubeBadge()
                        else ...[
                          TagDots(track: track),
                          const OfflineBadge(),
                        ],
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$subtitlePrefix${info?.artist ?? 'Unknown artist'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.subtle,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'More',
                icon: Icon(Icons.more_horiz, color: AppColors.subtle),
                onPressed: onMore,
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
