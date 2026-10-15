import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/local_copies.dart';
import '../services/musify_server.dart';
import '../theme.dart';
import 'navigation.dart';
import 'server_key_dialog.dart';
import 'toast.dart';

/// Asks for a YouTube, YouTube Music or Spotify playlist link and makes it
/// one of the user's playlists, then opens it. A Spotify playlist's songs
/// are found on YouTube Music. Songs on the device play from there; the
/// rest stream, and the whole playlist can be downloaded.
Future<void> importPlaylist(BuildContext context) async {
  // Read through the user's server.
  if (!await ensureServerKey(context) || !context.mounted) return;
  // A playlist link just copied goes in by itself.
  final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  if (!context.mounted) return;
  final link = TextEditingController(
    text: _isPlaylistLink(copied) ? copied.trim() : '',
  );
  final imported = await showDialog<(Playlist, List<String>)>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _ImportDialog(link: link),
  );
  link.dispose();
  if (imported == null || !context.mounted) return;
  final (remote, missing) = imported;

  final playlist = Library.instance.createPlaylist(
    remote.name,
    tracks: remote.tracks,
  );
  final here = remote.tracks
      .whereType<YouTubeTrack>()
      .where((t) => LocalCopies.instance.copyOf(t) != null)
      .length;
  final count = playlist.tracks.length;
  showToast(
    context,
    'Imported $count ${count == 1 ? 'song' : 'songs'}'
    '${here > 0 ? ', $here already on this device' : ''}'
    '${missing.isEmpty ? '' : '. Not on YouTube: ${missing.take(3).join('; ')}'
              '${missing.length > 3 ? ' and ${missing.length - 3} more' : ''}'}',
  );
  openPlaylist(context, playlist);
}

bool _isPlaylistLink(String text) =>
    MusifyServer.spotifyPlaylistIdOf(text) != null ||
    MusifyServer.playlistIdOf(text) != null;

class _ImportDialog extends StatefulWidget {
  final TextEditingController link;

  const _ImportDialog({required this.link});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  bool _reading = false;

  /// Finding a Spotify playlist's songs on YouTube takes a while: say so.
  bool _spotify = false;
  String? _error;

  Future<void> _import() async {
    final text = widget.link.text;
    final spotify = MusifyServer.spotifyPlaylistIdOf(text);
    final youtube = MusifyServer.playlistIdOf(text);
    if (spotify == null && youtube == null) {
      setState(() => _error = "That isn't a playlist link");
      return;
    }
    setState(() {
      _reading = true;
      _spotify = spotify != null;
      _error = null;
    });
    try {
      final server = MusifyServer.instance;
      final (playlist, missing) = spotify != null
          ? await server.spotifyPlaylist(spotify)
          : (await server.youtubePlaylist(youtube!), const <String>[]);
      if (!mounted) return;
      if (playlist.tracks.isEmpty) {
        setState(() {
          _reading = false;
          _error = 'No songs in it (is it public?)';
        });
        return;
      }
      Navigator.of(context).pop((playlist, missing));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = "Couldn't read it: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.elevated,
      title: const Text('Import playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paste the link to a public YouTube, YouTube Music or Spotify '
            'playlist. It becomes one of your playlists; songs already on '
            'this device play from there.',
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.link,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            cursorColor: AppColors.green,
            decoration: InputDecoration(
              hintText: 'A YouTube or Spotify playlist link',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _reading ? null : _import(),
          ),
          if (_reading && _spotify) ...[
            const SizedBox(height: 12),
            Text(
              'Finding its songs on YouTube Music: about half a minute for '
              '200 songs.',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _reading ? null : _import,
          child: _reading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Import'),
        ),
      ],
    );
  }
}
