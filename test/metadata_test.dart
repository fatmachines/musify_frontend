import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/metadata_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('musify_meta');
  });

  tearDown(() => dir.delete(recursive: true));

  test("a song with no cover of its own gets its folder's cover.jpg", () async {
    final album = Directory(p.join(dir.path, 'Queen Greatest Hits'))
      ..createSync();
    final song = File(p.join(album.path, '01 Bohemian Rhapsody.mp3'))
      ..writeAsStringSync('not really audio');
    final picture = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
    File(p.join(album.path, 'Cover.JPG')).writeAsBytesSync(picture);

    expect(await MetadataService.cover(Track(song.path)), picture);
  });

  test('a file changed since it was read is read again', () async {
    final song = File(p.join(dir.path, 'Thriller.mp3'))..writeAsStringSync('a');
    await MetadataService.loadInfo([Track(song.path)]);
    expect(MetadataService.cachedInfo(Track(song.path)), isNotNull);
    expect(await MetadataService.forgetChanged(), isEmpty);

    song.writeAsStringSync('a longer file now');
    expect(await MetadataService.forgetChanged(), [song.path]);
    expect(MetadataService.cachedInfo(Track(song.path)), isNull);
  });
}
