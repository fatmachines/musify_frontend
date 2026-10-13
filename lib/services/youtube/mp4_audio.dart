import 'dart:convert';
import 'dart:typed_data';

/// Turns fragmented MP4 audio, as YouTube's player feeds it to the browser
/// (an init segment with the track's setup, then fragments of samples),
/// into a plain M4A file that any player reads: one sample table, one
/// block of audio, and title, artist and cover tags. The audio itself is
/// copied as is, not re-encoded.
///
/// [stream] is everything appended for the audio track, in order; it may
/// hold the same fragment twice (the player re-fetches after a seek), so
/// fragments are ordered and de-duplicated by their decode time.
class Mp4Audio {
  /// The rebuilt file.
  final Uint8List bytes;

  /// How long the audio is.
  final Duration duration;

  /// Time missing between fragments (e.g. not every part was captured).
  final Duration gaps;

  const Mp4Audio(this.bytes, this.duration, this.gaps);

  /// Null if [stream] has no audio track setup or no samples.
  static Mp4Audio? flatten(
    Uint8List stream, {
    String? title,
    String? artist,
    Uint8List? cover,
  }) {
    final top = _children(stream, 0, stream.length);

    // Fragments belong to the setup (moov) before them. If the setup
    // changed (another quality), keep the setup with the most audio.
    final groups = <String, _Group>{};
    _Group? group;
    for (final box in top) {
      if (box.type == 'moov') {
        final setup = _Setup.read(stream, box);
        if (setup == null) {
          group = null;
          continue;
        }
        group = groups.putIfAbsent(setup.key, () => _Group(setup));
      } else if (box.type == 'moof' && group != null) {
        for (final fragment in _Fragment.read(stream, box, group.setup)) {
          group.fragments.putIfAbsent(fragment.decodeTime, () => fragment);
        }
      }
    }
    final best = groups.values
        .where((g) => g.fragments.isNotEmpty)
        .fold<_Group?>(
          null,
          (best, g) => best == null || g.length > best.length ? g : best,
        );
    if (best == null) return null;

    final setup = best.setup;
    final fragments = best.fragments.values.toList()
      ..sort((a, b) => a.decodeTime.compareTo(b.decodeTime));

    final sizes = <int>[];
    final durations = <int>[];
    final audio = BytesBuilder(copy: false);
    var gaps = 0;
    var end = fragments.first.decodeTime;
    for (final fragment in fragments) {
      // Overlapping what's already in: a re-fetch at a different split.
      if (fragment.decodeTime < end) continue;
      gaps += fragment.decodeTime - end;
      sizes.addAll(fragment.sizes);
      durations.addAll(fragment.durations);
      audio.add(fragment.data);
      end = fragment.decodeTime + fragment.length;
    }
    final total = durations.fold(0, (a, b) => a + b);
    final data = audio.takeBytes();

    Uint8List moov(int audioAt) => _box('moov', [
      _withDuration(setup.mvhd, total * setup.movieScale ~/ setup.mediaScale),
      _box('trak', [
        _withDuration(setup.tkhd, total * setup.movieScale ~/ setup.mediaScale),
        _box('mdia', [
          _withDuration(setup.mdhd, total),
          setup.hdlr,
          _box('minf', [
            ...setup.minfOthers,
            _box('stbl', [
              setup.stsd,
              _stts(durations),
              // One chunk holding every sample.
              _fullBox('stsc', [_u32(1), _u32(1), _u32(sizes.length), _u32(1)]),
              _fullBox('stsz', [
                _u32(0),
                _u32(sizes.length),
                for (final s in sizes) _u32(s),
              ]),
              _fullBox('stco', [_u32(1), _u32(audioAt)]),
            ]),
          ]),
        ]),
      ]),
      if (title != null || artist != null || cover != null)
        _tags(title: title, artist: artist, cover: cover),
    ]);

    final ftyp = _box('ftyp', [
      ascii.encode('M4A '),
      _u32(0),
      ascii.encode('M4A mp42isom'),
    ]);
    // The chunk offset depends on moov's size, which doesn't depend on it.
    final moovSize = moov(0).length;
    final out = BytesBuilder(copy: false)
      ..add(ftyp)
      ..add(moov(ftyp.length + moovSize + 8))
      ..add(_u32(data.length + 8))
      ..add(ascii.encode('mdat'))
      ..add(data);
    Duration time(int units) =>
        Duration(microseconds: units * 1000000 ~/ setup.mediaScale);
    return Mp4Audio(out.takeBytes(), time(total), time(gaps));
  }
}

