import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/playlist.dart';
import 'metadata_service.dart';

/// Embedded cover art written out to files, because the lock screen, the
/// notification and car displays take artwork by URI rather than as bytes.
class CoverFiles {
  static final _uris = <String, Future<Uri?>>{};

  /// Writes [track]'s cover again next time (its file changed).
  static void forget(String path) => _uris.remove(path)?.then((uri) {
    if (uri != null) File.fromUri(uri).delete().ignore();
  });

  static Future<Uri?> uriFor(Track track) {
    return _uris.putIfAbsent(track.path, () async {
      final bytes = await MetadataService.cover(track);
      if (bytes == null) return null;
      try {
        final temp = await getTemporaryDirectory();
        final dir = Directory(p.join(temp.path, 'covers'));
        await dir.create(recursive: true);
        final name =
            '${track.path.hashCode.toUnsigned(32)}'
            '_${track.path.length}.jpg';
        final file = File(p.join(dir.path, name));
        if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
        return file.uri;
      } catch (_) {
        return null;
      }
    });
  }
}
