import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import 'app_log.dart';

/// Musify's server (the musify_backend repo): downloads YouTube songs and
/// reads YouTube playlists with yt-dlp, which the phone can't do itself.
///
/// Everyone runs their own: its address and key are entered once in the app
/// (Your Library ⋮ → Musify server), or built in with
/// --dart-define=MUSIFY_SERVER=https://... --dart-define=MUSIFY_KEY=...
class MusifyServer extends ChangeNotifier {
  MusifyServer._();

  static final instance = MusifyServer._();

  static const _urlKey = 'musify_server_url';
  static const _keyKey = 'musify_server_key';
  static const _builtInUrl = String.fromEnvironment('MUSIFY_SERVER');
  static const _builtInKey = String.fromEnvironment('MUSIFY_KEY');

  String? _url;
  String? _key;
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _url = prefs.getString(_urlKey);
    _key = prefs.getString(_keyKey);
    _loaded = true;
  }

  /// The server's address, e.g. https://musify.example.com, or null.
  Future<String?> url() async {
    await _load();
    return _url ?? (_builtInUrl.isEmpty ? null : _builtInUrl);
  }

  Future<String?> key() async {
    await _load();
    return _key ?? (_builtInKey.isEmpty ? null : _builtInKey);
  }

  /// Whether there's an address and a key to use.
  Future<bool> isSetUp() async => await url() != null && await key() != null;

  /// The address, known without waiting once loaded (see [url]); for
  /// screens, which mustn't flicker while it's read.
  String? get urlNow => _url ?? (_builtInUrl.isEmpty ? null : _builtInUrl);

  bool get setUpNow =>
      urlNow != null &&
      (_key ?? (_builtInKey.isEmpty ? null : _builtInKey)) != null;

  /// Where [track] streams from the server, or null without one. The key
  /// goes in the address: the system's player can't send headers.
  Uri? streamUri(YouTubeTrack track) {
    final base = urlNow;
    final key = _key ?? (_builtInKey.isEmpty ? null : _builtInKey);
    if (base == null || key == null) return null;
    return Uri.parse('$base/audio/${track.videoId}.m4a')
        .replace(queryParameters: {'key': key});
  }

  /// Songs the server has fetched (this run), and ones it's fetching.
  final _ready = <String>{};
  final _fetching = <String, Future<bool>>{};

  /// Whether the server has [track], so it streams straight away.
  bool isReady(YouTubeTrack track) => _ready.contains(track.videoId);

  /// Has the server fetch [track] from YouTube: a few seconds, or at once
  /// if it has it already. True once it's there to stream; false if the
  /// server couldn't get it (or there's no server).
  Future<bool> warm(YouTubeTrack track) {
    final id = track.videoId;
    if (_ready.contains(id)) return Future.value(true);
    final uri = streamUri(track);
    if (uri == null) return Future.value(false);
    return _fetching.putIfAbsent(id, () async {
      try {
        final response = await http
            .get(uri, headers: {'Range': 'bytes=0-0'})
            .timeout(const Duration(minutes: 2));
        final ok = response.statusCode == 206 || response.statusCode == 200;
        if (ok) _ready.add(id);
        return ok;
      } catch (_) {
        return false;
      } finally {
        _fetching.remove(id);
      }
    });
  }

  /// Marks [videoId] as fetched, for tests.
  @visibleForTesting
  void debugReady(String videoId) => _ready.add(videoId);

  /// Reads the saved address and key (once).
  Future<void> load() => _load();

  /// Saves the address and key (null or empty clears them).
  Future<void> setUp(String? url, String? key) async {
    final prefs = await SharedPreferences.getInstance();
    var address = url?.trim() ?? '';
    if (address.isNotEmpty && !address.contains('://')) {
      address = 'https://$address';
    }
    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }
    final secret = key?.trim() ?? '';
    Future<void> put(String name, String value) =>
        value.isEmpty ? prefs.remove(name) : prefs.setString(name, value);
    await put(_urlKey, address);
    await put(_keyKey, secret);
    _url = address.isEmpty ? null : address;
    _key = secret.isEmpty ? null : secret;
    _loaded = true;
    _charts = null;
    notifyListeners();
  }

  Future<String> _base() async {
    final address = await url();
    if (address == null) {
      throw const ServerError('Set up a Musify server first');
    }
    return address;
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
        .get(Uri.parse('${await _base()}/health'), headers: await _headers())
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ServerError(_errorOf(response, response.body));
    }
    return (jsonDecode(response.body) as Map)['ytdlp'] as String;
  }

  // Sync ----------------------------------------------------------------------

  /// A request for sync (see SyncService): its status and JSON answer.
  /// [token] is this device's sync token.
  Future<(int, Map<String, dynamic>)> syncCall(
    String method,
    String path, {
    Object? body,
    String? token,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = http.Request(method, await syncUri(path))
      ..headers.addAll(await syncHeaders(token));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(timeout),
    );
    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      data = {'error': 'the server answered ${response.statusCode}'};
    }
    return (response.statusCode, data);
  }

  Future<Uri> syncUri(String path) async => Uri.parse('${await _base()}$path');

  Future<Map<String, String>> syncHeaders(String? token) async => {
    ...await _headers(),
    'X-Musify-Sync': ?token,
  };

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
        .get(Uri.parse('${await _base()}/charts'), headers: await _headers())
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

  (YouTubeArtist?, List<YouTubeTrack>)? _debugSearch;
  (Playlist, List<YouTubeAlbum>)? _debugArtist;

  /// Sets the charts and key without the server, for screenshots and tests.
  @visibleForTesting
  void debugUse({
    required String key,
    required List<Playlist> charts,
    (YouTubeArtist?, List<YouTubeTrack>)? search,
    (Playlist, List<YouTubeAlbum>)? artist,
  }) {
    _debugSearch = search;
    _debugArtist = artist;
    _url = 'https://musify.example.com';
    _key = key;
    _loaded = true;
    _charts = charts;
    _chartsAt = DateTime.now();
  }

  static Playlist _playlist(Map<String, dynamic> json) => Playlist(
    id: 'youtube:${json['id']}',
    name: json['title'] as String? ?? 'YouTube playlist',
    tracks: _tracks(json['tracks']),
  );

  static List<YouTubeTrack> _tracks(Object? list) => [
    if (list is List)
      for (final t in list)
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
            album: t['album'] as String?,
          ),
  ];

  static YouTubeArtist? _artist(Object? json) => json is Map
      ? YouTubeArtist(
          id: json['id'] as String,
          name: json['name'] as String? ?? '',
          thumbnail: json['thumbnail'] as String?,
        )
      : null;

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final response = await http
        .get(Uri.parse('${await _base()}$path'), headers: await _headers())
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw ServerError(_errorOf(response, response.body));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// The YouTube (or YouTube Music) playlist [id], with its songs. Long
  /// ones take the server a while to read.
  Future<Playlist> youtubePlaylist(String id) async => _playlist(
    await _getJson(
      '/playlist?id=${Uri.encodeQueryComponent(id)}',
      timeout: const Duration(minutes: 2),
    ),
  );

  /// A public Spotify playlist, each song found on YouTube Music, and the
  /// songs that couldn't be ("Title – Artist"). Takes the server a while:
  /// a few seconds per 50 songs.
  Future<(Playlist, List<String>)> spotifyPlaylist(String id) async {
    final data = await _getJson(
      '/spotify?id=${Uri.encodeQueryComponent(id)}',
      timeout: const Duration(minutes: 10),
    );
    return (
      _playlist(data),
      [for (final m in (data['missing'] as List?) ?? const []) '$m'],
    );
  }

  /// The playlist id in a Spotify link (`open.spotify.com/playlist/<id>`, or
  /// `spotify:playlist:<id>`), or null.
  static String? spotifyPlaylistIdOf(String text) => RegExp(
    r'(?:open\.spotify\.com/(?:[a-z-]+/)?playlist/|spotify:playlist:)([A-Za-z0-9]{22})',
  ).firstMatch(text)?.group(1);

  /// The playlist id in a YouTube or YouTube Music link ("...?list=PL..."),
  /// or a bare id; null if there's none.
  static String? playlistIdOf(String text) {
    final trimmed = text.trim();
    final id = RegExp(r'^[A-Za-z0-9_-]{10,64}$');
    if (id.hasMatch(trimmed)) return trimmed;
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    final list = uri?.queryParameters['list'];
    return list != null && id.hasMatch(list) ? list : null;
  }

  /// YouTube Music's songs for [query] (no videos or mixes), and the
  /// artist when the query is their name.
  Future<(YouTubeArtist?, List<YouTubeTrack>)> search(String query) async {
    if (_debugSearch case final found?) return found;
    final data = await _getJson('/search?q=${Uri.encodeQueryComponent(query)}');
    return (_artist(data['artist']), _tracks(data['songs']));
  }

  /// [artist]'s songs, all of them, as a playlist with their picture, and
  /// their albums, newest first.
  Future<(Playlist, List<YouTubeAlbum>)> artist(YouTubeArtist artist) async {
    if (_debugArtist case final found?) return found;
    final data = await _getJson(
      '/artist?id=${Uri.encodeQueryComponent(artist.id)}',
    );
    final songs = Playlist(
      id: artist.playlistId,
      name: data['name'] as String? ?? artist.name,
      tracks: _tracks(data['tracks']),
      artworkUrl: data['thumbnail'] as String? ?? artist.thumbnail,
    );
    final albums = [
      if (data['albums'] case final List list)
        for (final a in list)
          if (a case {'id': final String id})
            YouTubeAlbum(
              id: id,
              title: a['title'] as String? ?? '',
              year: a['year'] as String?,
              thumbnail: a['thumbnail'] as String?,
            ),
    ];
    return (songs, albums);
  }

  /// [album]'s songs as a playlist with its cover.
  Future<Playlist> album(YouTubeAlbum album) async {
    final data = await _getJson(
      '/album?id=${Uri.encodeQueryComponent(album.id)}',
    );
    return Playlist(
      id: album.playlistId,
      name: data['title'] as String? ?? album.title,
      tracks: _tracks(data['tracks']),
      artworkUrl: data['thumbnail'] as String? ?? album.thumbnail,
    );
  }

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
        Uri.parse('${await _base()}/audio/${track.videoId}.m4a'),
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