class _Group {
  final _Setup setup;
  final fragments = <int, _Fragment>{};

  _Group(this.setup);

  int get length => fragments.values.fold(0, (a, f) => a + f.length);
}

/// The parts of an init segment's moov that the plain file reuses.
class _Setup {
  final Uint8List mvhd;
  final Uint8List tkhd;
  final Uint8List mdhd;
  final Uint8List hdlr;
  final Uint8List stsd;

  /// minf's children other than its sample table (smhd, dinf).
  final List<Uint8List> minfOthers;
  final int trackId;
  final int movieScale;
  final int mediaScale;

  /// Defaults for fragments (trex).
  final int defaultDuration;
  final int defaultSize;

  _Setup({
    required this.mvhd,
    required this.tkhd,
    required this.mdhd,
    required this.hdlr,
    required this.stsd,
    required this.minfOthers,
    required this.trackId,
    required this.movieScale,
    required this.mediaScale,
    required this.defaultDuration,
    required this.defaultSize,
  });

  /// Setups with the same sample description hold compatible samples.
  String get key => base64.encode(stsd);

  static _Setup? read(Uint8List b, _Box moov) {
    final kids = _children(b, moov.body, moov.end);
    final mvhd = _find(kids, 'mvhd');
    // The first sound track.
    for (final trak in kids.where((k) => k.type == 'trak')) {
      final trakKids = _children(b, trak.body, trak.end);
      final tkhd = _find(trakKids, 'tkhd');
      final mdia = _find(trakKids, 'mdia');
      if (mvhd == null || tkhd == null || mdia == null) continue;
      final mdiaKids = _children(b, mdia.body, mdia.end);
      final mdhd = _find(mdiaKids, 'mdhd');
      final hdlr = _find(mdiaKids, 'hdlr');
      final minf = _find(mdiaKids, 'minf');
      if (mdhd == null || hdlr == null || minf == null) continue;
      // hdlr: version/flags, pre_defined, then the handler type.
      if (_type(b, hdlr.body + 8) != 'soun') continue;
      final minfKids = _children(b, minf.body, minf.end);
      final stbl = _find(minfKids, 'stbl');
      if (stbl == null) continue;
      final stsd = _find(_children(b, stbl.body, stbl.end), 'stsd');
      if (stsd == null) continue;

      final trackId = _readU32(b, tkhd.body + (b[tkhd.body] == 1 ? 20 : 12));
      var defaultDuration = 0;
      var defaultSize = 0;
      final mvex = _find(kids, 'mvex');
      if (mvex != null) {
        for (final trex in _children(b, mvex.body, mvex.end)) {
          if (trex.type != 'trex' || _readU32(b, trex.body + 4) != trackId) {
            continue;
          }
          defaultDuration = _readU32(b, trex.body + 12);
          defaultSize = _readU32(b, trex.body + 16);
        }
      }
      return _Setup(
        mvhd: _copy(b, mvhd),
        tkhd: _copy(b, tkhd),
        mdhd: _copy(b, mdhd),
        hdlr: _copy(b, hdlr),
        stsd: _copy(b, stsd),
        minfOthers: [
          for (final k in minfKids)
            if (k.type != 'stbl') _copy(b, k),
        ],
        trackId: trackId,
        movieScale: _timescale(b, mvhd),
        mediaScale: _timescale(b, mdhd),
        defaultDuration: defaultDuration,
        defaultSize: defaultSize,
      );
    }
    return null;
  }
}

