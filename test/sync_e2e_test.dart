// Runs against a real Musify backend started from ../backend; skipped if
// it (or its Python) isn't there.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/library.dart';
import 'package:musify/services/musify_server.dart';
import 'package:musify/services/player_service.dart';
import 'package:musify/services/sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';

const python = String.fromEnvironment(
  'MUSIFY_PYTHON',
  defaultValue: '/tmp/claude-0/-root-musify/4642ad07-31d5-48d3-bb83-29633f9acdfd/scratchpad/venv/bin/python',
);
const backend = '/root/musify/backend/musify_server.py';
const base = 'http://127.0.0.1:8797';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  JustAudioPlatform.instance = FakeJustAudio();
  final runnable = File(python).existsSync() && File(backend).existsSync();

  late Process server;
  late Directory data;
  late Directory music;

  setUpAll(() async {
    if (!runnable) return;
    // Real HTTP, not the test binding's fake.
    HttpOverrides.global = null;
    data = await Directory.systemTemp.createTemp('musify_sync_data');
    music = await Directory.systemTemp.createTemp('musify_sync_music');
    for (final (rel, bytes) in [
      ('Rock/a.mp3', 'aaaa'),
      ('Pop/b.mp3', 'bbbb'),
    ]) {
      final f = File(p.join(music.path, rel));
      await f.create(recursive: true);
      await f.writeAsString(bytes * 1000);
    }
    server = await Process.start(
      python,
      [backend],
      environment: {
        'MUSIFY_KEY': 'k',
        'MUSIFY_PORT': '8797',
        'MUSIFY_DATA': data.path,
        'MUSIFY_CACHE': p.join(data.path, 'cache'),
      },
      workingDirectory: p.dirname(backend),
    );
    for (var i = 0; i < 50; i++) {
      try {
        final r = await http.get(
          Uri.parse('$base/health'),
          headers: {'X-Musify-Key': 'k'},
        );
        if (r.statusCode == 200) break;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });

  tearDownAll(() async {
    if (!runnable) return;
    server.kill();
    await data.delete(recursive: true);
    await music.delete(recursive: true);
  });

  /// The other device, talking to the server directly.
  Future<(int, dynamic)> mac(
    String method,
    String path, {
    Object? body,
    String? token,
    List<int>? raw,
  }) async {
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers['X-Musify-Key'] = 'k';
    if (token != null) request.headers['X-Musify-Sync'] = token;
    if (raw != null) {
      request.bodyBytes = raw;
    } else if (body != null) {
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await request.send());
    return (
      response.statusCode,
      response.body.startsWith('{')
          ? jsonDecode(response.body)
          : response.bodyBytes,
    );
  }

  test(
    'two devices: join, library both ways, files, deletions, carry on',
    () async {
      SharedPreferences.setMockInitialValues({
        'library_folders': [music.path],
      });
      final library = Library.instance;
      await library.ensureLoaded();
      await MusifyServer.instance.setUp(base, 'k');
      final sync = SyncService.instance;
      await sync.start();

      // This device: a playlist with a song here and a YouTube one, a like.
      final a = library.allSongs.firstWhere((t) => t.path.endsWith('a.mp3'));
      final road = library.createPlaylist('Road Trip');
      library.addTrack(road, a);
      library.addTrack(
        road,
        YouTubeTrack(videoId: 'abcdefghijk', name: 'Video'),
      );
      library.toggleLike(a);
      await sync.create();
      await sync.setMusicFolder(library.folders.single);
      await sync.syncNow();
      expect(sync.lastError, isNull);
      final code = sync.code!;

      // The Mac asks to join; this device approves.
      final (_, joined) = await mac(
        'POST',
        '/sync/join',
        body: {
          'code': code,
          'device': 'mac-device-0001',
          'name': 'Mac',
          'platform': 'macos',
        },
      );
      await sync.syncNow();
      expect(sync.requests.single.name, 'Mac');
      // Approving while the Sync screen's quick checks run alongside.
      sync.watch();
      await sync.answer(sync.requests.single, approve: true);
      expect(sync.requests, isEmpty, reason: 'the approval box goes away');
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(sync.requests, isEmpty, reason: 'and stays away');
      sync.unwatch();
      final (_, status) = await mac('GET', '/sync/join/${joined['request']}');
      expect(status['status'], 'approved');
      final token = status['token'] as String;
      expect(sync.devices.map((d) => d.name), contains('Mac'));

      // The Mac sees this device's library and songs.
      final (_, state) = await mac('GET', '/sync/state/library', token: token);
      final items = (state['data']['items'] as Map).cast<String, dynamic>();
      final roadItem = items['p:${road.id.substring('custom:'.length)}']['v'];
      expect(roadItem['name'], 'Road Trip');
      expect(roadItem['tracks'][0], {'sync': 'Rock/a.mp3'});
      expect(roadItem['tracks'][1]['yt']['id'], 'abcdefghijk');
      expect(items['liked']['v']['tracks'], [
        {'sync': 'Rock/a.mp3'},
      ]);
      final (_, filesThere) = await mac('GET', '/sync/files', token: token);
      expect((filesThere['files'] as List).map((f) => f['path']).toSet(), {
        'Rock/a.mp3',
        'Pop/b.mp3',
      });
      final aSha = sha1.convert(File(a.path).readAsBytesSync()).toString();
      final (_, aBytes) = await mac('GET', '/sync/blobs/$aSha', token: token);
      expect(aBytes, File(a.path).readAsBytesSync());

      // The Mac makes a playlist, adds a song, deletes one, plays something.
      final now = DateTime.now().millisecondsSinceEpoch + 1000;
      items['p:frommac'] = {
        't': now,
        'v': {
          'name': 'From Mac',
          'tracks': [
            {'sync': 'Jazz/c.mp3'},
            {'sync': 'Pop/b.mp3'},
          ],
        },
      };
      final (put, _) = await mac(
        'PUT',
        '/sync/state/library',
        token: token,
        body: {
          'rev': state['rev'],
          'data': {'v': 1, 'items': items},
        },
      );
      expect(put, 200);
      final song = utf8.encode('cccc' * 1000);
      final cSha = sha1.convert(song).toString();
      expect(
        (await mac('PUT', '/sync/blobs/$cSha', token: token, raw: song)).$1,
        200,
      );
      expect(
        (await mac(
          'POST',
          '/sync/files',
          token: token,
          body: {
            'add': [
              {'path': 'Jazz/c.mp3', 'sha1': cSha, 'size': song.length},
            ],
            'delete': ['Rock/a.mp3'],
          },
        )).$1,
        200,
      );
      await mac(
        'PUT',
        '/sync/state/playback',
        token: token,
        body: {
          'rev': 0,
          'data': {
            'track': {'sync': 'Pop/b.mp3'},
            'pos': 42000,
            'playing': false,
            'playlist': null,
            't': now,
            'device': 'mac-device-0001',
            'name': 'Mac',
          },
        },
      );

      await sync.syncNow();
      expect(sync.lastError, isNull);
      // The Mac's song is here, in the same folder; the deleted one is gone.
      expect(File(p.join(music.path, 'Jazz', 'c.mp3')).readAsBytesSync(), song);
      expect(File(p.join(music.path, 'Rock', 'a.mp3')).existsSync(), isFalse);
      // Its playlist is here, finding the downloaded song.
      final fromMac = library.custom.firstWhere((pl) => pl.name == 'From Mac');
      expect(fromMac.tracks.map((t) => p.basename(t.path)), ['c.mp3', 'b.mp3']);
      // What it played is ready to carry on, where it got to.
      expect(PlayerService.instance.currentTrack?.path, endsWith('b.mp3'));
      expect(
        PlayerService.instance.player.position,
        const Duration(seconds: 42),
      );
      expect(sync.handoff.value, 'Mac');

      // The Mac plays on: this device, idle, follows where it's got to.
      final (_, latest) = await mac(
        'GET',
        '/sync/state/playback',
        token: token,
      );
      await mac(
        'PUT',
        '/sync/state/playback',
        token: token,
        body: {
          'rev': latest['rev'],
          'data': {
            'track': {'sync': 'Pop/b.mp3'},
            'pos': 90000,
            'playing': false,
            'playlist': null,
            't': now,
            'at': now + 5000,
            'device': 'mac-device-0001',
            'name': 'Mac',
          },
        },
      );
      await sync.syncNow();
      expect(PlayerService.instance.currentTrack?.path, endsWith('b.mp3'));
      expect(
        PlayerService.instance.player.position,
        const Duration(seconds: 90),
      );
    },
    skip: runnable ? false : 'no backend here',
  );
}
