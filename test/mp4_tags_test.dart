import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/mp4_tags.dart';

Uint8List box(String type, List<int> body) {
  final size = 8 + body.length;
  return Uint8List.fromList([
    size >> 24 & 0xFF,
    size >> 16 & 0xFF,
    size >> 8 & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...body,
  ]);
}

void main() {
  test('refuses a file that is not fragmented', () {
    final dir = Directory.systemTemp.createTempSync('mp4tags');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/plain.m4a')
      ..writeAsBytesSync([
        ...box('ftyp', 'M4A '.codeUnits),
        ...box('moov', box('mvhd', List.filled(20, 0))),
        ...box('mdat', List.filled(100, 1)),
      ]);
    final before = file.readAsBytesSync();
    expect(writeMp4Tags(file, title: 'x'), isFalse);
    expect(file.readAsBytesSync(), before);
  });

  test('adds tags to a fragmented file, keeping the fragments', () {
    final dir = Directory.systemTemp.createTempSync('mp4tags');
    addTearDown(() => dir.deleteSync(recursive: true));
    // tfhd flags 0x020000: offsets relative to their moof.
    final tfhd = box('tfhd', [0, 0x02, 0x00, 0x00, 0, 0, 0, 1]);
    final fragment = [
      ...box('moof', box('traf', tfhd)),
      ...box('mdat', List.filled(64, 9)),
    ];
    final file = File('${dir.path}/yt.m4a')
      ..writeAsBytesSync([
        ...box('ftyp', 'dash'.codeUnits),
        ...box('moov', box('mvhd', List.filled(20, 0))),
        ...fragment,
      ]);
    expect(writeMp4Tags(file, title: 'Kesariya', artist: 'Arijit'), isTrue);
    final bytes = file.readAsBytesSync();
    final text = String.fromCharCodes(bytes);
    expect(text, contains('udta'));
    expect(text, contains('Kesariya'));
    expect(text, contains('Arijit'));
    // The fragment is untouched, just after the bigger moov.
    expect(bytes.sublist(bytes.length - fragment.length), fragment);
  });
}
