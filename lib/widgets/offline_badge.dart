import 'package:flutter/material.dart';

import '../theme.dart';

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
