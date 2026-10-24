import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/library_scanner.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('musify_scan');
    Future<void> touch(String rel) =>
        File(p.join(root.path, rel)).create(recursive: true);
    await touch('intro.mp3');
    await touch('Rock/b.FLAC');
    await touch('Rock/a.mp3');
    await touch('Rock/cover.jpg');
    await touch('Rock/Classic/c.m4a');
    await touch('Empty/notes.txt');
    await touch('.hidden/d.mp3');
  });

  tearDown(() => root.delete(recursive: true));

  test('each folder with audio becomes a playlist', () async {
    final playlists = (await LibraryScanner.scan(root.path)).playlists;

    expect(playlists.map((pl) => pl.location), [
      '.',
      'Rock',
      p.join('Rock', 'Classic'),
    ]);
    expect(playlists[1].tracks.map((t) => t.title), ['a', 'b']);
    expect(playlists[1].tracks.last.extension, 'FLAC');
  });

  test('songs added later come last; ones added together by name', () async {
    Future<void> add(String name) =>
        File(p.join(root.path, 'New', name)).create(recursive: true);
    await add('m.mp3');
    await add('c.mp3');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await add('a.mp3');
    final playlists = (await LibraryScanner.scan(
      root.path,
      batchGap: const Duration(milliseconds: 100),
    )).playlists;
    final folder = playlists.firstWhere((pl) => pl.location == 'New');
    expect(folder.tracks.map((t) => t.title), ['c', 'm', 'a']);
  });

  test('a download not yet complete is no song', () async {
    final song = File(p.join(root.path, 'Rock', 'Believer.m4a'));
    final part = partFileFor(song);
    expect(p.extension(part.path), '.m4a');
    await part.create();
    final playlists = (await LibraryScanner.scan(root.path)).playlists;
    expect(playlists[1].tracks.map((t) => t.title), ['a', 'b']);
  });

  test('unreadable root is reported instead of looking empty', () async {
    final result = await LibraryScanner.scan(p.join(root.path, 'missing'));
    expect(result.rootError, isNotNull);
    expect(result.playlists, isEmpty);
  });
}
