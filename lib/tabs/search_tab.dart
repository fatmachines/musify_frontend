import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../services/library.dart';
import '../services/library_search.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../services/youtube/youtube_media.dart';
import '../services/musify_server.dart';
import '../services/app_log.dart';
import '../screens/artist_page.dart';
import '../theme.dart';
import '../widgets/list_scrollbar.dart';
import '../widgets/navigation.dart';
import '../widgets/add_to_playlist.dart';
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
/// every added folder, then songs on YouTube. Before typing it shows the
/// library as cards.
class SearchTab extends StatefulWidget {
  /// The search field's text and focus when the field is elsewhere (the
  /// desktop layout's top bar): the page then shows only the results.
  final TextEditingController? query;
  final FocusNode? focus;

  const SearchTab({super.key, this.query, this.focus});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _library = Library.instance;
  late final _query = widget.query ?? TextEditingController();
  late final _focus = widget.focus ?? FocusNode();

  /// The field is in the top bar, not on this page.
  bool get _fieldElsewhere => widget.query != null;

  /// Keeps the same text field when the layout around it changes (the
  /// header goes away once searching). A rebuilt field would keep focus but
  /// drop the keyboard.
  final _fieldKey = GlobalKey();

  final _resultsScroll = ScrollController();

  /// YouTube results, fetched once typing pauses.
  Timer? _youtubeSoon;
  String _youtubeQuery = '';
  List<YouTubeTrack>? _youtube;
  bool _youtubeFailed = false;

