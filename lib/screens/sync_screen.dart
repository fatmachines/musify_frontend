import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/folder_access.dart';
import '../services/library.dart';
import '../services/musify_server.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/folders_sheet.dart';
import '../widgets/server_key_dialog.dart';
import '../widgets/sync_conflict.dart';
import '../widgets/toast.dart';

/// Sync between the user's devices: turn it on (this device's own code)
/// or join another device's code, approve devices that ask, pick the
/// music folder to sync, and see how it's going.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  @override
  void initState() {
    super.initState();
    // Requests and approvals show up within seconds while this is open.
    SyncService.instance.watch();
  }

  @override
  void dispose() {
    SyncService.instance.unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListenableBuilder(
        listenable: Listenable.merge([sync, MusifyServer.instance]),
        builder: (context, _) {
          if (!MusifyServer.instance.setUpNow) return const _NeedsServer();
          // Pull down to check again (or sync now).
          return RefreshIndicator(
            color: AppColors.green,
            onRefresh: () => _run(context, sync.refresh),
            // Not const: they read the sync service directly, so each
            // change has to rebuild them (a const one would be skipped).
            child: switch (sync.status) {
              SyncStatus.off => _Off(),
              SyncStatus.waiting => _Waiting(),
              SyncStatus.on => _On(),
            },
          );
        },
      ),
    );
  }
}

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) showToast(context, '$e');
  }
}

enum _Look { filled, text, danger, icon }

/// A button that shows it's working: a spinner by its label (or in place
/// of its icon) and no second press until [onPressed] is done. Errors
/// become a toast.
class _ActionButton extends StatefulWidget {
  final Future<void> Function() onPressed;
  final String label;
  final IconData? icon;
  final _Look look;
  final bool enabled;

  const _ActionButton({
    required this.onPressed,
    required this.label,
    this.icon,
    this.look = _Look.filled,
    this.enabled = true,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _working = false;

  Future<void> _press() async {
    if (_working) return;
    setState(() => _working = true);
    await _run(context, widget.onPressed);
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.enabled && !_working ? _press : null;
    final spinner = SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: widget.look == _Look.filled ? AppColors.onText : AppColors.green,
      ),
    );
    switch (widget.look) {
      case _Look.icon:
        return IconButton(
          tooltip: widget.label,
          onPressed: onPressed,
          icon: _working ? spinner : Icon(widget.icon),
        );
      case _Look.filled:
        final icon = widget.icon;
        return _working || icon != null
            ? FilledButton.icon(
                onPressed: onPressed,
                icon: _working ? spinner : Icon(icon),
                label: Text(widget.label),
              )
            : FilledButton(onPressed: onPressed, child: Text(widget.label));
      case _Look.text:
      case _Look.danger:
        final style = widget.look == _Look.danger
            ? TextButton.styleFrom(foregroundColor: const Color(0xFFF15E6C))
            : null;
        return _working
            ? TextButton.icon(
                onPressed: null,
                style: style,
                icon: spinner,
                label: Text(widget.label),
              )
            : TextButton(
                onPressed: onPressed,
                style: style,
                child: Text(widget.label),
              );
    }
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Text(
        'Keep your devices in step: playlists, tags, Liked Songs and Home '
        'pins; what\'s playing, to carry on from another device; and, if '
        'you pick a folder, your music files themselves.',
        style: TextStyle(color: AppColors.subtle, fontSize: 14, height: 1.4),
      ),
    );
  }
}

