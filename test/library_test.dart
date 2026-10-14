import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/library.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Playlist names, leaving out the permanent Liked Songs.
List<String> names(Library library) => [
  for (final pl in library.all)
    if (pl.id != Library.likedId) pl.name,
];

void main() {
  // Deleting checks the player, which needs Flutter's bindings.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory first;
  late Directory second;

  Future<void> touch(Directory root, String rel) =>
      File(p.join(root.path, rel)).create(recursive: true);

  setUp(() async {
    // Layout 1: songs inside subfolders.
    first = await Directory.systemTemp.createTemp('musify_lib_a');
    await touch(first, 'Rock/a.mp3');
    await touch(first, 'Pop/b.mp3');
    // Layout 2: songs directly in the folder.
    second = await Directory.systemTemp.createTemp('musify_lib_b');
    await touch(second, 'c.mp3');
  });

  tearDown(() async {
    await first.delete(recursive: true);
    await second.delete(recursive: true);
  });

  test('the old single folder carries over', () async {
    SharedPreferences.setMockInitialValues({'library_root_path': first.path});
    final library = Library.fresh();
    await library.ensureLoaded();
    expect(library.folders.map((f) => f.path), [first.path]);
    expect(names(library), ['Pop', 'Rock']);
  });

  test('every added folder contributes its playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path, second.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    // Sorted by name, ignoring case.
    expect(names(library), [p.basename(second.path), 'Pop', 'Rock']);
  });

  test('user playlists mix folders, persist and can be edited', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path, second.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final rock = library.all.firstWhere((pl) => pl.name == 'Rock');
    final loose = library.all.firstWhere((pl) => pl.location == '.');

    var mix = library.createPlaylist('Mix');
    library.addTrack(mix, rock.tracks.single);
    library.addTrack(mix, loose.tracks.single);
    library.addTrack(mix, rock.tracks.single); // already there
    mix = library.byId(mix.id)!;
    expect(mix.isCustom, isTrue);
    expect(mix.tracks.map((t) => p.basename(t.path)), ['a.mp3', 'c.mp3']);
    // Liked Songs, then the user's playlists.
    expect(library.all.map((pl) => pl.id).take(2), [Library.likedId, mix.id]);

    // Saved and read back by a fresh library.
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('custom_playlists_v1')!), hasLength(1));
    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    final again = reloaded.byId(mix.id)!;
    expect(again.tracks.map((t) => p.basename(t.path)), ['a.mp3', 'c.mp3']);

    reloaded.removeTrack(again, const Track('x')); // not in it: no change
    reloaded.removeTrack(again, again.tracks.first);
    reloaded.renamePlaylist(reloaded.byId(mix.id)!, 'Road mix');
    final edited = reloaded.byId(mix.id)!;
    expect(edited.name, 'Road mix');
    expect(edited.tracks.map((t) => p.basename(t.path)), ['c.mp3']);

    reloaded.deletePlaylist(edited);
    expect(reloaded.byId(mix.id), isNull);
    expect(reloaded.custom, isEmpty);
  });

  test('songs that disappeared drop out of user playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [second.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final song = library.all.last.tracks.single;
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, song);
    await File(song.path).delete();
    await library.rescan();
    expect(library.byId(mix.id)!.tracks, isEmpty);
  });

  test('hidden folder playlists stay hidden until shown again', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final rock = library.all.firstWhere((pl) => pl.name == 'Rock');
    library.hidePlaylist(rock);
    expect(names(library), ['Pop']);
    expect(library.hidden.map((pl) => pl.name), ['Rock']);
    expect(library.byId(rock.id), isNull);

    // Remembered across launches and rescans.
    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    expect(names(reloaded), ['Pop']);

    reloaded.unhidePlaylist(reloaded.hidden.single);
    expect(names(reloaded), ['Pop', 'Rock']);
  });

  test('playlists pinned to Home stay pinned, in the order pinned', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final rock = library.all.firstWhere((pl) => pl.name == 'Rock');
    library.togglePin(rock);
    library.togglePin(library.liked);
    library.togglePin(library.tagPlaylist(library.tags.first));
    expect(library.pinned.map((pl) => pl.name), [
      'Rock',
      'Liked Songs',
      library.tags.first.name,
    ]);
    expect(library.isPinned(rock), isTrue);

    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    expect(reloaded.pinned.map((pl) => pl.id), [
      rock.id,
      Library.likedId,
      reloaded.tagPlaylist(reloaded.tags.first).id,
    ]);

    // Hidden folders leave Home; unpinning removes them for good.
    reloaded.hidePlaylist(reloaded.pinned.first);
    expect(reloaded.pinned.map((pl) => pl.id), [
      Library.likedId,
      reloaded.tagPlaylist(reloaded.tags.first).id,
    ]);
    reloaded.togglePin(reloaded.liked);
    expect(reloaded.pinned, hasLength(1));
  });

  test('renaming a folder keeps its songs, pin and playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    await touch(first, 'Rock/Live/l.mp3');
    final library = Library.fresh();
    await library.ensureLoaded();
    final rock = library.all.firstWhere((pl) => pl.name == 'Rock');
    final song = rock.tracks.single;
    library.togglePin(rock);
    library.toggleLike(song);
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, song);
    final live = library.all.firstWhere((pl) => pl.name == 'Live');
    library.hidePlaylist(live);

    expect(await library.renameFolder(rock, 'Pop'), contains('already'));
    expect(await library.renameFolder(rock, 'a/b'), isNotNull);
    expect(await library.renameFolder(rock, 'Classic Rock'), isNull);

    final renamed = p.join(first.path, 'Classic Rock');
    expect(Directory(p.join(first.path, 'Rock')).existsSync(), isFalse);
    expect(File(p.join(renamed, 'a.mp3')).existsSync(), isTrue);
    expect(names(library), ['Mix', 'Classic Rock', 'Pop']);
    expect(library.currentId(rock.id), renamed);
    expect(library.pinned.single.name, 'Classic Rock');
    final moved = p.join(renamed, 'a.mp3');
    expect(library.liked.tracks.single.path, moved);
    expect(library.byId(mix.id)!.tracks.single.path, moved);
    // The folder inside went along, still hidden.
    expect(library.hidden.single.id, p.join(renamed, 'Live'));

    // A folder the user added is renamed in Files instead.
    final top = Library.fresh();
    SharedPreferences.setMockInitialValues({
      'library_folders': [second.path],
    });
    await top.ensureLoaded();
    final root = top.all.firstWhere((pl) => pl.location == '.');
    expect(await top.renameFolder(root, 'New'), contains('Files'));
  });

  test('artists and albums pin to Home and stay pinned', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final artist = Playlist(
      id: 'youtube:artist:UC123',
      name: 'Michael Jackson',
      tracks: [YouTubeTrack(videoId: 'v1', name: 'Billie Jean')],
      artworkUrl: 'https://example.com/mj.jpg',
    );
    expect(Library.isPage(artist), isTrue);
    library.togglePin(artist);
    expect(library.isPinned(artist), isTrue);

    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    final pin = reloaded.pinned.single;
    expect(pin.id, artist.id);
    expect(pin.name, 'Michael Jackson');
    expect(pin.artworkUrl, artist.artworkUrl);
    // Only enough to open the page, which loads the songs.
    expect(pin.tracks, isEmpty);
    reloaded.togglePin(pin);
    expect(reloaded.pinned, isEmpty);
  });

  test('YouTube songs can be liked and put in playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final video = YouTubeTrack(
      videoId: 'abc123',
      name: 'A video',
      channel: 'A channel',
      length: const Duration(minutes: 4),
    );
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, video);
    library.addTrack(mix, library.allSongs.first);
    library.toggleLike(video);
    expect(library.isLiked(video), isTrue);

    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    final liked = reloaded.liked.tracks.single as YouTubeTrack;
    expect(liked.videoId, 'abc123');
    expect(liked.channel, 'A channel');
    expect(liked.length, const Duration(minutes: 4));
    final saved = reloaded.custom.single;
    expect(saved.tracks.first, isA<YouTubeTrack>());
    expect(saved.tracks, hasLength(2));

    reloaded.removeTrack(saved, video);
    reloaded.toggleLike(video);
    expect(reloaded.custom.single.tracks, hasLength(1));
    expect(reloaded.liked.tracks, isEmpty);
  });

  test('moving a song keeps it in its playlists, likes and tags', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final song = library.allSongs.firstWhere((t) => t.path.endsWith('a.mp3'));
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, song);
    library.toggleLike(song);
    library.toggleTag(song, library.tags.first);

    final pop = p.join(first.path, 'Pop');
    final moved = await library.moveSong(song, pop);
    expect(moved, p.join(pop, 'a.mp3'));
    expect(File(song.path).existsSync(), isFalse);
    expect(File(moved!).existsSync(), isTrue);
    expect(library.custom.single.tracks.single.path, moved);
    expect(library.liked.tracks.single.path, moved);
    expect(library.tagPlaylist(library.tags.first).tracks.single.path, moved);
    // It's now in the Pop folder playlist, not Rock's.
    final names = {for (final pl in library.all) pl.name: pl};
    expect(
      names['Pop']!.tracks.map((t) => p.basename(t.path)),
      contains('a.mp3'),
    );
    expect(names.containsKey('Rock'), isFalse, reason: 'Rock is empty now');

    // Remembered after a restart.
    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    expect(reloaded.custom.single.tracks.single.path, moved);
  });

  test('deleting a song removes its file and it leaves playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final song = library.allSongs.firstWhere((t) => t.path.endsWith('a.mp3'));
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, song);
    library.toggleLike(song);
    expect(await library.deleteSong(song), isTrue);
    expect(File(song.path).existsSync(), isFalse);
    expect(library.allSongs.map((t) => t.path), isNot(contains(song.path)));
    expect(library.custom.single.tracks, isEmpty);
    expect(library.liked.tracks, isEmpty);
  });

  test('deleting a folder playlist from the device', () async {
    await touch(first, 'Rock/Classic/d.mp3');
    await touch(first, 'Pop/cover.jpg');
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path, second.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    Playlist named(String name) =>
        library.all.firstWhere((pl) => pl.name == name);

    // Rock's song goes, but Rock stays: its subfolder is another playlist.
    expect(await library.deleteFromDevice(named('Rock')), 1);
    expect(File(p.join(first.path, 'Rock/a.mp3')).existsSync(), isFalse);
    expect(Directory(p.join(first.path, 'Rock')).existsSync(), isTrue);
    expect(names(library), contains('Classic'));
    expect(names(library), isNot(contains('Rock')));

    // Nothing left in Classic, so the folder goes too.
    await library.deleteFromDevice(named('Classic'));
    expect(Directory(p.join(first.path, 'Rock/Classic')).existsSync(), isFalse);

    // Other files keep a folder.
    await library.deleteFromDevice(named('Pop'));
    expect(File(p.join(first.path, 'Pop/cover.jpg')).existsSync(), isTrue);

    // A folder added to the library itself is never removed.
    await library.deleteFromDevice(named(p.basename(second.path)));
    expect(second.existsSync(), isTrue);
    expect(library.folders.map((f) => f.path), contains(second.path));
    expect(names(library), isEmpty);
  });

  test('liked songs: newest first, saved, and removable', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    final rock = library.all.firstWhere((pl) => pl.name == 'Rock');
    final pop = library.all.firstWhere((pl) => pl.name == 'Pop');
    expect(library.all.first.id, Library.likedId);
    expect(library.liked.tracks, isEmpty);

    library.toggleLike(rock.tracks.single);
    library.toggleLike(pop.tracks.single);
    expect(library.isLiked(rock.tracks.single), isTrue);
    expect(library.liked.tracks.map((t) => p.basename(t.path)), [
      'b.mp3',
      'a.mp3',
    ]);

    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    expect(reloaded.liked.tracks.map((t) => p.basename(t.path)), [
      'b.mp3',
      'a.mp3',
    ]);

    // Removing from the Liked Songs playlist unlikes; it can't be deleted.
    reloaded.removeTrack(reloaded.liked, reloaded.liked.tracks.first);
    reloaded.deletePlaylist(reloaded.liked);
    expect(reloaded.byId(Library.likedId), isNotNull);
    expect(reloaded.liked.tracks.map((t) => p.basename(t.path)), ['a.mp3']);
  });

  test('tags: a default to start, toggled per song, saved', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    expect(library.tags.map((t) => t.name), ['To replace']);

    final song = library.all
        .firstWhere((pl) => pl.name == 'Rock')
        .tracks
        .single;
    final replace = library.tags.single;
    final live = library.createTag('Live', const Color(0xFF4FC3F7));
    library.toggleTag(song, replace);
    library.toggleTag(song, live);
    expect(library.tagsOf(song).map((t) => t.name), ['To replace', 'Live']);
    library.toggleTag(song, live);
    expect(library.tagsOf(song).map((t) => t.name), ['To replace']);

    final reloaded = Library.fresh();
    await reloaded.ensureLoaded();
    expect(reloaded.tags.map((t) => t.name), ['To replace', 'Live']);
    expect(reloaded.tagsOf(song).map((t) => t.name), ['To replace']);

    reloaded.deleteTag(reloaded.tags.first);
    expect(reloaded.tags.map((t) => t.name), ['Live']);
    expect(reloaded.tagsOf(song), isEmpty);
  });
}