  /// The artist the search names, from YouTube Music: shown on top.
  YouTubeArtist? _artist;

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    _query.addListener(_onQueryChanged);
    _focus.addListener(_onFocusChanged);
    _library.ensureLoaded().then((_) => _onLibraryChanged());
    searchFocusRequests.addListener(_focus.requestFocus);
    // Already typed in the top bar before this page opened.
    if (_query.text.isNotEmpty) _searchYouTubeSoon();
  }

  void _onQueryChanged() {
    setState(() {});
    _searchYouTubeSoon();
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    _query.removeListener(_onQueryChanged);
    _focus.removeListener(_onFocusChanged);
    searchFocusRequests.removeListener(_focus.requestFocus);
    _youtubeSoon?.cancel();
    _resultsScroll.dispose();
    if (!_fieldElsewhere) {
      _query.dispose();
      _focus.dispose();
    }
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

  void _searchYouTubeSoon() {
    final query = LibrarySearch.words(_query.text).join(' ');
    if (query == _youtubeQuery) return;
    _youtubeSoon?.cancel();
    _youtubeQuery = query;
    _youtube = null;
    _youtubeFailed = false;
    _artist = null;
    if (query.isEmpty) return;
    _youtubeSoon = Timer(const Duration(milliseconds: 500), () async {
      try {
        // YouTube Music through the server (songs only, and artists), else
        // plain YouTube from the phone.
        YouTubeArtist? artist;
        List<YouTubeTrack>? results;
        final server = MusifyServer.instance;
        if (await server.isSetUp()) {
          try {
            (artist, results) = await server.search(query);
          } catch (e) {
            AppLog.add('search: server failed, using YouTube: $e');
          }
        }
        results ??= await YouTubeMedia.instance.search(query);
        if (!mounted || query != _youtubeQuery) return;
        setState(() {
          _youtube = results;
          _artist = artist;
        });
      } catch (e) {
        if (!mounted || query != _youtubeQuery) return;
        setState(() => _youtubeFailed = true);
      }
    });
  }

  bool get _active => _focus.hasFocus || _query.text.isNotEmpty;

  void _cancel() {
    _query.clear();
    _focus.unfocus();
  }

  void _play(Track track) => PlayerService.instance.playSong(track);

  void _open(Playlist playlist) {
    _focus.unfocus();
    openPlaylist(context, playlist);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!_active && !_fieldElsewhere)
              Padding(
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
            if (_fieldElsewhere) const SizedBox(height: 8) else _buildField(),
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
                      Icon(Icons.search, color: AppColors.onText, size: 28),
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
                          color: active ? AppColors.text : AppColors.onText,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: active
                              ? 'Songs, artists, playlists'
                              : 'What do you want to listen to?',
                          hintStyle: TextStyle(
                            color: active
                                ? AppColors.subtle
                                : AppColors.onText.withValues(alpha: 0.87),
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
                        child: Icon(
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

  Widget _buildResults() {
    if (LibrarySearch.words(_query.text).isEmpty) {
      return const _Hint(
        title: 'Search your music',
        message: 'Find songs by title, artist or album in your folders and on YouTube.',
      );
    }
    final playlists = LibrarySearch.playlists(_query.text);
    final songs = LibrarySearch.songs(_query.text);
    final youtube = _youtube;
    final searching = youtube == null && !_youtubeFailed;
    if (playlists.isEmpty &&
        songs.isEmpty &&
        !searching &&
        (youtube?.isEmpty ?? true)) {
      return _Hint(
        title: "Couldn't find \"${_query.text.trim()}\"",
        message: _youtubeFailed
            ? "Try different words. YouTube couldn't be reached."
            : 'Try different words, or check the spelling.',
      );
    }
    final local = playlists.length + songs.length;
    final artist = _artist;
    // The artist first, big; then your music, then YouTube's songs.
    final top = artist == null ? 0 : 1;
    final player = PlayerService.instance;
    return StreamBuilder(
      // Rebuilds rows when the playing song changes.
      stream: player.player.sequenceStateStream,
      builder: (context, _) => ListScrollbar(
        controller: _resultsScroll,
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: ListView.builder(
          controller: _resultsScroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
          // Your music, then a "YouTube" heading and what YouTube found.
          itemCount: top + local + 1 + (youtube?.length ?? 0),
          itemBuilder: (context, row) {
            if (artist != null && row == 0) {
              return _ArtistCard(
                artist: artist,
                onTap: () {
                  _focus.unfocus();
                  openPage(context, ArtistPage(artist: artist));
                },
              );
            }
            final i = row - top;
            if (i == local) {
              return _YouTubeHeading(
                searching: searching,
                failed: _youtubeFailed,
                empty: youtube?.isEmpty ?? false,
              );
            }
            if (i > local) {
              final index = i - local - 1;
              final track = youtube![index];
              final current = player.currentTrack?.path == track.path;
              void play() => player.playYouTube(youtube, index);
              return SongTile(
                track: track,
                subtitlePrefix: 'Song • ',
                current: current,
                playing: current && player.player.playing,
                onTap: play,
                onMore: () => showSongMenu(context, track, onPlay: play),
                trailing: _AddButton(track: track),
              );
            }
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
    // Two to a row on a phone; on a wide window as many as fit, so the
    // cards keep their size.
    sliver: SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1.75,
      ),
      delegate: SliverChildListDelegate(cards),
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
                // White on the card, light theme or dark.
                style: const TextStyle(
                  color: Colors.white,
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
                    style: TextStyle(color: AppColors.subtle, fontSize: 14),
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

/// A YouTube result's +: choose Liked Songs or a playlist to save it in.
/// A green tick once it's in one.
class _AddButton extends StatelessWidget {
  final Track track;

  const _AddButton({required this.track});

  @override
  Widget build(BuildContext context) {
    final library = Library.instance;
    final saved =
        library.isLiked(track) ||
        library.custom.any((p) => library.contains(p, track));
    return IconButton(
      tooltip: 'Add to playlist',
      onPressed: () => showAddToPlaylist(context, track),
      icon: Icon(
        saved ? Icons.check_circle : Icons.add_circle_outline,
        color: saved ? AppColors.green : AppColors.subtle,
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

/// Spotify's top result for an artist: their picture in a big circle, the
/// name in large type and "Artist".
class _ArtistCard extends StatelessWidget {
  final YouTubeArtist artist;
  final VoidCallback onTap;

  const _ArtistCard({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                ClipOval(child: ArtworkImage(url: artist.thumbnail, size: 104)),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.faint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Artist',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: AppColors.subtle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _YouTubeHeading extends StatelessWidget {
  final bool searching;
  final bool failed;
  final bool empty;

  const _YouTubeHeading({
    required this.searching,
    required this.failed,
    required this.empty,
  });

  @override
  Widget build(BuildContext context) {
    final note = failed
        ? "Couldn't reach YouTube"
        : empty
        ? 'Nothing found'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          const Text(
            'YouTube',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          if (searching)
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.subtle,
              ),
            )
          else if (note != null)
            Text(note, style: TextStyle(color: AppColors.subtle, fontSize: 14)),
        ],
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
    // Centred across the page however wide it is.
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
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
              style: TextStyle(color: AppColors.subtle, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
