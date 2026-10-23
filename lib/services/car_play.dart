import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/playlist.dart';
import '../tabs/home_tab.dart';
import '../widgets/download_sheet.dart';
import 'app_log.dart';
import 'cover_files.dart';
import 'downloads.dart';
import 'library.dart';
import 'local_copies.dart';
import 'metadata_service.dart';
import 'musify_server.dart';
import 'player_service.dart';

/// CarPlay's screens (iOS), laid out like Spotify's, drawn by
/// CarPlaySceneDelegate in ios/Runner/AppDelegate.swift: Home, Recently
/// Played, Your Library, and each playlist's songs. This side hands over
/// the lists, over the musify/carplay channel.
///
/// Each entry is a map: id, title, subtitle, playable (a song, or opens a
/// list), art ('liked', 'tag', 'folder', 'playlist', 'song'), color (a
/// tag's), and images: cover files (up to four, for the mosaic).
class CarPlay {
  static const _channel = MethodChannel('musify/carplay');
  static const _recentKey = 'carplay_recent';

  /// Songs shown with their covers in a playlist (reading covers is slow).
  static const _coveredSongs = 100;

  static Timer? _changedSoon;
  static List<String> _recent = [];

  static Future<void> init(AudioHandler handler) async {
    if (!Platform.isIOS) return;
    try {
      _recent =
          (await SharedPreferences.getInstance()).getStringList(_recentKey) ??
          [];
    } catch (_) {}
    _channel.setMethodCallHandler((call) async {
      try {
        return await _handle(call, handler);
      } catch (e) {
        AppLog.add('carplay: ${call.method} failed: $e');
        rethrow;
      }
    });
    // The native side may register its channel just after Dart starts.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await _channel.invokeMethod('ready');
        break;
      } on MissingPluginException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        AppLog.add('carplay: ready failed: $e');
        break;
      }
    }
    Library.instance.addListener(_changedLater);
    String? shownId;
    handler.mediaItem.listen((item) {
      _notePlayed();
      if (item?.id == shownId) return;
      shownId = item?.id;
      _changedLater();
    });
  }

  static Future<Object?> _handle(MethodCall call, AudioHandler handler) async {
    final library = Library.instance;
    await library.ensureLoaded();
    switch (call.method) {
      case 'home':
        return _home();
      case 'recent':
        return Future.wait(_recentPlaylists().map(_playlistEntry));
      case 'library':
        final (playlists, folders, tags) = _library();
        return {
          'playlists': await Future.wait(playlists.map(_playlistEntry)),
          'folders': await Future.wait(folders.map(_playlistEntry)),
          'tags': await Future.wait(tags.map(_playlistEntry)),
        };
      case 'children':
        final playlist = library.byId(call.arguments as String);
        if (playlist == null) return const [];
        final tracks = playlist.tracks;
        await MetadataService.loadInfo(tracks);
        return Future.wait([
          for (var i = 0; i < tracks.length; i++)
            _songEntry(tracks[i], withCover: i < _coveredSongs),
        ]);
      case 'queue':
        return _queue();
      case 'jump':
        await PlayerService.instance.player.seek(
          Duration.zero,
          index: call.arguments as int,
        );
        return null;
      case 'addTargets':
        return _addTargets();
      case 'toggleInPlaylist':
        return _toggleInPlaylist(call.arguments as String);
      case 'tags':
        return _tags();
      case 'toggleTag':
        return _toggleTag(call.arguments as String);
      case 'downloadTargets':
        return _downloadTargets();
      case 'download':
        return _download(call.arguments as String);
      case 'play':
        final args = (call.arguments as Map).cast<String, Object?>();
        final id = args['id'] as String;
        final playlistId = args['playlist'] as String?;
        AppLog.add('carplay: play $id in $playlistId');
        final playlist = playlistId == null ? null : library.byId(playlistId);
        if (playlist == null) {
          await handler.playFromMediaId(id);
          return null;
        }
        final player = PlayerService.instance;
        final index = playlist.tracks.indexWhere((t) => t.path == id);
        await player.play(
          playlist,
          shuffle: args['shuffle'] as bool? ?? player.shuffleOn.value,
          startIndex: index >= 0 ? index : null,
        );
        return null;
    }
    return null;
  }

  // Now Playing's buttons ---------------------------------------------------

  /// Up Next: the queue, then the rest of the playlist; ids are positions
  /// in the player's sequence (for 'jump').
  static Future<Map<String, Object?>> _queue() async {
    final player = PlayerService.instance.player;
    final state = player.sequenceState;
    final sequence = state.sequence;
    final current = state.currentIndex ?? -1;
    final queued = <(int, Track)>[];
    final rest = <(int, Track)>[];
    for (var i = current + 1; i < sequence.length && rest.length < 100; i++) {
      final track = sequence[i].tag;
      if (track is QueuedTrack) {
        queued.add((i, track));
      } else if (track is Track) {
        rest.add((i, track));
      }
    }
    Future<List<Map<String, Object?>>> entries(List<(int, Track)> list) async {
      await MetadataService.loadInfo([for (final (_, t) in list) t]);
      return Future.wait([
        for (final (k, (i, t)) in list.indexed)
          _songEntry(t, withCover: k < 30).then((e) => {...e, 'id': '$i'}),
      ]);
    }

    return {
      'queued': await entries(queued),
      'rest': await entries(rest),
      'from': PlayerService.instance.current?.name,
    };
  }

  static Track? _playingTrack() => PlayerService.instance.currentTrack;

  static Future<Map<String, Object?>> _addTargets() async {
    final track = _playingTrack();
    final library = Library.instance;
    if (track == null) return {'note': 'Nothing is playing'};
    final playlists = library.custom;
    if (playlists.isEmpty) {
      return {'note': 'Make a playlist in Musify on your iPhone first'};
    }
    return {
      'items': await Future.wait([
        for (final playlist in playlists)
          _playlistEntry(playlist)
              .then((e) => {...e, 'on': library.contains(playlist, track)}),
      ]),
    };
  }

  static bool _toggleInPlaylist(String id) {
    final track = _playingTrack();
    final library = Library.instance;
    final playlist = library.byId(id);
    if (track == null || playlist == null) return false;
    if (library.contains(playlist, track)) {
      library.removeTrack(playlist, track);
      return false;
    }
    library.addTrack(playlist, track);
    return true;
  }

  static Map<String, Object?> _tags() {
    final track = _playingTrack();
    final library = Library.instance;
    if (track == null) return {'note': 'Nothing is playing'};
    if (track is YouTubeTrack) {
      return {'note': 'YouTube songs can be tagged once downloaded'};
    }
    if (library.tags.isEmpty) {
      return {'note': 'Make a tag in Musify on your iPhone first'};
    }
    return {
      'items': [
        for (final tag in library.tags)
          {
            'id': tag.id,
            'title': tag.name,
            'art': 'tag',
            'color': tag.color.toARGB32(),
            'on': library.hasTag(track, tag),
          },
      ],
    };
  }

  static bool _toggleTag(String id) {
    final track = _playingTrack();
    final library = Library.instance;
    final tag = library.tags.where((t) => t.id == id).firstOrNull;
    if (track == null || tag == null) return false;
    library.toggleTag(track, tag);
    return library.hasTag(track, tag);
  }

  static Future<Map<String, Object?>> _downloadTargets() async {
    final track = _playingTrack();
    if (track is! YouTubeTrack) {
      return {
        'note': track == null
            ? 'Nothing is playing'
            : 'This song is already on your iPhone',
      };
    }
    final copy = LocalCopies.instance.copyOf(track);
    if (copy != null) {
      return {'note': 'Downloaded: plays from ${p.basename(copy.path)}'};
    }
    if (Downloads.instance.isQueued(track)) {
      return {'note': 'Already downloading'};
    }
    if (!await MusifyServer.instance.isSetUp()) {
      return {'note': 'Set up your Musify server in Settings first'};
    }
    final folders = downloadFolders();
    if (folders.isEmpty) {
      return {'note': 'Add a music folder in Musify on your iPhone first'};
    }
    final last = await Downloads.lastFolder();
    folders.sort((a, b) => (a.path == last ? 0 : 1) - (b.path == last ? 0 : 1));
    return {
      'items': [
        for (final folder in folders)
          {
            'id': folder.path,
            'title': folder.name,
            'subtitle': folder.within,
            'art': 'folder',
          },
      ],
    };
  }

  /// Starts the download; returns what to tell the driver.
  static String _download(String folder) {
    final track = _playingTrack();
    if (track is! YouTubeTrack) return 'Nothing to download';
    final downloads = Downloads.instance;
    final message = downloads.current == null
        ? 'Downloading ${track.name} to ${p.basename(folder)}'
        : 'Will download after the current song';
    downloads.download(
      track,
      folder,
      onDone: (file, error) => AppLog.add(
        'carplay: download ${file == null ? 'failed: $error' : 'saved'}',
      ),
    );
    return message;
  }

  static List<Playlist> _recentPlaylists() => [
    for (final id in _recent) ?Library.instance.byId(id),
  ];

  /// Your Library: Liked Songs and the user's playlists, folders, tags.
  static (List<Playlist>, List<Playlist>, List<Playlist>) _library() {
    final library = Library.instance;
    return (
      [
        for (final p in library.all)
          if (p.location == null) p,
      ],
      [
        for (final p in library.all)
          if (p.location != null) p,
      ],
      [
        for (final tag in library.tags)
          if (library.tagPlaylist(tag) case final p when p.tracks.isNotEmpty) p,
      ],
    );
  }

  /// Spotify's car Home: the greeting over a row of recent covers, then
  /// what's pinned, the user's playlists and folders. (Now Playing is
  /// CarPlay's own button, top right.)
  static Future<Map<String, Object?>> _home() async {
    final library = Library.instance;
    final (playlists, folders, _) = _library();
    var recent = _recentPlaylists();
    if (recent.isEmpty) {
      // Nothing played yet: the library's first ones instead.
      recent = library.all.where((p) => p.tracks.isNotEmpty).toList();
    }
    Future<List<Map<String, Object?>>> entries(Iterable<Playlist> list) =>
        Future.wait(list.take(8).map(_playlistEntry));
    return {
      'greeting': HomeTab.greeting(),
      'recent': await entries(recent),
      'pinned': await entries(library.pinned),
      'playlists': await entries(playlists),
      'folders': await entries(folders),
    };
  }

  static Future<Map<String, Object?>> _playlistEntry(Playlist playlist) async {
    final library = Library.instance;
    final isTag = Library.isSystem(playlist) && playlist.id != Library.likedId;
    final tag = isTag
        ? library.tags
              .where((t) => playlist.id.endsWith(':${t.id}'))
              .firstOrNull
        : null;
    final art = playlist.id == Library.likedId
        ? 'liked'
        : isTag
        ? 'tag'
        : playlist.location != null
        ? 'folder'
        : 'playlist';
    final count = playlist.tracks.length;
    return {
      'id': playlist.id,
      'title': playlist.name,
      'subtitle': count == 1 ? '1 song' : '$count songs',
      'playable': false,
      'art': art,
      'color': ?tag?.color.toARGB32(),
      'images': art == 'liked' || art == 'tag'
          ? const <String>[]
          : await _playlistCovers(playlist),
    };
  }

  static Future<Map<String, Object?>> _songEntry(
    Track track, {
    required bool withCover,
  }) async {
    final info = MetadataService.cachedInfo(track);
    final cover = withCover ? await CoverFiles.uriFor(track) : null;
    return {
      'id': track.path,
      'title': info?.title ?? track.title,
      'subtitle': info?.artist,
      'playable': true,
      'art': 'song',
      'images': [?cover?.toFilePath()],
    };
  }

  static final _coverPaths = <String, Future<String?>>{};

  /// The playlist's mosaic covers (as in the app), written out as files.
  static Future<List<String>> _playlistCovers(Playlist playlist) async {
    final covers = await MetadataService.playlistCovers(playlist);
    final paths = await Future.wait([
      for (var i = 0; i < covers.length && i < 4; i++)
        _coverPaths.putIfAbsent(
          '${playlist.id}#$i#${covers[i].length}',
          () => _write(covers[i]),
        ),
    ]);
    return [for (final path in paths) ?path];
  }

  static var _written = 0;

  static Future<String?> _write(Uint8List bytes) async {
    final name = '${_written++}.jpg';
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'carplay'),
      );
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Keeps Recently Played: the library playlists played, latest first.
  static void _notePlayed() {
    final current = PlayerService.instance.current;
    if (current == null || Library.instance.byId(current.id) == null) return;
    if (_recent.firstOrNull == current.id) return;
    _recent = [
      current.id,
      ..._recent.where((id) => id != current.id),
    ].take(12).toList();
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setStringList(_recentKey, _recent))
        .catchError((Object _) => false);
    _changedLater();
  }

  /// Refreshes the car's lists after library edits or a new song.
  static void _changedLater() {
    _changedSoon?.cancel();
    _changedSoon = Timer(const Duration(seconds: 1), () {
      _channel.invokeMethod('changed').catchError((Object e) {
        AppLog.add('carplay: changed failed: $e');
      });
    });
  }
}
