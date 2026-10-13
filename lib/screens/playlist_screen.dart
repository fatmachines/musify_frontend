import 'package:flutter/material.dart';

import '../models/playlist.dart';

class PlaylistScreen extends StatelessWidget {
  final Playlist playlist;

  const PlaylistScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final tracks = playlist.tracks;
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: ListView.builder(
        itemCount: tracks.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            );
          }
          final track = tracks[index - 1];
          return ListTile(
            leading: const _TrackArt(),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.extension),
          );
        },
      ),
    );
  }
}

class _TrackArt extends StatelessWidget {
  const _TrackArt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
    );
  }
}
