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
Future<String?> pickDownloadFolder(BuildContext context) async {
  final last = await Downloads.lastFolder();
  if (!context.mounted) return null;
  final folders = downloadFolders()
    ..sort((a, b) => (a.path == last ? 0 : 1) - (b.path == last ? 0 : 1));
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
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Download to',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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

/// While songs download: a green loading bar across the top of the app
/// and, under it, "1/3 downloading…" with the song and how far it is.
class DownloadProgressBar extends StatelessWidget {
  const DownloadProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = Downloads.instance;
    return ListenableBuilder(
      listenable: downloads,
      builder: (context, _) {
        final track = downloads.current;
        if (track == null) return const SizedBox.shrink();
        final progress = downloads.progressOf(track) ?? 0;
        // Above the Scaffold, so it brings its own text style.
        return IgnorePointer(
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 3,
                    color: AppColors.green,
                    backgroundColor: Colors.white12,
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.elevated.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 8),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${downloads.batchDone + 1}/${downloads.batchTotal} '
                              'downloading…',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.green,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                track.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text(
                              '  ${(progress * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.subtle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
