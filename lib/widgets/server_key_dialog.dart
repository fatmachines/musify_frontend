import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/musify_server.dart';
import '../theme.dart';
import 'toast.dart';

/// Asks for the Musify server's address and key, and checks them. True once
/// a working server is saved.
Future<bool> showServerKeyDialog(BuildContext context) async {
  final server = MusifyServer.instance;
  final url = await server.url() ?? '';
  final key = await server.key() ?? '';
  if (!context.mounted) return false;
  final saved = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => _ServerDialog(url: url, secret: key),
  );
  return saved ?? false;
}

/// [showServerKeyDialog] unless a server is already set up.
Future<bool> ensureServerKey(BuildContext context) async {
  if (await MusifyServer.instance.isSetUp()) return true;
  if (!context.mounted) return false;
  return showServerKeyDialog(context);
}

class _ServerDialog extends StatefulWidget {
  final String url;
  final String secret;

  const _ServerDialog({required this.url, required this.secret});

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  // Owned here: the dialog's closing animation still shows the fields.
  late final _url = TextEditingController(text: widget.url);
  late final _secret = TextEditingController(text: widget.secret);
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final server = MusifyServer.instance;
    final oldUrl = await server.url();
    final oldKey = await server.key();
    await server.setUp(_url.text, _secret.text);
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
        _error = "Couldn't connect: ${plainError(e)}";
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
            'Downloads and YouTube charts come through your own Musify '
            'server (see the musify_backend repo). Enter its address and key:',
            style: TextStyle(color: AppColors.subtle, fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
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
            controller: _secret,
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

/// What went wrong reaching a server, in words rather than the exception.
String plainError(Object e) {
  final text = '$e';
  if (e is ServerError) return e.message;
  if (e is TimeoutException) return 'the server took too long to answer';
  if (e is HandshakeException || e is TlsException) {
    return "the server's certificate isn't valid";
  }
  if (e is FormatException || e is ArgumentError) {
    return "that isn't a server address";
  }
  if (e is SocketException || e is http.ClientException) {
    if (text.contains('host lookup')) {
      return "can't find that server; check the address";
    }
    if (text.contains('refused')) return "the server isn't answering";
    return "can't reach the server; check the address and your internet";
  }
  return text;
}
