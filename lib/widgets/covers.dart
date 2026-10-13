import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/metadata_service.dart';

/// Playlist artwork: a 2x2 grid of four different song covers, or a single
/// cover when the folder has fewer, or a placeholder when it has none.
class PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final double size;

  const PlaylistCover({super.key, required this.playlist, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<List<Uint8List>>(
        future: MetadataService.playlistCovers(playlist),
        builder: (context, snapshot) {
          final covers = snapshot.data ?? const [];
          if (covers.isEmpty) {
            return _Placeholder(icon: Icons.queue_music, size: size);
          }
          if (covers.length < 4) {
            return _CoverImage(bytes: covers.first, size: size);
          }
          final half = size / 2;
          return Column(children: [
            Row(children: [
              _CoverImage(bytes: covers[0], size: half),
              _CoverImage(bytes: covers[1], size: half),
            ]),
            Row(children: [
              _CoverImage(bytes: covers[2], size: half),
              _CoverImage(bytes: covers[3], size: half),
            ]),
          ]);
        },
      ),
    );
  }
}

class TrackCover extends StatelessWidget {
  final Track track;
  final double size;

  const TrackCover({super.key, required this.track, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: FutureBuilder<Uint8List?>(
        future: MetadataService.cover(track),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return bytes == null
              ? _Placeholder(icon: Icons.music_note, size: size)
              : _CoverImage(bytes: bytes, size: size);
        },
      ),
    );
  }
}

class _CoverImage extends StatelessWidget {
  final Uint8List bytes;
  final double size;

  const _CoverImage({required this.bytes, required this.size});

  @override
  Widget build(BuildContext context) {
    // Embedded covers can be several megapixels; decode at display size.
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return Image.memory(
      bytes,
      width: size,
      height: size,
      cacheWidth: px,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) =>
          _Placeholder(icon: Icons.music_note, size: size),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final double size;

  const _Placeholder({required this.icon, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF282828),
      child: Icon(icon, size: size * 0.45, color: const Color(0xFFB3B3B3)),
    );
  }
}
