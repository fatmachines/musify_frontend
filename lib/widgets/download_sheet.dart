import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import '../services/downloads.dart';
import '../services/library.dart';
import '../theme.dart';
import 'server_key_dialog.dart';
import 'toast.dart';

/// A folder in the library a song can be saved to.
class DownloadFolder {
  final String path;
  final String name;

  /// Where it is, e.g. "Music/Travel"; null for a library folder itself.
  final String? within;

  const DownloadFolder(this.path, this.name, this.within);
}

/// The library folders and every folder playlist inside them.
List<DownloadFolder> downloadFolders() {
  final library = Library.instance;
  final folders = <DownloadFolder>[];
  for (final root in library.folders) {
    folders.add(DownloadFolder(root.path, root.name, null));
    for (final playlist in library.all) {
      final location = playlist.location;
      if (location == null || location == '.') continue;
      if (!p.isWithin(root.path, playlist.id)) continue;
      folders.add(
        DownloadFolder(playlist.id, playlist.name, '${root.name}/$location'),
      );
    }
  }
  return folders;
}

/// Asks where to save, the last folder used first. Null if cancelled.
/// With [mainOnly], just the library folders themselves.
Future<String?> pickDownloadFolder(
  BuildContext context, {
  bool mainOnly = false,
  String title = 'Download to',
}) async {
  final last = await Downloads.lastFolder();
  if (!context.mounted) return null;
  final folders = [
    for (final f in downloadFolders())
      if (!mainOnly || f.within == null) f,
  ]..sort((a, b) => (a.path == last ? 0 : 1) - (b.path == last ? 0 : 1));
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          if (folders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Add a music folder in Your Library first.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle),
              ),
            ),
          for (final folder in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.name),
              subtitle: Text(
                [
                  if (folder.path == last) 'Last used',
                  folder.within ?? 'Music folder',
                ].join(' • '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(sheet).pop(folder.path),
            ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom + 16),
        ],
      ),
    ),
  );
}

/// Asks for a folder, then queues [track] to be saved there, with toasts
/// for the start and the result.
Future<void> downloadWithPicker(
  BuildContext context,
  YouTubeTrack track,
) async {
  if (!await ensureServerKey(context) || !context.mounted) return;
  final folder = await pickDownloadFolder(context);
  if (folder == null || !context.mounted) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  final downloads = Downloads.instance;
  showToastOn(
    overlay,
    downloads.current == null
        ? 'Downloading ${track.name}'
        : 'Will download after the current song',
  );
  downloads.download(
    track,
    folder,
    onDone: (file, error) => showToastOn(
      overlay,
      file == null
          ? "Couldn't download ${track.name}: $error"
          : 'Saved ${track.name} to ${p.basename(folder)}',
    ),
  );
}

/// Asks for a library folder, then saves every YouTube song in [playlist]
/// into a new folder named after it there.
Future<void> downloadPlaylistWithPicker(
  BuildContext context,
  Playlist playlist,
) async {
  if (!await ensureServerKey(context) || !context.mounted) return;
  final parent = await pickDownloadFolder(
    context,
    mainOnly: true,
    title: 'Download "${playlist.name}" into',
  );
  if (parent == null || !context.mounted) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  final (count, folder) = await Downloads.instance.downloadPlaylist(
    playlist,
    parent,
    onDone: (saved, failed) => showToastOn(
      overlay,
      failed == 0
          ? 'Saved ${playlist.name}: $saved songs'
          : 'Saved $saved songs to ${playlist.name}, $failed failed',
    ),
  );
  showToastOn(
    overlay,
    count == 0
        ? 'Everything is already in ${p.basename(folder)}'
        : 'Downloading $count songs to ${p.basename(folder)}',
  );
}

/// Puts the download banner above [child] while songs download, pushing it
/// down (it slides in and back out), instead of covering it.
class DownloadBannerLayout extends StatelessWidget {
  final Widget child;

  const DownloadBannerLayout({super.key, required this.child});

  /// The banner below the status bar: its text and the green bar.
  static const _height = 34.0;

  @override
  Widget build(BuildContext context) {
    final downloads = Downloads.instance;
    final media = MediaQuery.of(context);
    final top = media.padding.top;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, child) => TweenAnimationBuilder<double>(
        tween: Tween(end: downloads.current == null ? 0 : 1),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        builder: (context, shown, child) => Column(
          children: [
            // The banner takes the status bar's place along with its own,
            // so the app below starts just under it.
            // Not built while hidden: its loading bar would animate away.
            if (shown > 0)
              ClipRect(
                child: SizedBox(
                  height: (top + _height) * shown,
                  child: OverflowBox(
                    alignment: Alignment.bottomCenter,
                    minHeight: top + _height,
                    maxHeight: top + _height,
                    child: const _DownloadBanner(),
                  ),
                ),
              ),
            Expanded(
              child: MediaQuery(
                data: media.copyWith(
                  padding: media.padding.copyWith(top: top * (1 - shown)),
                  viewPadding: media.viewPadding.copyWith(
                    top: media.viewPadding.top * (1 - shown),
                  ),
                ),
                child: child!,
              ),
            ),
          ],
        ),
        child: child,
      ),
      child: child,
    );
  }
}

/// "1/3 downloading…", the song and how far it is, over a green loading
/// bar. Keeps showing the last song while it slides away.
class _DownloadBanner extends StatefulWidget {
  const _DownloadBanner();

  @override
  State<_DownloadBanner> createState() => _DownloadBannerState();
}

class _DownloadBannerState extends State<_DownloadBanner> {
  String _count = '';
  String _name = '';
  double _progress = 0;

  @override
  Widget build(BuildContext context) {
    final downloads = Downloads.instance;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final track = downloads.current;
        if (track != null) {
          _count =
              '${downloads.batchDone + 1}/${downloads.batchTotal} '
              'downloading…';
          _name = track.name;
          _progress = downloads.progressOf(track) ?? 0;
        }
        return Material(
          color: AppColors.surface,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          _count,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.green,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Text(
                          '${(_progress * 100).round()}%',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.subtle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  minHeight: 3,
                  color: AppColors.green,
                  backgroundColor: Colors.white12,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
