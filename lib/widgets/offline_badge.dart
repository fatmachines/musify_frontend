import 'package:flutter/material.dart';

import '../theme.dart';

/// Marks a song that plays from YouTube rather than from the device.
class YouTubeBadge extends StatelessWidget {
  final double size;

  const YouTubeBadge({super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size * 1.4,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFF0033),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        size: size * 0.9,
        color: Colors.white,
      ),
    );
  }
}

/// Spotify's green "downloaded" mark. Everything in Musify is on the device,
/// so it marks every song and playlist.
class OfflineBadge extends StatelessWidget {
  final double size;

  const OfflineBadge({super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
      child: Icon(
        Icons.arrow_downward_rounded,
        size: size * 0.72,
        color: Colors.black,
      ),
    );
  }
}
