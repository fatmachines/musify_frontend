import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/musify_server.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/navigation.dart';
import 'playlist_screen.dart';

/// An artist from YouTube Music: all their songs, shown like a playlist
/// (play, shuffle, queue, download them all into a folder), with their
/// albums in a row above the songs.
class ArtistPage extends StatelessWidget {
  final YouTubeArtist artist;

  const ArtistPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    return _Loading<(Playlist, List<YouTubeAlbum>)>(
      title: artist.name,
      load: () => MusifyServer.instance.artist(artist),
      builder: (context, loaded) {
        final (songs, albums) = loaded;
        return PlaylistScreen(
          playlist: songs,
          beforeTracks: albums.isEmpty ? null : _Albums(albums: albums),
        );
      },
    );
  }
}

/// An album from YouTube Music, its songs shown like a playlist.
class AlbumPage extends StatelessWidget {
  final YouTubeAlbum album;

  const AlbumPage({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return _Loading<Playlist>(
      title: album.title,
      load: () => MusifyServer.instance.album(album),
      builder: (context, songs) => PlaylistScreen(playlist: songs),
    );
  }
}

/// "Albums", then a row of album covers that scrolls sideways.
class _Albums extends StatelessWidget {
  final List<YouTubeAlbum> albums;

  const _Albums({required this.albums});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Text(
            'Albums',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ),
        SizedBox(
          height: 214,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, i) => _AlbumCard(
              album: albums[i],
              onTap: () => openPage(context, AlbumPage(album: albums[i])),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'All songs',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final YouTubeAlbum album;
  final VoidCallback onTap;

  const _AlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 156,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ArtworkImage(
                url: album.thumbnail,
                size: 156,
                placeholder: Icons.album,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              [album.year, 'Album'].whereType<String>().join(' • '),
              maxLines: 1,
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// A spinner (or a retry) until [load] is done, then [builder]'s page.
class _Loading<T> extends StatefulWidget {
  final String title;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T loaded) builder;

  const _Loading({
    super.key,
    required this.title,
    required this.load,
    required this.builder,
  });

  @override
  State<_Loading<T>> createState() => _LoadingState<T>();
}

class _LoadingState<T> extends State<_Loading<T>> {
  late Future<T> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return widget.builder(context, snapshot.data as T);
        }
        return Scaffold(
          appBar: AppBar(title: Text(widget.title)),
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Couldn't load ${widget.title}",
                        style: TextStyle(color: AppColors.subtle),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () =>
                            setState(() => _future = widget.load()),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : CircularProgressIndicator(color: AppColors.green),
          ),
        );
      },
    );
  }
}
