import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/sync_screen.dart';
import '../services/app_log.dart';
import '../services/appearance.dart';
import '../services/equalizer_service.dart';
import '../services/musify_server.dart';
import '../services/sync_service.dart';
import '../services/voice_play.dart';
import '../theme.dart';
import '../widgets/navigation.dart';
import '../widgets/server_key_dialog.dart';
import 'equalizer_tab.dart';

/// The equalizer, light or dark, the Musify server, and sync between
/// devices.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  Future<void> _copyLog(BuildContext context) async {
    await VoicePlay.collectSiriLog();
    await Clipboard.setData(ClipboardData(text: AppLog.dump()));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Debug log copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        // Not a page of its own on the phone (a tab): no back button there.
        automaticallyImplyLeading: Navigator.of(context).canPop(),
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.green,
              child: const Icon(Icons.settings, size: 18, color: Colors.black),
            ),
            const SizedBox(width: 12),
            const Text('Settings'),
          ],
        ),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 120,
        ),
        children: [
          const _Heading('Sound'),
          ListenableBuilder(
            listenable: EqualizerService.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.equalizer_rounded),
              title: const Text('Equalizer'),
              subtitle: Text(EqualizerService.instance.enabled ? 'On' : 'Off'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPage(context, const EqualizerTab()),
            ),
          ),
          const _Heading('Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: Appearance.mode,
            builder: (context, mode, _) => Column(
              children: [
                for (final (value, label, icon) in [
                  (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                  (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                  (
                    ThemeMode.system,
                    'Same as this device',
                    Icons.brightness_auto_outlined,
                  ),
                ])
                  ListTile(
                    leading: Icon(icon),
                    title: Text(label),
                    trailing: mode == value
                        ? Icon(Icons.check_circle, color: AppColors.green)
                        : null,
                    onTap: () => Appearance.set(value),
                  ),
              ],
            ),
          ),
          const _Heading('Devices'),
          ListenableBuilder(
            listenable: Listenable.merge([
              MusifyServer.instance,
              SyncService.instance,
            ]),
            builder: (context, _) => FutureBuilder<String?>(
              future: MusifyServer.instance.url(),
              builder: (context, snapshot) {
                final url = snapshot.data;
                return ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('Musify server'),
                  subtitle: Text(
                    url == null
                        ? 'Not set up: for downloads, charts and sync'
                        : Uri.parse(url).host,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showServerKeyDialog(context),
                );
              },
            ),
          ),
          ListenableBuilder(
            listenable: SyncService.instance,
            builder: (context, _) {
              final sync = SyncService.instance;
              return ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Sync'),
                subtitle: Text(sync.summary),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage(context, const SyncScreen()),
              );
            },
          ),
          const _Heading('Help'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Copy debug log'),
            onTap: () => _copyLog(context),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;

  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.subtle,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
