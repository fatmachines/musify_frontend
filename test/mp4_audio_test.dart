import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/youtube/mp4_audio.dart';

/// The top-level boxes of an MP4 file, as (type, start, end).
List<(String, int, int)> boxes(Uint8List b) {
  final found = <(String, int, int)>[];
  var at = 0;
  while (at + 8 <= b.length) {
    final size = ByteData.sublistView(b).getUint32(at);
    found.add((String.fromCharCodes(b, at + 4, at + 8), at, at + size));
    at += size;
  }
  return found;
}

void main() {
  // 6 seconds of AAC in 1-second fragments, laid out like YouTube's audio
  // (ffmpeg -movflags frag_keyframe+empty_moov+default_base_moof).
  final fragmented = File('test/fixtures/fragmented.m4a').readAsBytesSync();

  test('fragments become one plain file with tags', () {
    final audio = Mp4Audio.flatten(
      fragmented,
      title: 'Song',
      artist: 'Channel',
      cover: Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]),
    )!;
    expect(audio.duration.inMilliseconds, closeTo(6023, 30));
    expect(audio.gaps, Duration.zero);
    final types = [for (final b in boxes(audio.bytes)) b.$1];
    expect(types, ['ftyp', 'moov', 'mdat']);
    final text = String.fromCharCodes(audio.bytes);
    expect(text, contains('stco'));
    expect(text, isNot(contains('mvex')));
    expect(text, contains('Song'));
    expect(text, contains('Channel'));
  });

  test('repeated and out-of-order fragments are put right', () {
    final parts = boxes(fragmented);
    Iterable<int> bytesOf(int i) =>
        fragmented.sublist(parts[i].$2, parts[i].$3);
    // ftyp, moov, then fragment pairs (moof, mdat) at 2..13.
    final shuffled = Uint8List.fromList([
      ...bytesOf(0),
      ...bytesOf(1),
      for (final i in [4, 5, 2, 3, 2, 3, 6, 7, 8, 9, 10, 11, 12, 13])
        ...bytesOf(i),
    ]);
    final plain = Mp4Audio.flatten(fragmented)!;
    final fixed = Mp4Audio.flatten(shuffled)!;
    expect(fixed.bytes, plain.bytes);
  });

  test('a missing fragment shows as a gap; a cut-off one is dropped', () {
    final parts = boxes(fragmented);
    Iterable<int> bytesOf(int i) =>
        fragmented.sublist(parts[i].$2, parts[i].$3);
    final holey = Uint8List.fromList([
      for (final i in [0, 1, 2, 3, 6, 7, 8, 9, 10, 11]) ...bytesOf(i),
      // Half of the last moof.
      ...bytesOf(12).take(100),
    ]);
    final audio = Mp4Audio.flatten(holey)!;
    expect(audio.gaps.inMilliseconds, closeTo(1000, 50));
    expect(audio.duration.inMilliseconds, closeTo(4000, 100));
  });

  test('no audio setup, no file', () {
    expect(
      Mp4Audio.flatten(Uint8List.fromList([0, 0, 0, 8, 1, 2, 3, 4])),
      isNull,
    );
  });

  test('the library reads its tags and length', () {
    final out = File('${Directory.systemTemp.path}/musify_tags.m4a')
      ..writeAsBytesSync(
        Mp4Audio.flatten(
          fragmented,
          title: 'Song',
          artist: 'Channel',
          cover: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
        )!.bytes,
      );
    addTearDown(out.deleteSync);
    final tags = readMetadata(out, getImage: true);
    expect(tags.title, 'Song');
    expect(tags.artist, 'Channel');
    expect(tags.duration!.inMilliseconds, closeTo(6023, 50));
    expect(tags.pictures, isNotEmpty);
  });

  test('writes a file ffprobe reads', () async {
    final out = File('${Directory.systemTemp.path}/musify_flat.m4a')
      ..writeAsBytesSync(Mp4Audio.flatten(fragmented, title: 'Song')!.bytes);
    addTearDown(out.deleteSync);
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration:format_tags=title',
      '-of',
      'default=nw=1',
      out.path,
    ]);
    if (probe.exitCode == 127) return; // No ffprobe here.
    expect(probe.stdout, contains('TAG:title=Song'));
    expect(probe.stdout, contains('duration=6.0'));
    final decode = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-i',
      out.path,
      '-f',
      'null',
      '-',
    ]);
    expect(decode.stderr, '');
  }, testOn: 'linux || mac-os');
}
