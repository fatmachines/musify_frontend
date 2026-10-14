import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/musify_server.dart';
import '../theme.dart';
import 'playlist_screen.dart';

/// An artist from YouTube Music with all their songs: loads them from the
/// Musify server, then shows them like a playlist (play, shuffle, queue,
/// download them all into a folder).
class ArtistPage extends StatefulWidget {
  final YouTubeArtist artist;

  const ArtistPage({super.key, required this.artist});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  late Future<Playlist> _songs = MusifyServer.instance.artist(widget.artist);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Playlist>(
      future: _songs,
      builder: (context, snapshot) {
        final playlist = snapshot.data;
        if (playlist != null) return PlaylistScreen(playlist: playlist);
        return Scaffold(
          appBar: AppBar(title: Text(widget.artist.name)),
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Couldn't load ${widget.artist.name}'s songs",
                        style: const TextStyle(color: AppColors.subtle),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => setState(
                          () => _songs = MusifyServer.instance.artist(
                            widget.artist,
                          ),
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(color: AppColors.green),
          ),
        );
      },
    );
  }
}
