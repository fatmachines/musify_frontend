import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/playlist.dart';
import '../services/downloads.dart';
import '../services/library.dart';
import '../theme.dart';
import 'toast.dart';

/// A folder in the library a song can be saved to.
class DownloadFolder {
  final String path;
  final String name;
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
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: ListView(
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
                folder.path == last
                    ? 'Last used${folder.within == null ? '' : ' • ${folder.within}'}'
                    : folder.within ?? 'Music folder',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(sheet).pop(folder.path),
            ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}

/// Asks for a folder, then downloads [track] there, with toasts for the
/// start and the result.
Future<void> downloadWithPicker(
  BuildContext context,
  YouTubeTrack track,
) async {
  final folder = await pickDownloadFolder(context);
  if (folder == null || !context.mounted) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  showToastOn(overlay, 'Downloading ${track.name}');
  final file = await Downloads.instance.download(track, folder);
  showToastOn(
    overlay,
    file == null
        ? "Couldn't download ${track.name}"
        : 'Saved to ${p.basename(folder)}',
  );
}

/// A download button for a YouTube song row: progress while it downloads.
class DownloadButton extends StatelessWidget {
  final YouTubeTrack track;

  const DownloadButton({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Downloads.instance,
      builder: (context, _) {
        final progress = Downloads.instance.progressOf(track);
        if (progress != null) {
          return SizedBox.square(
            dimension: 48,
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  value: progress > 0 ? progress : null,
                  strokeWidth: 2.5,
                ),
              ),
            ),
          );
        }
        return IconButton(
          tooltip: 'Download',
          icon: const Icon(Icons.download_rounded, color: AppColors.subtle),
          onPressed: () => downloadWithPicker(context, track),
        );
      },
    );
  }
}
