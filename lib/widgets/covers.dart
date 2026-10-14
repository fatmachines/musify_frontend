import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';

/// Playlist artwork: a 2x2 grid of four different song covers, or a single
/// cover when the folder has fewer, or a placeholder when it has none.
class PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final double size;

  const PlaylistCover({super.key, required this.playlist, required this.size});

  @override
  Widget build(BuildContext context) {
    if (playlist.id == Library.likedId) return LikedCover(size: size);
    // An artist's picture is round, as everywhere on Spotify.
    if (playlist.id.startsWith('youtube:artist:')) {
      return ClipOval(
        child: ArtworkImage(url: playlist.artworkUrl, size: size),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<List<Uint8List>>(
        future: MetadataService.playlistCovers(playlist),
        initialData: MetadataService.loadedPlaylistCovers(playlist),
        builder: (context, snapshot) {
          final covers = snapshot.data ?? const [];
          if (covers.isEmpty) {
            return _Placeholder(icon: Icons.queue_music, size: size);
          }
          if (covers.length < 4) {
            return _CoverImage(bytes: covers.first, size: size);
          }
          final half = size / 2;
          return Column(
            children: [
              Row(
                children: [
                  _CoverImage(bytes: covers[0], size: half),
                  _CoverImage(bytes: covers[1], size: half),
                ],
              ),
              Row(
                children: [
                  _CoverImage(bytes: covers[2], size: half),
                  _CoverImage(bytes: covers[3], size: half),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A picture from the web (an artist's), square, with a placeholder until
/// it's in.
class ArtworkImage extends StatelessWidget {
  final String? url;
  final double size;

  const ArtworkImage({super.key, required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null) return _Placeholder(icon: Icons.person, size: size);
    return FutureBuilder<Uint8List?>(
      future: MetadataService.image(url),
      initialData: MetadataService.loadedImage(url),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return bytes == null
            ? _Placeholder(icon: Icons.person, size: size)
            : _CoverImage(bytes: bytes, size: size);
      },
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
        initialData: MetadataService.loadedCover(track),
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

/// Spotify's Liked Songs art: a white heart on a purple-to-mint gradient.
class LikedCover extends StatelessWidget {
  static const accent = Color(0xFF5038A0);

  final double size;

  const LikedCover({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF450AF5), Color(0xFF8E8EE5), Color(0xFFC4EFD9)],
        ),
      ),
      child: Icon(Icons.favorite, color: Colors.white, size: size * 0.42),
    );
  }
}