/// A run of samples from one moof.
class _Fragment {
  final int decodeTime;
  final List<int> sizes;
  final List<int> durations;
  final Uint8List data;

  _Fragment(this.decodeTime, this.sizes, this.durations, this.data);

  int get length => durations.fold(0, (a, b) => a + b);

  static List<_Fragment> read(Uint8List b, _Box moof, _Setup setup) {
    final found = <_Fragment>[];
    for (final traf in _children(b, moof.body, moof.end)) {
      if (traf.type != 'traf') continue;
      final kids = _children(b, traf.body, traf.end);
      final tfhd = _find(kids, 'tfhd');
      if (tfhd == null || _readU32(b, tfhd.body + 4) != setup.trackId) {
        continue;
      }
      final tfhdFlags = _readU32(b, tfhd.body) & 0xFFFFFF;
      var at = tfhd.body + 8;
      // Absolute offsets can't be followed in a captured stream; data is
      // then taken to start at the moof, as with default-base-is-moof.
      if (tfhdFlags & 0x01 != 0) at += 8;
      if (tfhdFlags & 0x02 != 0) at += 4;
      var defaultDuration = setup.defaultDuration;
      var defaultSize = setup.defaultSize;
      if (tfhdFlags & 0x08 != 0) {
        defaultDuration = _readU32(b, at);
        at += 4;
      }
      if (tfhdFlags & 0x10 != 0) {
        defaultSize = _readU32(b, at);
        at += 4;
      }

      final tfdt = _find(kids, 'tfdt');
      if (tfdt == null) continue;
      var decodeTime = b[tfdt.body] == 1
          ? _readU64(b, tfdt.body + 4)
          : _readU32(b, tfdt.body + 4);

      var dataAt = moof.start;
      var first = true;
      for (final trun in kids.where((k) => k.type == 'trun')) {
        final flags = _readU32(b, trun.body) & 0xFFFFFF;
        final count = _readU32(b, trun.body + 4);
        var p = trun.body + 8;
        if (flags & 0x01 != 0) {
          dataAt = moof.start + _readI32(b, p);
          p += 4;
        } else if (first) {
          dataAt = moof.start;
        }
        first = false;
        if (flags & 0x04 != 0) p += 4;
        final sizes = <int>[];
        final durations = <int>[];
        for (var i = 0; i < count; i++) {
          if (p > trun.end) break;
          var duration = defaultDuration;
          var size = defaultSize;
          if (flags & 0x100 != 0) {
            duration = _readU32(b, p);
            p += 4;
          }
          if (flags & 0x200 != 0) {
            size = _readU32(b, p);
            p += 4;
          }
          if (flags & 0x400 != 0) p += 4;
          if (flags & 0x800 != 0) p += 4;
          sizes.add(size);
          durations.add(duration);
        }
        final length = sizes.fold(0, (a, s) => a + s);
        if (sizes.isEmpty || dataAt < 0 || dataAt + length > b.length) {
          continue;
        }
        final fragment = _Fragment(
          decodeTime,
          sizes,
          durations,
          Uint8List.sublistView(b, dataAt, dataAt + length),
        );
        found.add(fragment);
        decodeTime += fragment.length;
        dataAt += length;
      }
    }
    return found;
  }
}

// Boxes -------------------------------------------------------------------------

class _Box {
  final String type;
  final int start;
  final int body;
  final int end;

  _Box(this.type, this.start, this.body, this.end);
}

/// The boxes in b[from, to). A box cut short (a capture that ended early)
/// ends the list.
List<_Box> _children(Uint8List b, int from, int to) {
  final boxes = <_Box>[];
  var at = from;
  while (at + 8 <= to) {
    var size = _readU32(b, at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > to) break;
      size = _readU64(b, at + 8);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header || at + size > to) break;
    boxes.add(_Box(_type(b, at + 4), at, at + header, at + size));
    at += size;
  }
  return boxes;
}

