import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';

/// Musify's own server (server/ in this repo): downloads YouTube songs and
/// reads YouTube playlists with yt-dlp, which the phone can't do itself.
///
/// It needs a key, entered once in the app (Your Library ⋮ → Musify server)
/// or built in with --dart-define=MUSIFY_KEY=...
class MusifyServer extends ChangeNotifier {
  MusifyServer._();

  static final instance = MusifyServer._();

  static const base = 'https://musify.fatmachines.com';
  static const _keyKey = 'musify_server_key';
  static const _builtInKey = String.fromEnvironment('MUSIFY_KEY');

  String? _key;
  bool _loaded = false;

  Future<String?> key() async {
    if (!_loaded) {
      final prefs = await SharedPreferences.getInstance();
      _key = prefs.getString(_keyKey);
      _loaded = true;
    }
    return _key ?? (_builtInKey.isEmpty ? null : _builtInKey);
  }

  Future<void> setKey(String? key) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = key?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(_keyKey);
      _key = null;
    } else {
      await prefs.setString(_keyKey, trimmed);
      _key = trimmed;
    }
    _loaded = true;
    _charts = null;
    notifyListeners();
  }

  Future<Map<String, String>> _headers() async {
    final key = await this.key();
    if (key == null) throw const ServerError('Add the Musify server key first');
    return {'X-Musify-Key': key};
  }

  static String _errorOf(http.BaseResponse response, String body) {
    if (response.statusCode == 401) return 'the Musify server key is wrong';
    try {
      return (jsonDecode(body) as Map)['error'] as String;
    } catch (_) {
      return 'the server answered ${response.statusCode}';
    }
  }

  /// Checks the key works; returns the server's yt-dlp version.
  Future<String> check() async {
    final response = await http
        .get(Uri.parse('$base/health'), headers: await _headers())
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ServerError(_errorOf(response, response.body));
    }
    return (jsonDecode(response.body) as Map)['ytdlp'] as String;
  }

  // Playlists -----------------------------------------------------------------

  List<Playlist>? _charts;
  DateTime? _chartsAt;

  /// YouTube Music's Top 100 Global, US, UK, Canada, Australia and India,
  /// as playlists of YouTube songs. Fetched at most every half hour.
  Future<List<Playlist>> charts({bool refresh = false}) async {
    final at = _chartsAt;
    if (!refresh &&
        _charts != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 30)) {
      return _charts!;
    }
    final response = await http
        .get(Uri.parse('$base/charts'), headers: await _headers())
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw ServerError(_errorOf(response, response.body));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _charts = [
      for (final chart in data['charts'] as List)
        _playlist(chart as Map<String, dynamic>),
    ];
    _chartsAt = DateTime.now();
    return _charts!;
  }

  List<Playlist>? get cachedCharts => _charts;

  /// Sets the charts and key without the server, for screenshots and tests.
  @visibleForTesting
  void debugUse({required String key, required List<Playlist> charts}) {
    _key = key;
    _loaded = true;
    _charts = charts;
    _chartsAt = DateTime.now();
  }

  static Playlist _playlist(Map<String, dynamic> json) => Playlist(
    id: 'youtube:${json['id']}',
    name: json['title'] as String? ?? 'YouTube playlist',
    tracks: [
      for (final t in json['tracks'] as List)
        if (t case {'id': final String id})
          YouTubeTrack(
            videoId: id,
            name: (t['title'] as String?) ?? id,
            channel: t['channel'] as String?,
            thumbnail:
                (t['thumbnail'] as String?) ??
                'https://i.ytimg.com/vi/$id/hqdefault.jpg',
            length: t['duration'] is num
                ? Duration(seconds: (t['duration'] as num).round())
                : null,
          ),
    ],
  );

  // Songs ---------------------------------------------------------------------

  /// Downloads [track] as a tagged M4A into [file]. [onProgress] gets 0
  /// to 1 (the server first fetches it from YouTube, a few seconds).
  Future<void> download(
    YouTubeTrack track,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    final part = File('${file.path}.part');
    try {
      final request = http.Request(
        'GET',
        Uri.parse('$base/audio/${track.videoId}.m4a'),
      )..headers.addAll(await _headers());
      final response = await client
          .send(request)
          .timeout(const Duration(minutes: 3));
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw ServerError(_errorOf(response, body));
      }
      final total = response.contentLength ?? 0;
      final sink = part.openWrite();
      var done = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          done += chunk.length;
          if (total > 0) onProgress?.call(done / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && done != total) {
        throw const ServerError('the download was cut off');
      }
      await part.rename(file.path);
      AppLog.add('server: ${track.videoId} -> ${file.path} ($done bytes)');
    } catch (e) {
      if (part.existsSync()) part.deleteSync();
      rethrow;
    } finally {
      client.close();
    }
  }
}

class ServerError implements Exception {
  final String message;

  const ServerError(this.message);

  @override
  String toString() => message;
}
