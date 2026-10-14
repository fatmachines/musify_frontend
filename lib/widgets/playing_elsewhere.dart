import 'package:flutter/material.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// Spotify Connect's green strip: "Playing on iPhone", with "Play here" to
/// carry on on this device (the other one pauses). Nothing while no other
/// device is playing.
class PlayingElsewhereStrip extends StatelessWidget {
  final EdgeInsets margin;
  final BorderRadius radius;

  const PlayingElsewhereStrip({
    super.key,
    this.margin = EdgeInsets.zero,
    this.radius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ValueListenableBuilder<String?>(
      valueListenable: sync.playingElsewhere,
      builder: (context, name, _) {
        if (name == null) return const SizedBox.shrink();
        return Container(
          margin: margin,
          decoration: BoxDecoration(
            color: AppColors.green,
            borderRadius: radius,
          ),
          padding: const EdgeInsets.only(left: 12, right: 4),
          height: 34,
          child: Row(
            children: [
              const Icon(Icons.speaker_group, size: 18, color: Colors.black),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Playing on $name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: sync.playHere,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                    fontFamily: 'Figtree',
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                child: const Text('Play here'),
              ),
            ],
          ),
        );
      },
    );
  }
}
