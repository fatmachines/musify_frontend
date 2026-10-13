import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Writes title, artist and cover into a fragmented MP4/M4A (as YouTube
/// serves audio), which audio_metadata_reader's writer can't handle.
///
/// The tags live in moov/udta/meta/ilst. Rewriting them changes moov's size,
/// which is only safe when nothing after it is addressed by absolute file
/// position: true of fragmented files whose fragments use
/// default-base-is-moof offsets (sidx offsets are relative too). Other files
/// are left alone and false is returned.
bool writeMp4Tags(
  File file, {
  String? title,
  String? artist,
  Uint8List? cover,
}) {
  final bytes = file.readAsBytesSync();
  final top = _children(bytes, 0, bytes.length);
  final moov = top.where((b) => b.type == 'moov').firstOrNull;
  if (moov == null || moov.header != 8) return false;
  if (!top.any((b) => b.type == 'moof')) return false;
  if (!_fragmentsAreRelative(bytes, top)) return false;

  // Keep any existing items (e.g. the encoder) that we don't replace.
  final kept = <Uint8List>[];
  final oldUdta = _children(
    bytes,
    moov.body,
    moov.end,
  ).where((b) => b.type == 'udta').firstOrNull;
  if (oldUdta != null) {
    for (final meta in _children(bytes, oldUdta.body, oldUdta.end)) {
      if (meta.type != 'meta') continue;
      // meta is a full box: 4 bytes of version and flags first.
      for (final ilst in _children(bytes, meta.body + 4, meta.end)) {
        if (ilst.type != 'ilst') continue;
        for (final item in _children(bytes, ilst.body, ilst.end)) {
          if (!const {'©nam', '©ART', 'covr'}.contains(item.type)) {
            kept.add(bytes.sublist(item.start, item.end));
          }
        }
      }
    }
  }

  final items = [
    ...kept,
    if (title != null) _textItem('©nam', title),
    if (artist != null) _textItem('©ART', artist),
    if (cover != null) _box('covr', [_data(_isPng(cover) ? 14 : 13, cover)]),
  ];
  final hdlr = _fullBox('hdlr', [
    Uint8List(4), // pre_defined
    ascii.encode('mdir'),
    ascii.encode('appl'),
    Uint8List(8), // reserved
    Uint8List(1), // empty name
  ]);
  final udta = _box('udta', [
    _fullBox('meta', [hdlr, _box('ilst', items)]),
  ]);

  // moov's other children, then the new udta.
  final moovBody = BytesBuilder();
  for (final child in _children(bytes, moov.body, moov.end)) {
    if (child.type != 'udta') {
      moovBody.add(bytes.sublist(child.start, child.end));
    }
  }
  moovBody.add(udta);
  final newMoov = _box('moov', [moovBody.takeBytes()]);

  final out = BytesBuilder()
    ..add(bytes.sublist(0, moov.start))
    ..add(newMoov)
    ..add(bytes.sublist(moov.end));
  file.writeAsBytesSync(out.takeBytes(), flush: true);
  return true;
}

class _Box {
  final String type;
  final int start;
  final int header;
  final int end;

  _Box(this.type, this.start, this.header, this.end);

  int get body => start + header;
}

List<_Box> _children(Uint8List bytes, int start, int end) {
  final data = ByteData.sublistView(bytes);
  final boxes = <_Box>[];
  var pos = start;
  while (pos + 8 <= end) {
    var size = data.getUint32(pos);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > end) break;
      size = data.getUint64(pos + 8);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) break;
    final type = latin1.decode(bytes.sublist(pos + 4, pos + 8));
    boxes.add(_Box(type, pos, header, pos + size));
    pos += size;
  }
  return boxes;
}

/// Every fragment's tfhd says offsets are relative to its moof, and none
/// carries an absolute base data offset.
bool _fragmentsAreRelative(Uint8List bytes, List<_Box> top) {
  final data = ByteData.sublistView(bytes);
  for (final moof in top.where((b) => b.type == 'moof')) {
    for (final traf in _children(bytes, moof.body, moof.end)) {
      if (traf.type != 'traf') continue;
      for (final box in _children(bytes, traf.body, traf.end)) {
        if (box.type != 'tfhd') continue;
        final flags = data.getUint32(box.body) & 0xFFFFFF;
        final absoluteBase = flags & 0x1 != 0;
        final relativeToMoof = flags & 0x20000 != 0;
        if (absoluteBase || !relativeToMoof) return false;
      }
    }
  }
  return true;
}

Uint8List _box(String type, List<Uint8List> children) {
  final body = BytesBuilder();
  for (final child in children) {
    body.add(child);
  }
  final content = body.takeBytes();
  final out = ByteData(8 + content.length)..setUint32(0, 8 + content.length);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(4, 8, latin1.encode(type));
  bytes.setRange(8, bytes.length, content);
  return bytes;
}

/// A box with a version byte and three flag bytes (all zero) first.
Uint8List _fullBox(String type, List<Uint8List> children) =>
    _box(type, [Uint8List(4), ...children]);

/// An ilst value: type 1 is UTF-8 text, 13 JPEG, 14 PNG.
Uint8List _data(int kind, Uint8List payload) {
  final head = ByteData(8)..setUint32(0, kind);
  return _box('data', [head.buffer.asUint8List(), payload]);
}

Uint8List _textItem(String type, String value) =>
    _box(type, [_data(1, Uint8List.fromList(utf8.encode(value)))]);

bool _isPng(Uint8List bytes) =>
    bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50;