class _NeedsServer extends StatelessWidget {
  const _NeedsServer();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const _Intro(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sync goes through your Musify server. Set it up first.',
                style: TextStyle(color: AppColors.text, fontSize: 15),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => showServerKeyDialog(context),
                child: const Text('Set up Musify server'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Off extends StatefulWidget {
  const _Off();

  @override
  State<_Off> createState() => _OffState();
}

class _OffState extends State<_Off> {
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// All eight letters and digits typed (dashes and spaces don't count).
  bool get _codeComplete =>
      _code.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length == 8;

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      // Clear of the tab bar and the mini player (in the bottom padding).
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
        const _Intro(),
        if (sync.lastError case final error?)
          _Note(icon: Icons.info_outline, text: error),
        const _SectionTitle('Start syncing'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Get a sync code for this device, then enter it on your other '
            'devices.',
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _ActionButton(
              onPressed: sync.create,
              icon: Icons.sync,
              label: 'Turn on sync',
            ),
          ),
        ),
        const _SectionTitle('Or join another device'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Enter the sync code shown on your other device. It will ask you '
            'to approve this one.',
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  cursorColor: AppColors.green,
                  style: const TextStyle(
                    fontSize: 20,
                    letterSpacing: 3,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    hintText: 'ABCD-1234',
                    hintStyle: TextStyle(
                      color: AppColors.muted,
                      letterSpacing: 3,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _ActionButton(
                enabled: _codeComplete,
                onPressed: () => sync.join(_code.text),
                label: 'Join',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 32),
        Center(
          child: SizedBox.square(
            dimension: 40,
            child: CircularProgressIndicator(color: AppColors.green),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Waiting for approval',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'On your other device, open Sync in Settings and approve '
            '"${SyncService.deviceName}". Joining ${sync.code ?? ''}.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: _ActionButton(
            look: _Look.text,
            onPressed: sync.cancelJoin,
            label: 'Cancel',
          ),
        ),
      ],
    );
  }
}

class _On extends StatelessWidget {
  const _On();

  IconData _icon(String platform) => switch (platform) {
    'ios' => Icons.phone_iphone,
    'android' => Icons.phone_android,
    'macos' => Icons.laptop_mac,
    _ => Icons.devices_other,
  };

  Future<void> _pickFolder(BuildContext context) async {
    final sync = SyncService.instance;
    final folders = Library.instance.folders;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Music to sync',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Songs in this folder go to your other devices, and theirs '
                'come here, in the same subfolders.',
                style: TextStyle(color: AppColors.subtle, fontSize: 13),
              ),
            ),
            for (final folder in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                trailing: sync.musicFolder?.id == folder.id
                    ? Icon(Icons.check_circle, color: AppColors.green)
                    : null,
                onTap: () => Navigator.of(sheet).pop(folder),
              ),
            if (folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Add a music folder in Your Library first.',
                  style: TextStyle(color: AppColors.subtle),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text("Don't sync music files"),
              trailing: sync.musicFolder == null
                  ? Icon(Icons.check_circle, color: AppColors.green)
                  : null,
              onTap: () => Navigator.of(sheet).pop(false),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    // Other devices' renames and deletions are done here too.
    if (picked is LibraryFolder &&
        (!context.mounted || !await ensureFileAccess(context))) {
      return;
    }
    await sync.setMusicFolder(picked is LibraryFolder ? picked : null);
  }

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    final code = sync.code ?? '';
    final files = sync.files;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      // Clear of the tab bar and the mini player (in the bottom padding).
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 24,
      ),
      children: [
        for (final request in sync.requests)
          _Approval(
            request: request,
            icon: _icon(request.platform),
            onAnswer: (approve) => sync.answer(request, approve: approve),
          ),
        // Things changed two ways while devices were apart.
        ValueListenableBuilder<List<SyncConflict>>(
          valueListenable: sync.conflicts,
          builder: (context, conflicts, _) => Column(
            children: [
              for (final conflict in conflicts) _ConflictCard(conflict),
            ],
          ),
        ),
        // The code, big, to type on another device.
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your sync code',
                style: TextStyle(color: AppColors.subtle, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      code,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      showToast(context, 'Sync code copied');
                    },
                    icon: const Icon(Icons.copy),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Enter it on another device (Sync in Settings, then Join), then '
                'approve it here.',
                style: TextStyle(color: AppColors.subtle, fontSize: 13),
              ),
            ],
          ),
        ),
        const _SectionTitle('Devices'),
        for (final device in sync.devices)
          ListTile(
            leading: Icon(_icon(device.platform)),
            title: Text(
              device.me ? '${device.name} (this device)' : device.name,
            ),
            subtitle: device.seen == null || device.me
                ? null
                : Text('Seen ${_ago(device.seen!)}'),
            trailing: device.me
                ? null
                : _ActionButton(
                    look: _Look.icon,
                    icon: Icons.remove_circle_outline,
                    label: 'Remove from sync',
                    onPressed: () async {
                      if (await _confirm(
                        context,
                        'Remove "${device.name}" from sync?',
                        'It keeps its playlists and songs but stops '
                            'following this device.',
                        'Remove',
                      )) {
                        await sync.removeDevice(device);
                      }
                    },
                  ),
          ),
        const _SectionTitle('Music files'),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(sync.musicFolder?.name ?? "Not syncing music files"),
          subtitle: const Text(
            'Same songs, in the same folders, on every device',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickFolder(context),
        ),
        if (files != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${files.label}: ${files.current}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.subtle, fontSize: 13),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: files.total == 0
                      ? null
                      : (files.done + files.fraction) / files.total,
                  color: AppColors.green,
                  backgroundColor: AppColors.faint,
                ),
              ],
            ),
          ),
        const _SectionTitle('Status'),
        ListTile(
          leading: sync.busy
              ? SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.green,
                  ),
                )
              : Icon(
                  sync.lastError == null ? Icons.check_circle : Icons.error,
                  color: sync.lastError == null
                      ? AppColors.green
                      : const Color(0xFFF15E6C),
                ),
          title: Text(
            sync.busy
                ? 'Syncing…'
                : sync.lastSynced == null
                ? 'Not synced yet'
                : 'Synced ${_ago(sync.lastSynced!)}',
          ),
          subtitle: sync.lastError == null ? null : Text(sync.lastError!),
          trailing: _ActionButton(
            look: _Look.text,
            enabled: !sync.busy,
            onPressed: sync.syncNow,
            label: 'Sync now',
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: _ActionButton(
            look: _Look.danger,
            onPressed: () async {
              if (await _confirm(
                context,
                'Stop syncing this device?',
                'Its playlists, tags and songs stay here; they just stop '
                    'following your other devices.',
                'Stop syncing',
              )) {
                await SyncService.instance.leave();
              }
            },
            label: 'Stop syncing this device',
          ),
        ),
      ],
    );
  }
}

