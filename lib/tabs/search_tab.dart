import 'dart:math';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/playlist_screen.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/song_menu.dart';
import '../widgets/song_tile.dart';

/// Card colours for the Browse grid, Spotify-style.
const _cardColors = [
  Color(0xFFE13300),
  Color(0xFF1E3264),
  Color(0xFF8400E7),
  Color(0xFF27856A),
  Color(0xFFE8115B),
  Color(0xFF148A08),
  Color(0xFFBC5900),
  Color(0xFF509BF5),
  Color(0xFFAF2896),
  Color(0xFF503750),
];

/// Bumped to start a search (focus the field, show the keyboard), e.g. when
/// the Search tab is tapped while already open.
final searchFocusRequests = ValueNotifier<int>(0);

/// Finds songs (by title, artist, album or file name) and playlists across
/// every added folder. Before typing it shows the library as cards.
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _library = Library.instance;
  final _query = TextEditingController();
  final _focus = FocusNode();

  /// Keeps the same text field when the layout around it changes (the
  /// header goes away once searching). A rebuilt field would keep focus but
  /// drop the keyboard.
  final _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    _query.addListener(() => setState(() {}));
    _focus.addListener(() => setState(() {}));
    _library.ensureLoaded().then((_) => _onLibraryChanged());
    searchFocusRequests.addListener(_focus.requestFocus);
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    searchFocusRequests.removeListener(_focus.requestFocus);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Tags are read for every song so artists and albums can be searched.
  void _onLibraryChanged() {
    if (!mounted) return;
    setState(() {});
    MetadataService.loadInfo(_library.allSongs).then((_) {
      if (mounted) setState(() {});
    });
  }

  bool get _active => _focus.hasFocus || _query.text.isNotEmpty;

  void _cancel() {
    _query.clear();
    _focus.unfocus();
  }

  /// Plays the song within its folder, so next and previous carry on there.
  void _play(Track track) {
    final home = _library.all
        .where((p) => !p.isCustom && p.tracks.any((t) => t.path == track.path))
        .firstOrNull;
    if (home == null) return;
    final player = PlayerService.instance;
    player.play(
      home,
      shuffle: player.shuffleOn.value,
      startIndex: home.tracks.indexWhere((t) => t.path == track.path),
    );
  }

  void _open(Playlist playlist) {
    _focus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: playlist)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!_active)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: AppColors.green,
                      child: Icon(
                        Icons.music_note,
                        size: 18,
                        color: Colors.black,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Search',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            _buildField(),
            Expanded(child: _active ? _buildResults() : _buildBrowse()),
          ],
        ),
      ),
    );
  }

  Widget _buildField() {
    final active = _active;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, active ? 8 : 0, active ? 4 : 16, 8),
      child: Row(
        children: [
          Expanded(
            // The whole bar opens the keyboard, not just the text line.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _focus.requestFocus,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: active ? AppColors.chip : AppColors.text,
                  borderRadius: BorderRadius.circular(active ? 23 : 6),
                ),
                child: Row(
                  children: [
                    if (!active) ...[
                      const Icon(Icons.search, color: Colors.black, size: 28),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: TextField(
                        key: _fieldKey,
                        controller: _query,
                        focusNode: _focus,
                        cursorColor: AppColors.green,
                        textInputAction: TextInputAction.search,
                        // Matches update as you type; no suggestions list.
                        autocorrect: false,
                        enableSuggestions: false,
                        style: TextStyle(
                          color: active ? AppColors.text : Colors.black,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: active
                              ? 'Songs, artists, playlists'
                              : 'What do you want to listen to?',
                          hintStyle: TextStyle(
                            color: active ? AppColors.subtle : Colors.black87,
                            fontSize: 16,
                            fontWeight: active
                                ? FontWeight.w400
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (_query.text.isNotEmpty)
                      GestureDetector(
                        onTap: _query.clear,
                        child: const Icon(
                          Icons.cancel,
                          color: AppColors.subtle,
                          size: 22,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (active)
            TextButton(
              onPressed: _cancel,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.text,
                textStyle: const TextStyle(
                  fontFamily: 'Figtree',
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }

  // Results -----------------------------------------------------------------------

  List<String> get _words => _query.text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  List<Playlist> _matchingPlaylists(List<String> words) => [
    for (final playlist in _library.all)
      if (words.every(playlist.name.toLowerCase().contains)) playlist,
  ];

  /// Songs where every word appears in the title, artist, album or file
  /// name; titles starting with the search come first.
  List<Track> _matchingSongs(List<String> words) {
    final phrase = words.join(' ');
    final scored = <(int, String, Track)>[];
    for (final track in _library.allSongs) {
      final info = MetadataService.cachedInfo(track);
      final title = (info?.title ?? track.title).toLowerCase();
      final haystack = [
        title,
        track.title.toLowerCase(),
        info?.artist?.toLowerCase(),
        info?.album?.toLowerCase(),
      ].whereType<String>().join(' ');
      if (!words.every(haystack.contains)) continue;
      final rank = title.startsWith(phrase)
          ? 0
          : title.contains(phrase)
          ? 1
          : 2;
      scored.add((rank, title, track));
    }
    scored.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2.compareTo(b.$2));
    return [for (final s in scored) s.$3];
  }

  Widget _buildResults() {
    final words = _words;
    if (words.isEmpty) {
      return const _Hint(
        title: 'Search your music',
        message: 'Find songs by title, artist or album in all your folders.',
      );
    }
    final playlists = _matchingPlaylists(words);
    final songs = _matchingSongs(words);
    if (playlists.isEmpty && songs.isEmpty) {
      return _Hint(
        title: "Couldn't find \"${_query.text.trim()}\"",
        message: 'Try different words, or check the spelling.',
      );
    }
    final player = PlayerService.instance;
    return StreamBuilder(
      // Rebuilds rows when the playing song changes.
      stream: player.player.sequenceStateStream,
      builder: (context, _) => ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        itemCount: playlists.length + songs.length,
        itemBuilder: (context, i) {
          if (i < playlists.length) {
            return _PlaylistRow(
              playlist: playlists[i],
              onTap: () => _open(playlists[i]),
            );
          }
          final track = songs[i - playlists.length];
          final current = player.currentTrack?.path == track.path;
          return SongTile(
            track: track,
            subtitlePrefix: 'Song • ',
            current: current,
            playing: current && player.player.playing,
            onTap: () => _play(track),
            onMore: () =>
                showSongMenu(context, track, onPlay: () => _play(track)),
            trailing: _LikeToggle(track: track),
          );
        },
      ),
    );
  }

  // Browse ------------------------------------------------------------------------

  Widget _buildBrowse() {
    final tags = [
      for (final tag in _library.tags)
        (playlist: _library.tagPlaylist(tag), color: tag.color),
    ];
    final playlists = _library.all;
    if (playlists.isEmpty && tags.isEmpty) {
      return const _Hint(
        title: 'Nothing to search yet',
        message: 'Add a music folder in Your Library.',
      );
    }
    return CustomScrollView(
      slivers: [
        if (tags.any((t) => t.playlist.tracks.isNotEmpty)) ...[
          const _SectionTitle('Your tags'),
          _grid([
            for (final t in tags)
              if (t.playlist.tracks.isNotEmpty)
                _BrowseCard(
                  playlist: t.playlist,
                  color: Color.lerp(t.color, Colors.black, 0.25)!,
                  onTap: () => _open(t.playlist),
                ),
          ]),
        ],
        const _SectionTitle('Browse your library'),
        _grid([
          for (var i = 0; i < playlists.length; i++)
            _BrowseCard(
              playlist: playlists[i],
              color: _cardColors[i % _cardColors.length],
              onTap: () => _open(playlists[i]),
            ),
        ]),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
        ),
      ],
    );
  }

  Widget _grid(List<Widget> cards) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverGrid.count(
      crossAxisCount: 2,
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      childAspectRatio: 1.75,
      children: cards,
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Text(
          text,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// A coloured card with the name top-left and the cover tilted into the
/// bottom-right corner.
class _BrowseCard extends StatelessWidget {
  final Playlist playlist;
  final Color color;
  final VoidCallback onTap;

  const _BrowseCard({
    required this.playlist,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              right: -14,
              bottom: -6,
              child: Transform.rotate(
                angle: pi / 7,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    boxShadow: [
                      BoxShadow(color: Colors.black38, blurRadius: 8),
                    ],
                  ),
                  child: PlaylistCover(playlist: playlist, size: 66),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 56, 10),
              child: Text(
                playlist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;

  const _PlaylistRow({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final songs = playlist.tracks.length;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            PlaylistCover(playlist: playlist, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Playlist • $songs ${songs == 1 ? 'song' : 'songs'}',
                    style: const TextStyle(
                      color: AppColors.subtle,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Spotify's add-to-Liked button: a plus, or a green tick once liked.
class _LikeToggle extends StatelessWidget {
  final Track track;

  const _LikeToggle({required this.track});

  @override
  Widget build(BuildContext context) {
    final liked = Library.instance.isLiked(track);
    return IconButton(
      tooltip: liked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
      onPressed: () => Library.instance.toggleLike(track),
      icon: Icon(
        liked ? Icons.check_circle : Icons.add_circle_outline,
        color: liked ? AppColors.green : AppColors.subtle,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String title;
  final String message;

  const _Hint({required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 0),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