_Box? _find(List<_Box> boxes, String type) =>
    boxes.where((b) => b.type == type).firstOrNull;

String _type(Uint8List b, int at) =>
    at + 4 > b.length ? '' : String.fromCharCodes(b, at, at + 4);

Uint8List _copy(Uint8List b, _Box box) =>
    Uint8List.fromList(b.sublist(box.start, box.end));

int _readU32(Uint8List b, int at) => at + 4 > b.length
    ? 0
    : b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];

int _readI32(Uint8List b, int at) => _readU32(b, at).toSigned(32);

int _readU64(Uint8List b, int at) =>
    _readU32(b, at) * 0x100000000 + _readU32(b, at + 4);

/// mvhd's or mdhd's timescale (same place in both).
int _timescale(Uint8List b, _Box box) {
  final scale = _readU32(b, box.body + (b[box.body] == 1 ? 20 : 12));
  return scale == 0 ? 1000 : scale;
}

/// A copy of an mvhd, tkhd or mdhd box with its duration set.
Uint8List _withDuration(Uint8List box, int duration) {
  final out = Uint8List.fromList(box);
  final version = out[8];
  final type = String.fromCharCodes(out, 4, 8);
  // After version/flags and the creation and modification times come
  // timescale (mvhd, mdhd) or track id and a reserved word (tkhd).
  final at = 8 + (version == 1 ? 4 + 16 : 4 + 8) + (type == 'tkhd' ? 8 : 4);
  if (version == 1) {
    out.setRange(at, at + 8, [
      ..._u32(duration ~/ 0x100000000),
      ..._u32(duration),
    ]);
  } else {
    out.setRange(at, at + 4, _u32(duration.clamp(0, 0xFFFFFFFF)));
  }
  return out;
}

Uint8List _stts(List<int> durations) {
  final entries = <(int, int)>[];
  for (final d in durations) {
    if (entries.isNotEmpty && entries.last.$2 == d) {
      entries.last = (entries.last.$1 + 1, d);
    } else {
      entries.add((1, d));
    }
  }
  return _fullBox('stts', [
    _u32(entries.length),
    for (final (count, d) in entries) ...[_u32(count), _u32(d)],
  ]);
}

/// moov/udta/meta/ilst with title, artist and cover, as iTunes writes them.
Uint8List _tags({String? title, String? artist, Uint8List? cover}) {
  Uint8List data(int type, List<int> value) =>
      _box('data', [_u32(type), _u32(0), value]);
  final isPng =
      cover != null &&
      cover.length > 4 &&
      cover[0] == 0x89 &&
      cover[1] == 0x50 &&
      cover[2] == 0x4E &&
      cover[3] == 0x47;
  return _box('udta', [
    _fullBox('meta', [
      _fullBox('hdlr', [
        _u32(0),
        ascii.encode('mdir'),
        ascii.encode('appl'),
        Uint8List(9),
      ]),
      _box('ilst', [
        if (title != null) _box('©nam', [data(1, utf8.encode(title))]),
        if (artist != null) _box('©ART', [data(1, utf8.encode(artist))]),
        if (cover != null) _box('covr', [data(isPng ? 14 : 13, cover)]),
      ]),
    ]),
  ]);
}

Uint8List _u32(int v) => Uint8List.fromList([
  v >> 24 & 0xFF,
  v >> 16 & 0xFF,
  v >> 8 & 0xFF,
  v & 0xFF,
]);

Uint8List _box(String type, List<List<int>> parts) {
  final body = BytesBuilder(copy: false);
  for (final part in parts) {
    body.add(part);
  }
  final bytes = body.takeBytes();
  // Box types like ©nam are Latin-1.
  return (BytesBuilder(copy: false)
        ..add(_u32(bytes.length + 8))
        ..add(latin1.encode(type))
        ..add(bytes))
      .takeBytes();
}

/// A box with version 0 and no flags.
Uint8List _fullBox(String type, List<List<int>> parts) =>
    _box(type, [Uint8List(4), ...parts]);
