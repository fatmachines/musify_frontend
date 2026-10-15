import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/sync_service.dart';
import '../theme.dart';

/// What the conflict is about, and the two versions: this device's first.
({String title, String body, String mine, String theirs, String? detail})
describeConflict(SyncConflict conflict) {
  final other = conflict.otherDevice;
  if (conflict.name case final clash?) {
    return (
      title: 'Playlist renamed on two devices',
      body:
          'While this device and $other were apart, the same playlist was '
          'renamed on both. Which name do you want to keep?',
      mine: clash.mine,
      theirs: clash.theirs,
      detail: null,
    );
  }
  final clash = conflict.files!;
  if (clash.folder) {
    final count = clash.mine.length;
    return (
      title: 'Folder renamed on two devices',
      body:
          'While this device and $other were apart, the same folder was '
          'renamed (or moved) differently on each. Which do you want to keep '
          'on all of them?',
      mine: p.posix.dirname(clash.mine.first),
      theirs: p.posix.dirname(clash.theirs.first),
      detail: '$count ${count == 1 ? 'song' : 'songs'}',
    );
  }
  return (
    title: 'Song renamed on two devices',
    body:
        'While this device and $other were apart, the same song was renamed '
        '(or moved) differently on each. Which do you want to keep on all of '
        'them?',
    mine: clash.mine.first,
    theirs: clash.theirs.first,
    detail: null,
  );
}

/// Asks which version of [conflict] to keep, and settles it. Returns once
/// answered or put off ("Decide later" keeps it on the Sync screen).
Future<void> showConflictDialog(
  BuildContext context,
  SyncConflict conflict,
) async {
  final about = describeConflict(conflict);
  final keepMine = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text(about.title),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(about.body, style: TextStyle(color: AppColors.subtle)),
          const SizedBox(height: 16),
          _Choice(
            value: about.mine,
            source: 'This device (${SyncService.deviceName})',
            detail: about.detail,
            onTap: () => Navigator.of(dialog).pop(true),
          ),
          const SizedBox(height: 8),
          _Choice(
            value: about.theirs,
            source: _capitalised(conflict.otherDevice),
            detail: about.detail,
            onTap: () => Navigator.of(dialog).pop(false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Decide later'),
        ),
      ],
    ),
  );
  if (keepMine == null) return;
  await SyncService.instance.resolve(conflict, keepMine: keepMine);
}

String _capitalised(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// One version to keep: what it is, and where it came from.
class _Choice extends StatelessWidget {
  final String value;
  final String source;
  final String? detail;
  final VoidCallback onTap;

  const _Choice({
    required this.value,
    required this.source,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.chip,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [source, ?detail].join(' • '),
                      style: TextStyle(color: AppColors.subtle, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.subtle),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks about each new conflict as sync finds it, one at a time. For the
/// app's shells; returns how to stop.
VoidCallback listenForConflicts(State state) {
  final conflicts = SyncService.instance.conflicts;
  final asked = <String>{};
  var asking = false;
  Future<void> ask() async {
    if (asking || !state.mounted) return;
    final next = conflicts.value
        .where((c) => !asked.contains(c.id))
        .firstOrNull;
    if (next == null) return;
    asking = true;
    asked.add(next.id);
    await showConflictDialog(state.context, next);
    asking = false;
    ask();
  }

  conflicts.addListener(ask);
  // Ones left from last time.
  WidgetsBinding.instance.addPostFrameCallback((_) => ask());
  return () => conflicts.removeListener(ask);
}
