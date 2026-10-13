import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../models/playlist.dart';
import '../services/app_log.dart';
import '../services/metadata_service.dart';
import '../services/player_service.dart';
import '../theme.dart';
import '../utils/cover_color.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/covers.dart';
import '../widgets/track_swiper.dart';

const _fallbackColor = Color(0xFF3E3E3E);

/// The full-screen player. The shell slides it up over everything and
/// handles dragging it down to close.
class NowPlaying extends StatelessWidget {
  final VoidCallback onClose;

  const NowPlaying({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final service = PlayerService.instance;
    return StreamBuilder<Track?>(
      stream: service.trackStream,
      initialData: service.currentTrack,
      builder: (context, snapshot) {
        final track = snapshot.data;
        if (track == null) return const ColoredBox(color: AppColors.background);
        return FutureBuilder<Color?>(
          future: trackColor(track),
          builder: (context, color) {
            final accent = color.data ?? _fallbackColor;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [accent, Color.lerp(accent, Colors.black, 0.7)!],
                ),
              ),
              // Sits outside any Scaffold, so it brings its own Material
              // for text styles, ink and the slider.
              child: Material(
                type: MaterialType.transparency,
                child: SafeArea(
                  child: FutureBuilder(
                    future: MetadataService.loadInfo([track]),
                    builder: (context, _) =>
                        _Body(track: track, onClose: onClose),
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

class _Body extends StatelessWidget {
  final Track track;
  final VoidCallback onClose;

  const _Body({required this.track, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final info = MetadataService.cachedInfo(track);
    final playlist = PlayerService.instance.current;
    final lyrics = info?.lyrics;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                  iconSize: 32,
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                Expanded(
                  child: Text(
                    playlist?.name ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerRight,
                  onPressed: () => _showMore(context, track),
                  icon: const Icon(Icons.more_horiz),
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
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info?.title ?? track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  info?.artist ?? 'Unknown artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.subtle, fontSize: 16),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _SeekBar(),
          const SizedBox(height: 4),
          const _Controls(),
          const SizedBox(height: 8),
          Row(
            children: [
              const _RepeatButton(),
              const Spacer(),
              IconButton(
                tooltip: 'Share',
                onPressed: () => _share(context, track),
                icon: const Icon(Icons.ios_share, size: 22),
              ),
              IconButton(
                tooltip: 'Queue',
                onPressed: () => _showQueue(context),
                icon: const Icon(Icons.queue_music, size: 24),
              ),
            ],
          ),
          if (lyrics != null) ...[
            const SizedBox(height: 8),
            _LyricsCard(track: track, lyrics: lyrics),
          ],
          const SizedBox(height: 12),
        ],
      ),
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
    final player = PlayerService.instance.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snapshot) {
        final total = player.duration ?? Duration.zero;
        final max = total.inMilliseconds.toDouble();
        final position = (snapshot.data ?? Duration.zero).inMilliseconds
            .toDouble()
            .clamp(0.0, max);
        final value = _dragging ?? position;
        final shown = Duration(milliseconds: value.round());
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                padding: EdgeInsets.zero,
                activeTrackColor: AppColors.text,
                inactiveTrackColor: Colors.white24,
                thumbColor: AppColors.text,
                overlayColor: Colors.white24,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: SizedBox(
                height: 24,
                child: Slider(
                  value: value,
                  max: max > 0 ? max : 1,
                  onChanged: max > 0
                      ? (v) => setState(() => _dragging = v)
                      : null,
                  onChangeEnd: (v) {
                    player.seek(Duration(milliseconds: v.round()));
                    setState(() => _dragging = null);
                  },
                ),
              ),
            ),
            Row(
              children: [
                Text(_format(shown), style: _timeStyle),
                const Spacer(),
                Text('-${_format(total - shown)}', style: _timeStyle),
              ],
            ),
          ],
        );
      },
    );
  }

  static const _timeStyle = TextStyle(color: AppColors.subtle, fontSize: 11);
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
    final player = service.player;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        StreamBuilder<bool>(
          stream: player.shuffleModeEnabledStream,
          initialData: player.shuffleModeEnabled,
          builder: (context, snapshot) {
            final on = snapshot.data ?? false;
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
        StreamBuilder<bool>(
          stream: player.playingStream,
          initialData: player.playing,
          builder: (context, snapshot) {
            final playing = snapshot.data ?? false;
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
                      color: Colors.black,
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
          color: Colors.white.withValues(alpha: 0.12),
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
        files: [XFile(track.path)],
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
            const Divider(color: Colors.white12, height: 16),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Add to playlist'),
              onTap: () {
                Navigator.of(sheet).pop();
                showAddToPlaylist(context, track);
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
                _showQueue(context);
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
                }, style: const TextStyle(color: AppColors.subtle)),
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
                  title: const Text(
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
    return Text(text, style: const TextStyle(color: AppColors.green));
  }
}

void _showQueue(BuildContext context) {
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
          final order = state.effectiveSequence;
          final current = state.currentSource;
          final position = current == null ? -1 : order.indexOf(current);
          final upNext = order.skip(position + 1).toList();
          return ListView(
            children: [
              const _QueueHeading('Now playing'),
              if (current?.tag is Track)
                _QueueTile(track: current!.tag as Track, playing: true),
              _QueueHeading('Next from: ${playlist?.name ?? ''}'),
              for (final source in upNext)
                if (source.tag is Track)
                  _QueueTile(
                    track: source.tag as Track,
                    onTap: () => player.seek(
                      Duration.zero,
                      index: state.sequence.indexOf(source),
                    ),
                  ),
            ],
          );
        },
      ),
    ),
  );
}

class _QueueHeading extends StatelessWidget {
  final String text;

  const _QueueHeading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
