import 'dart:convert';

import 'package:path/path.dart' as p;

/// A playlist's or tag's name changed to different things on this device
/// and another while they were apart: the user picks one.
class NameClash {
  /// The item (`p:<id>` for a playlist, `t:<id>` for a tag) and the field.
  final String key;
  final String field;
  final String mine;
  final String theirs;

  /// The other device's name, if known.
  final String? by;

  const NameClash(this.key, this.field, this.mine, this.theirs, this.by);
}

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// Merges this device's library items ([mine], stamped by stampChanges)
/// with the group's ([theirs]), given how they last agreed ([base]).
///
/// An item changed on one side only takes that side. Changed on both, it's
/// merged field by field: song lists keep what each side added and drop
/// what each removed; a field only one side changed takes that change; an
/// edit beats a deletion (nothing is lost). Only a name changed to two
/// different things can't be settled: it keeps theirs for now, and comes
/// back as a [NameClash] for the user.
({Map<String, dynamic> merged, List<NameClash> clashes}) mergeLibrary(
  Map<String, dynamic> mine,
  Map<String, dynamic> theirs,
  Map<String, dynamic> base,
) {
  final merged = <String, dynamic>{...theirs};
  final clashes = <NameClash>[];
  mine.forEach((key, item) {
    item as Map;
    final other = theirs[key] as Map?;
    final last = base[key] as Map?;
    if (other == null) {
      merged[key] = item;
      return;
    }
    final changedHere = !_same(item, last);
    final changedThere = !_same(other, last);
    if (!changedHere || _same(item, other)) return; // theirs, as it is
    if (!changedThere) {
      merged[key] = item;
      return;
    }
    final t = [
      (item['t'] as num),
      (other['t'] as num),
    ].reduce((a, b) => a > b ? a : b);
    final deletedHere = item['del'] == true;
    final deletedThere = other['del'] == true;
    if (deletedHere && deletedThere) return;
    if (deletedHere) return; // their edit stays
    if (deletedThere) {
      merged[key] = {...item, 't': t};
      return;
    }
    final ours = (item['v'] as Map).cast<String, dynamic>();
    final yours = (other['v'] as Map).cast<String, dynamic>();
    final was = ((last?['del'] == true ? null : last?['v']) as Map?)
        ?.cast<String, dynamic>();
    final value = <String, dynamic>{};
    for (final field in {...yours.keys, ...ours.keys}) {
      final m = ours[field];
      final y = yours[field];
      final b = was?[field];
      if (_same(m, y) || _same(m, b)) {
        value[field] = y ?? m;
      } else if (_same(y, b)) {
        value[field] = m;
      } else if (m is List && y is List) {
        value[field] = mergeLists(b is List ? b : const [], m, y);
      } else {
        value[field] = y;
        if (field == 'name' && m is String && y is String) {
          clashes.add(NameClash(key, field, m, y, other['by'] as String?));
        }
      }
    }
    merged[key] = {
      't': t,
      'v': value,
      if (other['by'] != null) 'by': other['by'],
    };
  });
  return (merged: merged, clashes: clashes);
}

/// A list both sides changed: theirs, plus what was added here, minus what
/// was taken off here.
List<Object?> mergeLists(
  List<Object?> base,
  List<Object?> mine,
  List<Object?> theirs,
) {
  String id(Object? o) => jsonEncode(o);
  final before = base.map(id).toSet();
  final here = mine.map(id).toSet();
  final there = theirs.map(id).toSet();
  final removedHere = before.difference(here);
  return [
    for (final o in theirs)
      if (!removedHere.contains(id(o))) o,
    for (final o in mine)
      if (!before.contains(id(o)) && !there.contains(id(o))) o,
  ];
}

/// The same songs renamed (or moved) to different places on this device
/// and another while they were apart: here they're at [mine], there at
/// [theirs] (paths in the synced folder, pairwise). A folder renamed two
/// ways is one of these, for all its songs.
class RenameClash {
  final List<String> sha1s;
  final List<String> mine;
  final List<String> theirs;

  const RenameClash(this.sha1s, this.mine, this.theirs);

  /// A folder renamed (the songs kept their file names), or one song.
  bool get folder =>
      mine.length > 1 ||
      (p.posix.basename(mine.first) == p.posix.basename(theirs.first) &&
          p.posix.dirname(mine.first) != p.posix.dirname(theirs.first));

  String get id => 'files:${(sha1s.toList()..sort()).join(',')}';

  Map<String, Object?> toJson() => {
    'sha1s': sha1s,
    'mine': mine,
    'theirs': theirs,
  };

  static RenameClash fromJson(Map<String, dynamic> json) => RenameClash(
    (json['sha1s'] as List).cast<String>(),
    (json['mine'] as List).cast<String>(),
    (json['theirs'] as List).cast<String>(),
  );
}

/// Songs new here ([upload]) and new there ([download]) that are the same
/// file (SHA-1), and were already synced under another name: renamed two
/// ways. Grouped by the pair of folders they went to, so a folder renamed
/// two ways is asked about once.
List<RenameClash> findRenames({
  required List<String> upload,
  required List<String> download,
  required Map<String, String> local,
  required Map<String, Map<String, dynamic>> remote,
  required Map<String, dynamic> synced,
}) {
  final wasSynced = synced.values.toSet();
  final there = <String, String>{
    for (final rel in download)
      if (remote[rel]?['sha1'] case final String sha1) sha1: rel,
  };
  final groups = <String, List<(String, String, String)>>{};
  for (final rel in upload) {
    final sha1 = local[rel];
    final other = there[sha1];
    if (sha1 == null || other == null || other == rel) continue;
    if (!wasSynced.contains(sha1)) continue; // two new copies, not a rename
    final key =
        '${p.posix.dirname(rel)}|${p.posix.dirname(other)}|'
        '${p.posix.basename(rel) == p.posix.basename(other)}';
    (groups[key] ??= []).add((sha1, rel, other));
  }
  return [
    for (final group in groups.values)
      // Different file names in one folder: each song its own question.
      if (group.length > 1 &&
          group.every((g) => p.posix.basename(g.$2) == p.posix.basename(g.$3)))
        RenameClash(
          [for (final g in group) g.$1],
          [for (final g in group) g.$2],
          [for (final g in group) g.$3],
        )
      else
        for (final g in group) RenameClash([g.$1], [g.$2], [g.$3]),
  ];
}
