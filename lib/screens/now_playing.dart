import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/library.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../services/youtube/youtube_web_player.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/playing_elsewhere.dart';
import '../widgets/download_sheet.dart';
import '../widgets/covers.dart';
import '../widgets/tag_sheet.dart';
import '../widgets/track_swiper.dart';

const _fallbackColor = Color(0xFF3E3E3E);

/// The full-screen player. The shell slides it up over everything and
/// handles dragging it down to close.
class NowPlaying extends StatelessWidget {
  final VoidCallback onClose;

  /// Dragging down to close, for where the player scrolls (a song with
  /// lyrics) and the shell's own drag can't see it.
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  const NowPlaying({
    super.key,
    required this.onClose,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return StreamBuilder<Track?>(
      stream: service.trackStream,
      initialData: service.currentTrack,
      builder: (context, snapshot) {
        final track = snapshot.data;
        if (track == null) return ColoredBox(color: AppColors.background);
        return FutureBuilder<Color?>(
          future: trackColor(track),
          initialData: loadedTrackColor(track),
          builder: (context, color) {
            final accent = color.data ?? _fallbackColor;
            return AnimatedContainer(
              duration: Duration(milliseconds: 400),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.tint(accent),
                    AppColors.backdrop(accent, 0.7),
                  ],
                ),
              ),
              // Sits outside any Scaffold, so it brings its own Material
              // for text styles, ink and the slider.
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  child: FutureBuilder(
                    future: MetadataService.loadInfo([track]),
                    builder: (context, _) => _Body(
                      track: track,
                      onClose: onClose,
                      onDragUpdate: onDragUpdate,
                      onDragEnd: onDragEnd,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// How much of the lyrics card shows below the player, hinting that it
/// scrolls up. Left empty for songs without lyrics, so the cover and the
/// controls stay put from one song to the next.
const _peek = 28.0;

class _Body extends StatelessWidget {
  final Track track;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  const _Body({
    required this.track,
    required this.onClose,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final lyrics = MetadataService.cachedInfo(track)?.lyrics;
    final page = Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: _page(context),
    );
    if (lyrics == null) {
      return Column(
        children: [
          Expanded(child: page),
          const SizedBox(height: _peek),
        ],
      );
    }
    // Lyrics below the fold, as Spotify has them.
    return _BelowTheFold(
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      page: page,
      below: Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: _LyricsCard(track: track, lyrics: lyrics),
      ),
    );
  }

  Widget _page(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    final playlist = PlayerService.instance.current;
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [
              // The icons sit centred in their buttons (so the hover and
              // press circles are round them), the buttons nudged out so
              // the icons still line up with the cover's edges.
              Transform.translate(
                offset: Offset(-8, 0),
                child: IconButton(
                  tooltip: 'Close',
                  iconSize: 32,
                  onPressed: onClose,
                  icon: Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ),
              Expanded(
                child: Text(
                  playlist?.name ?? '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              Transform.translate(
                offset: Offset(12, 0),
                child: IconButton(
                  tooltip: 'More',
                  onPressed: () => _showMore(context, track),
                  icon: Icon(Icons.more_horiz),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.maxWidth < box.maxHeight - 16
                  ? box.maxWidth
                  : box.maxHeight - 16;
              // Swipe the cover sideways for the previous or next song.
              // The pages run the full screen width (past the side
              // padding) so covers slide in from the screen edge.
              return OverflowBox(
                maxWidth: box.maxWidth + 48,
                child: TrackSwiper(
                  itemBuilder: (context, track) => Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: TrackCover(track: track, size: size),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Like sits between the cover and the title.
        Align(
          alignment: Alignment.centerRight,
          child: _LikeButton(track: track),
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info?.title ?? track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    info?.artist ?? 'Unknown artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.subtle, fontSize: 16),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 16),
        _SeekBar(),
        SizedBox(height: 4),
        _Controls(),
        // Another device has the music: say so, and offer to play here.
        const PlayingElsewhereStrip(
          margin: EdgeInsets.only(top: 12),
          radius: BorderRadius.all(Radius.circular(8)),
        ),
        SizedBox(height: 8),
        Row(
          children: [
            _RepeatButton(),
            Spacer(),
            IconButton(
              tooltip: 'Share',
              onPressed: () => _share(context, track),
              icon: Icon(Icons.ios_share, size: 22),
            ),
            IconButton(
              tooltip: 'Queue',
              onPressed: () => showQueueSheet(context),
              icon: Icon(Icons.queue_music, size: 24),
            ),
          ],
        ),
        SizedBox(height: 12),
      ],
    );
  }
}

/// [page] filling the screen (but for [_peek]) with [below] under it,
/// scrolling. At the top, dragging down still closes the player: the
/// pull past the top goes to the shell's drag.
class _BelowTheFold extends StatefulWidget {
  final Widget page;
  final Widget below;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  const _BelowTheFold({
    required this.page,
    required this.below,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  State<_BelowTheFold> createState() => _BelowTheFoldState();
}

class _BelowTheFoldState extends State<_BelowTheFold> {
  final _scroll = ScrollController();

  /// This drag moves the player, not the page.
  bool _closing = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails? from, double dy) {
    widget.onDragUpdate?.call(
      DragUpdateDetails(
        globalPosition: from?.globalPosition ?? Offset.zero,
        delta: Offset(0, dy),
        primaryDelta: dy,
      ),
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (widget.onDragUpdate == null) return false;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        (n.overscroll < 0 || _closing)) {
      _closing = true;
      _drag(n.dragDetails, -n.overscroll);
    } else if (n is ScrollUpdateNotification &&
        _closing &&
        n.dragDetails != null) {
      // Back up while closing: the player follows; the page stays put.
      _drag(n.dragDetails, -(n.scrollDelta ?? 0));
      _scroll.jumpTo(0);
    } else if (n is ScrollEndNotification && _closing) {
      _closing = false;
      widget.onDragEnd?.call(
        n.dragDetails ?? DragEndDetails(primaryVelocity: 0),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SingleChildScrollView(
          controller: _scroll,
          // Clamped, so pulling past the top is an overscroll to pass on.
          physics: const ClampingScrollPhysics(),
          child: Column(
            children: [
              SizedBox(height: box.maxHeight - _peek, child: widget.page),
              widget.below,
            ],
          ),
        ),
      ),
    );
  }
}

/// The heart next to the song title: outlined, or filled green once liked.
class _LikeButton extends StatelessWidget {
  final Track track;

  const _LikeButton({required this.track});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Library.instance,
      builder: (context, _) {
        final liked = Library.instance.isLiked(track);
        return IconButton(
          tooltip: liked ? 'Remove from Liked Songs' : 'Like',
          iconSize: 28,
          // Flush with the cover's right edge.
          padding: EdgeInsets.zero,
          alignment: Alignment.centerRight,
          constraints: BoxConstraints.tightFor(width: 48, height: 44),
          onPressed: () => Library.instance.toggleLike(track),
          icon: AnimatedSwitcher(
            duration: Duration(milliseconds: 180),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              key: ValueKey(liked),
              color: liked ? AppColors.green : AppColors.text,
            ),
          ),
        );
      },
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar();

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Where the thumb is while being dragged; null otherwise.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    final player = service.player;
    final loaded = YouTubeWebPlayer.instance.buffered;
    // Also redrawn as the video loads while paused.
    return ListenableBuilder(
      listenable: loaded,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: PlayerService.instance.shownPosition,
        initialData: PlayerService.instance.shownPositionNow,
        builder: (context, snapshot) {
          final total = player.duration ?? Duration.zero;
          final max = total.inMilliseconds.toDouble();
          final position = PlayerService
              .instance
              .shownPositionNow
              .inMilliseconds
              .toDouble()
              .clamp(0.0, max);
          // How far a YouTube video has loaded, like YouTube's grey bar.
          // Songs on the device are all there, so they don't show one.
          final buffered = service.currentTrack is YouTubeTrack
              ? loaded.value.inMilliseconds.toDouble().clamp(0.0, max)
              : null;
          final value = _dragging ?? position;
          final shown = Duration(milliseconds: value.round());
          return Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  padding: EdgeInsets.zero,
                  activeTrackColor: AppColors.text,
                  inactiveTrackColor: AppColors.track,
                  secondaryActiveTrackColor: AppColors.loaded,
                  thumbColor: AppColors.text,
                  overlayColor: AppColors.track,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: SizedBox(
                  height: 24,
                  child: Slider(
                    value: value,
                    secondaryTrackValue: buffered,
                    max: max > 0 ? max : 1,
                    onChanged: max > 0
                        ? (v) => setState(() => _dragging = v)
                        : null,
                    onChangeEnd: (v) {
                      PlayerService.instance.seekTo(
                        Duration(milliseconds: v.round()),
                      );
                      setState(() => _dragging = null);
                    },
                  ),
                ),
              ),
              Row(
                children: [
                  Text(_format(shown), style: _timeStyle),
                  Spacer(),
                  Text('-${_format(total - shown)}', style: _timeStyle),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  static TextStyle get _timeStyle =>
      TextStyle(color: AppColors.subtle, fontSize: 11);
}

String _format(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final minutes = d.inMinutes;
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: service.shuffleOn,
          builder: (context, on, _) {
            return _DotButton(
              tooltip: 'Shuffle',
              icon: Icons.shuffle,
              active: on,
              onTap: () => service.setShuffle(!on),
            );
          },
        ),
        IconButton(
          tooltip: 'Previous',
          iconSize: 40,
          color: AppColors.text,
          onPressed: service.previous,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        ValueListenableBuilder<bool>(
          // This device's, or the other device's being played from here.
          valueListenable: PlayerService.instance.shownPlaying,
          builder: (context, playing, _) {
            return Semantics(
              button: true,
              label: playing ? 'Pause' : 'Play',
              child: Material(
                color: AppColors.text,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: service.togglePlayback,
                  child: SizedBox.square(
                    dimension: 64,
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 38,
                      color: AppColors.onText,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Next',
          iconSize: 40,
          color: AppColors.text,
          onPressed: service.next,
          icon: const Icon(Icons.skip_next_rounded),
        ),
        ValueListenableBuilder<SleepTimer?>(
          valueListenable: service.sleepTimer,
          builder: (context, timer, _) => _DotButton(
            tooltip: 'Sleep timer',
            icon: Icons.timer_outlined,
            active: timer != null,
            onTap: () => _showSleepTimer(context),
          ),
        ),
      ],
    );
  }
}

/// An icon that turns green with a dot under it when on, like Spotify's
/// shuffle.
class _DotButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _DotButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.green : AppColors.text;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 40,
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: color),
              Container(
                width: 4,
                height: 4,
                margin: const EdgeInsets.only(top: 3),
                decoration: BoxDecoration(
                  color: active ? AppColors.green : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton();

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return StreamBuilder<LoopMode>(
      stream: service.player.loopModeStream,
      initialData: service.player.loopMode,
      builder: (context, snapshot) {
        final mode = snapshot.data ?? LoopMode.off;
        return _DotButton(
          tooltip: switch (mode) {
            LoopMode.off => 'Repeat off',
            LoopMode.all => 'Repeat all',
            LoopMode.one => 'Repeat one',
          },
          icon: mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
          active: mode != LoopMode.off,
          onTap: service.cycleRepeat,
        );
      },
    );
  }
}

class _LyricsCard extends StatelessWidget {
  final Track track;
  final String lyrics;

  const _LyricsCard({required this.track, required this.lyrics});

  @override
  Widget build(BuildContext context) {
    final preview = lyrics
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(2)
        .join('\n');
    return GestureDetector(
      onTap: () => _showLyrics(context, track, lyrics),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.faint,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lyrics preview',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Sheets ---------------------------------------------------------------------

Future<void> _share(BuildContext context, Track track) async {
  final box = context.findRenderObject() as RenderBox?;
  try {
    await SharePlus.instance.share(
      ShareParams(
        // A YouTube song is shared as its link.
        uri: track is YouTubeTrack
            ? Uri.parse('https://youtu.be/${track.videoId}')
            : null,
        files: track is YouTubeTrack ? null : [XFile(track.path)],
        // iPad anchors the share popover here.
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  } catch (e) {
    AppLog.add('share: failed: $e');
  }
}

Widget _sheetHeader(Track track) {
  final info = MetadataService.cachedInfo(track);
  return ListTile(
    leading: TrackCover(track: track, size: 48),
    title: Text(
      info?.title ?? track.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      [info?.artist, info?.album].whereType<String>().join(' • '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

void _showMore(BuildContext context, Track track) {
  final service = PlayerService.instance;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      // Sized to its content, scrolling on screens too short for it.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHeader(track),
            Divider(color: AppColors.faint, height: 16),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Add to playlist'),
              onTap: () {
                Navigator.of(sheet).pop();
                showAddToPlaylist(context, track);
              },
            ),
            // YouTube songs can't be tagged.
            if (track is! YouTubeTrack)
              ListTile(
                leading: const Icon(Icons.sell_outlined),
                title: const Text('Tag'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  showTagSheet(context, track);
                },
              ),
            if (track is YouTubeTrack)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Download'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  downloadWithPicker(context, track);
                },
              ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share'),
              onTap: () {
                Navigator.of(sheet).pop();
                _share(context, track);
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Sleep timer'),
              onTap: () {
                Navigator.of(sheet).pop();
                _showSleepTimer(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Go to queue'),
              onTap: () {
                Navigator.of(sheet).pop();
                showQueueSheet(context);
              },
            ),
            StreamBuilder<LoopMode>(
              stream: service.player.loopModeStream,
              initialData: service.player.loopMode,
              builder: (context, snapshot) => ListTile(
                leading: const Icon(Icons.repeat),
                title: const Text('Repeat'),
                trailing: Text(switch (snapshot.data ?? LoopMode.off) {
                  LoopMode.off => 'Off',
                  LoopMode.all => 'All',
                  LoopMode.one => 'One',
                }, style: TextStyle(color: AppColors.subtle)),
                onTap: service.cycleRepeat,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File'),
              subtitle: Text(
                '${track.title}.${track.extension.toLowerCase()}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void _showSleepTimer(BuildContext context) {
  final service = PlayerService.instance;
  const options = [5, 10, 15, 30, 45, 60];
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      // Sized to its content, scrolling on screens too short for it.
      child: SingleChildScrollView(
        child: ValueListenableBuilder<SleepTimer?>(
          valueListenable: service.sleepTimer,
          builder: (context, timer, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Sleep timer',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (timer != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SleepCountdown(timer: timer),
                ),
              for (final minutes in options)
                ListTile(
                  title: Text(minutes == 60 ? '1 hour' : '$minutes minutes'),
                  onTap: () {
                    service.setSleepTimer(duration: Duration(minutes: minutes));
                    Navigator.of(sheet).pop();
                  },
                ),
              ListTile(
                title: const Text('End of track'),
                onTap: () {
                  service.setSleepTimer(endOfTrack: true);
                  Navigator.of(sheet).pop();
                },
              ),
              if (timer != null)
                ListTile(
                  title: Text(
                    'Turn off timer',
                    style: TextStyle(color: AppColors.green),
                  ),
                  onTap: () {
                    service.setSleepTimer();
                    Navigator.of(sheet).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SleepCountdown extends StatefulWidget {
  final SleepTimer timer;

  const _SleepCountdown({required this.timer});

  @override
  State<_SleepCountdown> createState() => _SleepCountdownState();
}

class _SleepCountdownState extends State<_SleepCountdown> {
  late final Timer _tick = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final endsAt = widget.timer.endsAt;
    final text = endsAt == null
        ? 'Stops at the end of this track'
        : 'Stops in ${_format(endsAt.difference(DateTime.now()))}';
    return Text(text, style: TextStyle(color: AppColors.green));
  }
}

/// The queue: what's playing and what's next, reorderable.
void showQueueSheet(BuildContext context) {
  final player = PlayerService.instance.player;
  final playlist = PlayerService.instance.current;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: StreamBuilder<SequenceState>(
        stream: player.sequenceStateStream,
        initialData: player.sequenceState,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          final sequence = state.sequence;
          final current = state.currentIndex ?? -1;
          final upNext = [
            for (var i = current + 1; i < sequence.length; i++) i,
          ];
          final queued = [
            for (final i in upNext)
              if (sequence[i].tag is QueuedTrack) i,
          ];
          final rest = [
            for (final i in upNext)
              if (sequence[i].tag is! QueuedTrack) i,
          ];
          Widget tile(int i) => _QueueTile(
            track: sequence[i].tag as Track,
            onTap: () => player.seek(Duration.zero, index: i),
          );
          return ListView(
            children: [
              const _QueueHeading('Now playing'),
              if (current >= 0 && sequence[current].tag is Track)
                _QueueTile(
                  track: sequence[current].tag as Track,
                  playing: true,
                ),
              if (queued.isNotEmpty)
                _QueueHeading(
                  'Next in queue',
                  action: TextButton(
                    onPressed: PlayerService.instance.clearQueue,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.subtle,
                    ),
                    child: const Text('Clear queue'),
                  ),
                ),
              for (final i in queued) tile(i),
              if (rest.isNotEmpty)
                _QueueHeading('Next from: ${playlist?.name ?? ''}'),
              for (final i in rest) tile(i),
            ],
          );
        },
      ),
    ),
  );
}

class _QueueHeading extends StatelessWidget {
  final String text;
  final Widget? action;

  const _QueueHeading(this.text, {this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  final Track track;
  final bool playing;
  final VoidCallback? onTap;

  const _QueueTile({required this.track, this.playing = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    return ListTile(
      onTap: onTap,
      leading: TrackCover(track: track, size: 44),
      title: Text(
        info?.title ?? track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: playing ? AppColors.green : AppColors.text),
      ),
      subtitle: Text(
        info?.artist ?? 'Unknown artist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

void _showLyrics(BuildContext context, Track track, String lyrics) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          _sheetHeader(track),
          const SizedBox(height: 8),
          Text(
            lyrics,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
  );
}
