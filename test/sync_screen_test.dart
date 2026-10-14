import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/screens/sync_screen.dart';
import 'package:musify/services/musify_server.dart';
import 'package:musify/services/sync_service.dart';
import 'package:musify/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

void main() {
  setUpAll(() => JustAudioPlatform.instance = FakeJustAudio());

  testWidgets('the Sync screen shows changes as they come', (tester) async {
    SharedPreferences.setMockInitialValues({});
    MusifyServer.instance.debugUse(key: 'k', charts: const []);
    final sync = SyncService.instance;
    sync.debugShow(token: 't', code: 'ABCD-2345');
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.dark), home: const SyncScreen()),
    );
    await tester.pump();
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(find.textContaining('wants to sync'), findsNothing);

    // A device asks: the box appears without leaving the screen.
    sync.debugShow(
      token: 't',
      code: 'ABCD-2345',
      requests: const [SyncRequest('r1', 'Mac', 'macos')],
      devices: const [SyncDevice('me', 'iPhone', 'ios', null, true)],
    );
    await tester.pump();
    expect(find.textContaining('"Mac" wants to sync'), findsOneWidget);
    expect(find.text('iPhone (this device)'), findsOneWidget);

    // Answered: gone, and the new device is listed.
    sync.debugShow(
      token: 't',
      code: 'ABCD-2345',
      devices: const [
        SyncDevice('me', 'iPhone', 'ios', null, true),
        SyncDevice('mac', 'Mac', 'macos', null, false),
      ],
    );
    await tester.pump();
    expect(find.textContaining('wants to sync'), findsNothing);
    expect(find.text('Mac'), findsOneWidget);
    sync.debugShow();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });
}
