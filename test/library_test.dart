import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/library.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
    expect(library.all.map((pl) => pl.name), ['Pop', 'Rock']);
  });

  test('every added folder contributes its playlists', () async {
    SharedPreferences.setMockInitialValues({
      'library_folders': [first.path, second.path],
    });
    final library = Library.fresh();
    await library.ensureLoaded();
    // Sorted by name, ignoring case.
    expect(library.all.map((pl) => pl.name), [
      p.basename(second.path),
      'Pop',
      'Rock',
    ]);
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
    // User playlists come first.
    expect(library.all.first.id, mix.id);

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
    final song = library.all.single.tracks.single;
    final mix = library.createPlaylist('Mix');
    library.addTrack(mix, song);
    await File(song.path).delete();
    await library.rescan();
    expect(library.byId(mix.id)!.tracks, isEmpty);
  });
}
