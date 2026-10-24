import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme.dart';

/// Android 11+ lets an app rename, move or delete only the files it made
/// itself; music copied over USB or by another app needs "All files
/// access". Asks for it first (once it's given, this just says yes).
/// Elsewhere there's nothing to ask.
Future<bool> ensureCanChangeFiles(BuildContext context) async {
  if (!Platform.isAndroid) return true;
  final permission = Permission.manageExternalStorage;
  final status = await permission.status;
  // Restricted: Android 10 and older, where reading music lets us change it.
  if (status.isGranted || status.isRestricted) return true;
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: const Text('Allow Musify to change your music files'),
      content: const Text(
        'Android only lets Musify rename, move or delete songs it saved '
        'itself. To change the rest, turn on "Allow access to manage all '
        'files" for Musify on the next screen.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Not now'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Open settings'),
        ),
      ],
    ),
  );
  if (go != true) return false;
  return (await permission.request()).isGranted;
}
