import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../screens/playlist_screen.dart';
import '../services/library.dart';
import '../services/musify_server.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../widgets/covers.dart';
import '../widgets/playlist_actions.dart';
import '../widgets/server_key_dialog.dart';

/// Spotify's home: a greeting, the playlists and folders pinned here as
/// tiles (two to a row, one tap away), then YouTube Music's charts as a
/// grid, from Musify's server.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final _library = Library.instance;
  final _server = MusifyServer.instance;

  List<Playlist>? _charts;
  String? _chartsError;

  /// Null until it's known whether there's a server key.
  bool? _needsKey;

  @override
  void initState() {
    super.initState();
    _library.ensureLoaded();
    _charts = _server.cachedCharts;
    _server.addListener(_loadCharts);
    _loadCharts();
  }

  @override
  void dispose() {
    _server.removeListener(_loadCharts);
    super.dispose();
  }

  Future<void> _loadCharts({bool refresh = false}) async {
    var setUp = false;
    try {
      setUp = await _server.isSetUp();
    } catch (_) {}
    if (!setUp) {
      if (mounted) setState(() => _needsKey = true);
      return;
    }
    if (mounted) {
      setState(() {
        _needsKey = false;
        _chartsError = null;
      });
    }
    try {
      final charts = await _server.charts(refresh: refresh);
      if (mounted) setState(() => _charts = charts);
    } catch (e) {
      if (mounted) setState(() => _chartsError = '$e');
    }
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
                ..._buildCharts(),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.paddingOf(context).bottom + 96,
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

/// Card colours for the charts, Spotify-style.
const _chartColors = [
  Color(0xFF1E3264),
  Color(0xFFE8115B),
  Color(0xFF8D67AB),
  Color(0xFF148A08),
  Color(0xFFBC5900),
  Color(0xFF509BF5),
];

/// "Top 100 Songs United Kingdom" -> "United Kingdom".
String _region(Playlist chart) =>
    chart.name.replaceFirst(RegExp(r'^Top 100 (Songs )?'), '');

extension on _HomeTabState {
  List<Widget> _buildCharts() {
    final charts = _charts;
    if (_needsKey == null) return const [];
    if (_needsKey!) {
      return [
        const _SectionTitle('Charts'),
        SliverToBoxAdapter(
          child: _Notice(
            icon: Icons.cloud_outlined,
            text:
                'Connect to the Musify server for YouTube charts and '
                'downloads.',
            action: 'Connect',
            onAction: () async {
              if (await showServerKeyDialog(context)) _loadCharts();
            },
          ),
        ),
      ];
    }
    if (charts == null) {
      return [
        const _SectionTitle('Charts'),
        SliverToBoxAdapter(
          child: _chartsError == null
              ? const SizedBox(
                  height: 120,
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.green),
                  ),
                )
              : _Notice(
                  icon: Icons.cloud_off_outlined,
                  text: "Couldn't load the charts: $_chartsError",
                  action: 'Retry',
                  onAction: () => _loadCharts(refresh: true),
                ),
        ),
      ];
    }
    // Where the user is (India), else the first chart.
    return [
      const _SectionTitle('Charts'),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 14,
            // A square card and a line of text under it.
            childAspectRatio: 0.84,
          ),
          itemCount: charts.length,
          itemBuilder: (context, i) => _ChartCard(
            chart: charts[i],
            color: _chartColors[i % _chartColors.length],
            onTap: () => _open(charts[i]),
          ),
        ),
      ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 12),
        child: Text(
          text,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// A chart: a coloured square with "Top 100" and the region, the first
/// song's cover in the corner, and how many songs under it.
class _ChartCard extends StatelessWidget {
  final Playlist chart;
  final Color color;
  final VoidCallback onTap;

  const _ChartCard({
    required this.chart,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final region = _region(chart);
    final first = chart.tracks.firstOrNull;
    return GestureDetector(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, box) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: box.maxWidth,
              height: box.maxWidth,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color, Color.lerp(color, Colors.black, 0.45)!],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  if (first != null)
                    Positioned(
                      right: -12,
                      bottom: -12,
                      child: Opacity(
                        opacity: 0.9,
                        child: TrackCover(
                          track: first,
                          size: box.maxWidth * 0.5,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Top 100',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          region.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // The card names the chart already.
            Text(
              '${chart.tracks.length} songs',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  const _Notice({
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.subtle),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.subtle, fontSize: 14),
            ),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
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
