import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/playlist_screen.dart';
import '../services/library.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/playlist_actions.dart';

/// Spotify's home: a greeting, then the playlists and folders pinned here
/// as tiles, two to a row, one tap away.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _library = Library.instance;

  @override
  void initState() {
    super.initState();
    _library.ensureLoaded();
  }

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5 || hour >= 18) return 'Good evening';
    if (hour < 12) return 'Good morning';
    return 'Good afternoon';
  }

  void _open(Playlist playlist) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: playlist)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _library,
          builder: (context, _) {
            final pinned = _library.pinned;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Row(
                      children: [
                        const CircleAvatar(
                          radius: 16,
                          backgroundColor: AppColors.green,
                          child: Icon(
                            Icons.music_note,
                            size: 18,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _greeting(),
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (pinned.isEmpty)
                  const SliverToBoxAdapter(child: _PinHint())
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: StreamBuilder(
                      // The playing playlist's tile shows an equaliser.
                      stream: PlayerService.instance.player.playingStream,
                      builder: (context, _) => SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              mainAxisExtent: 56,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          childCount: pinned.length,
                          (context, i) => _PinTile(
                            playlist: pinned[i],
                            onTap: () => _open(pinned[i]),
                            onLongPress: () =>
                                showPlaylistActions(context, pinned[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.paddingOf(context).bottom + 16,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A pinned playlist: cover on the left, name beside it.
class _PinTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PinTile({
    required this.playlist,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance;
    final playing = player.isCurrent(playlist) && player.player.playing;
    return Material(
      color: AppColors.chip,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Row(
          children: [
            PlaylistCover(playlist: playlist, size: 56),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                playlist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (playing)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.graphic_eq, size: 16, color: AppColors.green),
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _PinHint extends StatelessWidget {
  const _PinHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.push_pin_outlined, color: AppColors.green),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Pin playlists and folders here: tap ••• on a playlist, or '
              'long-press it in Your Library, and choose Pin to Home.',
              style: TextStyle(color: AppColors.subtle, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
