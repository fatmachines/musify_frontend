import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/metadata_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('musify_meta'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'lyrics in a custom ID3 frame (as ffmpeg writes them) are read',
    () async {
      // ffmpeg -metadata lyrics=... writes TXXX:USLT, not a USLT frame.
      final song = Track(
        File('test/fixtures/txxx_lyrics.mp3')
            .copySync(p.join(dir.path, 'a.mp3'))
            .path,
      );
      await MetadataService.loadInfo([song]);
      final info = MetadataService.cachedInfo(song);
      expect(info?.title, 'Lyrical');
      expect(info?.lyrics, 'Hello lyrics line');
    },
  );

  test("a folder's cover.jpg stands in for songs without their own", () async {
    final song = Track(
      File('test/fixtures/txxx_lyrics.mp3')
          .copySync(p.join(dir.path, 'b.mp3'))
          .path,
    );
    final picture = [0xFF, 0xD8, 0xFF, 1, 2, 3];
    File(p.join(dir.path, 'Cover.JPG')).writeAsBytesSync(picture);
    File(p.join(dir.path, 'notes.png')).writeAsBytesSync([9]);
    expect(await MetadataService.cover(song), picture);
  });
}
