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
/// Swipe right to queue it, left to toggle the first tag.
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

  /// Swiping left toggles the first tag; with no tags yet it opens the tag
  /// sheet to make one.
  void _quickTag(BuildContext context) {
    final library = Library.instance;
    final tag = library.tags.firstOrNull;
    if (tag == null) {
      showTagSheet(context, track);
      return;
    }
    final had = library.hasTag(track, tag);
    library.toggleTag(track, tag);
    showToast(context, had ? 'Removed ${tag.name}' : 'Tagged ${tag.name}');
  }

  @override
  Widget build(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    final firstTag = Library.instance.tags.firstOrNull;
    return SwipeActions(
      rightIcon: Icons.queue_music,
      onSwipeRight: () {
        PlayerService.instance.addToQueue(track);
        showToast(context, 'Added to queue');
      },
      leftIcon: Icons.sell_outlined,
      leftColor: firstTag?.color ?? AppColors.subtle,
      onSwipeLeft: () => _quickTag(context),
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
                          const Icon(
                            Icons.graphic_eq,
                            size: 14,
                            color: AppColors.green,
                          ),
                          const SizedBox(width: 4),
                        ],
                        TagDots(track: track),
                        const OfflineBadge(),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$subtitlePrefix${info?.artist ?? 'Unknown artist'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
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
                icon: const Icon(Icons.more_horiz, color: AppColors.subtle),
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
