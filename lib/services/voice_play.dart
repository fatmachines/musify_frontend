import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/playlist.dart';
import 'app_log.dart';
import 'library.dart';
import 'library_search.dart';
import 'metadata_service.dart';
import 'player_service.dart';

/// What a voice request names, when the assistant says.
enum VoiceKind { any, song, playlist, artist, album }

/// "Play X on Musify" from Siri (iOS, over the musify/siri channel; see
/// SiriBridge in ios/Runner/AppDelegate.swift) and Google Assistant /
/// Android Auto (through the audio handler's playFromSearch).
class VoicePlay {
  static const _channel = MethodChannel('musify/siri');
  static Timer? _vocabularySoon;

  static const _likedNames = {
    'liked songs',
    'liked',
    'my liked songs',
    'likes',
    'my likes',
    'liked music',
    'favorites',
    'favourites',
    'my favorites',
    'my favourites',
  };

  /// iOS: takes Siri's requests (some may be waiting from before the app
  /// started) and teaches Siri the library's playlist and artist names.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'play') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      AppLog.add('voice: from Siri $args');
      return play(
        args['query'] as String?,
        artist: args['artist'] as String?,
        kind: VoiceKind.values.asNameMap()[args['type']] ?? VoiceKind.any,
        shuffle: args['shuffle'] as bool?,
      );
    });
    // The native side may register its channel just after Dart starts.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await _channel.invokeMethod('ready');
        AppLog.add('voice: Siri channel ready');
        break;
      } on MissingPluginException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        AppLog.add('voice: ready failed: $e');
        break;
      }
    }
    final library = Library.instance;
    await library.ensureLoaded();
    library.addListener(_sendVocabularyLater);
    await _sendVocabulary();
  }

  static void _sendVocabularyLater() {
    _vocabularySoon?.cancel();
    _vocabularySoon = Timer(const Duration(seconds: 2), _sendVocabulary);
  }

  static Future<void> _sendVocabulary() async {
    final library = Library.instance;
    await MetadataService.loadInfo(library.allSongs);
    final artists = <String>{
      for (final track in library.allSongs)
        ?MetadataService.cachedInfo(track)?.artist,
    };
    try {
      await _channel.invokeMethod('vocabulary', {
        'playlists': [for (final p in library.all) p.name],
        'artists': artists.toList(),
      });
    } catch (e) {
      AppLog.add('voice: vocabulary failed: $e');
    }
  }

  /// Plays what was asked for. With nothing named, carries on with what was
  /// playing, or shuffles Liked Songs (or the first playlist). Returns
  /// whether something started.
  static Future<bool> play(
    String? query, {
    String? artist,
    VoiceKind kind = VoiceKind.any,
    bool? shuffle,
  }) async {
    final library = Library.instance;
    final player = PlayerService.instance;
    await library.ensureLoaded();
    await MetadataService.loadInfo(library.allSongs);
    final q = (query ?? '').trim();
    final by = (artist ?? '').trim();
    AppLog.add('voice: "$q" artist="$by" kind=${kind.name} shuffle=$shuffle');

    Future<bool> start(Playlist playlist, {required bool shuffled}) async {
      if (playlist.tracks.isEmpty) return false;
      await player.play(playlist, shuffle: shuffled);
      return true;
    }

    if (q.isEmpty && by.isEmpty) {
      if (player.currentTrack != null) {
        if (shuffle != null) await player.setShuffle(shuffle);
        player.player.play();
        return true;
      }
      final fallback = library.liked.tracks.isNotEmpty
          ? library.liked
          : library.all.where((p) => p.tracks.isNotEmpty).firstOrNull;
      if (fallback == null) return false;
      return start(fallback, shuffled: shuffle ?? true);
    }

    if (_likedNames.contains(q.toLowerCase())) {
      return start(library.liked, shuffled: shuffle ?? false);
    }

    if (kind == VoiceKind.artist || (q.isEmpty && by.isNotEmpty)) {
      if (await _playArtist(q.isEmpty ? by : q, shuffle: shuffle ?? true)) {
        return true;
      }
    }

    final playlists = LibrarySearch.playlists(_withoutPlaylistWords(q));
    final exactPlaylist = playlists
        .where((p) => p.name.toLowerCase() == _withoutPlaylistWords(q))
        .firstOrNull;
    if (kind == VoiceKind.playlist || exactPlaylist != null) {
      final playlist = exactPlaylist ?? playlists.firstOrNull;
      if (playlist != null) {
        return start(playlist, shuffled: shuffle ?? false);
      }
    }

    var songs = LibrarySearch.songs(q, artist: by.isEmpty ? null : by);
    if (songs.isEmpty && by.isNotEmpty) songs = LibrarySearch.songs(q);
    if (songs.isNotEmpty) return player.playSong(songs.first, shuffle: shuffle);

    // Maybe it was an artist or a playlist after all.
    if (await _playArtist(q, shuffle: shuffle ?? true)) return true;
    if (playlists.isNotEmpty) {
      return start(playlists.first, shuffled: shuffle ?? false);
    }
    AppLog.add('voice: nothing matched');
    return false;
  }

  static Future<bool> _playArtist(String name, {required bool shuffle}) async {
    final songs = LibrarySearch.byArtist(name);
    if (songs.isEmpty) return false;
    await PlayerService.instance.play(
      Playlist(id: 'artist:${name.toLowerCase()}', name: name, tracks: songs),
      shuffle: shuffle,
    );
    return true;
  }

  /// "the Travel playlist", "my road trip playlist" → the name itself.
  static String _withoutPlaylistWords(String query) => query
      .toLowerCase()
      .replaceAll(RegExp(r'^(my|the)\s+'), '')
      .replaceAll(RegExp(r'\s+playlist$'), '')
      .trim();
}
