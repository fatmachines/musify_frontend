import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import 'covers.dart';
import 'track_swiper.dart';

const _fallbackColor = Color(0xFF3E3E3E);

/// The floating "now playing" card above the tab bar. Tapping it, or
/// dragging it up, opens the full player.
class MiniPlayer extends StatelessWidget {
  final VoidCallback onOpen;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;

  const MiniPlayer({
    super.key,
    required this.onOpen,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return StreamBuilder<Track?>(
      stream: service.trackStream,
      initialData: service.currentTrack,
      builder: (context, snapshot) {
        final track = snapshot.data;
        if (track == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: onOpen,
          onVerticalDragUpdate: onDragUpdate,
          onVerticalDragEnd: onDragEnd,
          child: FutureBuilder<Color?>(
            future: trackColor(track),
            builder: (context, color) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              height: 60,
              decoration: BoxDecoration(
                color: Color.lerp(
                  color.data ?? _fallbackColor,
                  Colors.black,
                  0.3,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 4, 10),
                    child: Row(
                      children: [
                        // Swipe sideways for the previous or next song.
                        Expanded(
                          child: TrackSwiper(
                            itemBuilder: (context, track) => Row(
                              children: [
                                TrackCover(track: track, size: 40),
                                const SizedBox(width: 10),
                                Expanded(child: _TrackText(track: track)),
                              ],
                            ),
                          ),
                        ),
                        const _PlayPause(),
                      ],
                    ),
                  ),
                  const Positioned(
                    left: 8,
                    right: 8,
                    bottom: 2,
                    child: _Progress(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackText extends StatelessWidget {
  final Track track;

  const _TrackText({required this.track});

  @override
  Widget build(BuildContext context) {
    // Usually cached by the playlist screen already; this covers songs
    // whose tags haven't been read yet.
    return FutureBuilder(
      future: MetadataService.loadInfo([track]),
      builder: (context, _) {
        final info = MetadataService.cachedInfo(track);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info?.title ?? track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              info?.artist ?? 'Unknown artist',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ],
        );
      },
    );
  }
}

class _PlayPause extends StatelessWidget {
  const _PlayPause();

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return StreamBuilder<bool>(
      stream: service.player.playingStream,
      initialData: service.player.playing,
      builder: (context, snapshot) {
        final playing = snapshot.data ?? false;
        return IconButton(
          tooltip: playing ? 'Pause' : 'Play',
          iconSize: 32,
          color: AppColors.text,
          onPressed: service.togglePlayback,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress();

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final total = player.duration?.inMilliseconds ?? 0;
        final position = snapshot.data?.inMilliseconds ?? 0;
        final fraction = total == 0 ? 0.0 : (position / total).clamp(0.0, 1.0);
        return ClipRRect(
          borderRadius: BorderRadius.circular(1),
          child: SizedBox(
            height: 2,
            child: Stack(
              children: [
                Container(color: Colors.white24),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(color: AppColors.text),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
