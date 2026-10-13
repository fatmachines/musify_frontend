import 'package:flutter/material.dart';

import '../services/musify_server.dart';
import '../theme.dart';
import 'toast.dart';

/// Asks for the Musify server's key and checks it. True once a working
/// key is saved.
Future<bool> showServerKeyDialog(BuildContext context) async {
  final server = MusifyServer.instance;
  final field = TextEditingController(text: await server.key() ?? '');
  if (!context.mounted) return false;
  final saved = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => _KeyDialog(field: field),
  );
  field.dispose();
  return saved ?? false;
}

/// [showServerKeyDialog] unless a key is already saved.
Future<bool> ensureServerKey(BuildContext context) async {
  if (await MusifyServer.instance.key() != null) return true;
  if (!context.mounted) return false;
  return showServerKeyDialog(context);
}

class _KeyDialog extends StatefulWidget {
  final TextEditingController field;

  const _KeyDialog({required this.field});

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  bool _checking = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final server = MusifyServer.instance;
    final before = await server.key();
    await server.setKey(widget.field.text);
    try {
      final version = await server.check();
      if (!mounted) return;
      showToast(context, 'Connected (yt-dlp $version)');
      Navigator.of(context).pop(true);
    } catch (e) {
      // Keep the old key if the new one doesn't work.
      await server.setKey(before);
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = "Couldn't connect: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.elevated,
      title: const Text('Musify server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Downloads and YouTube charts come through '
            '${Uri.parse(MusifyServer.base).host}. Paste its key:',
            style: const TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.field,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            cursorColor: AppColors.green,
            decoration: InputDecoration(
              hintText: 'Key',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _checking ? null : _save,
          child: _checking
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
