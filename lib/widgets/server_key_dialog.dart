import 'package:flutter/material.dart';

import '../services/musify_server.dart';
import '../theme.dart';
import 'toast.dart';

/// Asks for the Musify server's address and key, and checks them. True once
/// a working server is saved.
Future<bool> showServerKeyDialog(BuildContext context) async {
  final server = MusifyServer.instance;
  final url = TextEditingController(text: await server.url() ?? '');
  final key = TextEditingController(text: await server.key() ?? '');
  if (!context.mounted) return false;
  final saved = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => _ServerDialog(url: url, secret: key),
  );
  url.dispose();
  key.dispose();
  return saved ?? false;
}

/// [showServerKeyDialog] unless a server is already set up.
Future<bool> ensureServerKey(BuildContext context) async {
  if (await MusifyServer.instance.isSetUp()) return true;
  if (!context.mounted) return false;
  return showServerKeyDialog(context);
}

class _ServerDialog extends StatefulWidget {
  final TextEditingController url;
  final TextEditingController secret;

  const _ServerDialog({required this.url, required this.secret});

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  bool _checking = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final server = MusifyServer.instance;
    final oldUrl = await server.url();
    final oldKey = await server.key();
    await server.setUp(widget.url.text, widget.secret.text);
    try {
      final version = await server.check();
      if (!mounted) return;
      showToast(context, 'Connected (yt-dlp $version)');
      Navigator.of(context).pop(true);
    } catch (e) {
      // Keep what worked before if the new one doesn't.
      await server.setUp(oldUrl, oldKey);
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
          const Text(
            'Downloads and YouTube charts come through your own Musify '
            'server (see the musify_backend repo). Enter its address and key:',
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.url,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            cursorColor: AppColors.green,
            decoration: const InputDecoration(
              hintText: 'https://musify.example.com',
            ),
          ),
          TextField(
            controller: widget.secret,
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