String _ago(DateTime time) {
  final gone = DateTime.now().difference(time);
  if (gone.inSeconds < 60) return 'just now';
  if (gone.inMinutes < 60) return '${gone.inMinutes} min ago';
  if (gone.inHours < 24) return '${gone.inHours} h ago';
  return '${gone.inDays} d ago';
}

/// A device asking to join: approve or deny (both locked while answering).
class _Approval extends StatefulWidget {
  final SyncRequest request;
  final IconData icon;
  final Future<void> Function(bool approve) onAnswer;

  const _Approval({
    required this.request,
    required this.icon,
    required this.onAnswer,
  });

  @override
  State<_Approval> createState() => _ApprovalState();
}

class _ApprovalState extends State<_Approval> {
  bool? _answering;

  Future<void> _answer(bool approve) async {
    if (_answering != null) return;
    setState(() => _answering = approve);
    await _run(context, () => widget.onAnswer(approve));
    if (mounted) setState(() => _answering = null);
  }

  @override
  Widget build(BuildContext context) {
    Widget spinner(Color color) => SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.green),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, color: AppColors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '"${widget.request.name}" wants to sync with this device',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _answering == null ? () => _answer(false) : null,
                child: _answering == false
                    ? spinner(AppColors.green)
                    : const Text('Deny'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _answering == null ? () => _answer(true) : null,
                child: _answering == true
                    ? spinner(AppColors.onText)
                    : const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async {
  final yes = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return yes ?? false;
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Note({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.subtle),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// A conflict waiting for the user: what it is, and a button to choose.
class _ConflictCard extends StatelessWidget {
  final SyncConflict conflict;

  const _ConflictCard(this.conflict);

  @override
  Widget build(BuildContext context) {
    final about = describeConflict(conflict);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF9F43)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.call_split, color: Color(0xFFFF9F43), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  about.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '“${about.mine}” here, “${about.theirs}” on '
              '${conflict.otherDevice}',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => showConflictDialog(context, conflict),
              child: const Text('Choose'),
            ),
          ),
        ],
      ),
    );
  }
}
