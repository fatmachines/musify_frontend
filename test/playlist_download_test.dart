import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/downloads.dart';
import 'package:musify/services/library.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a downloaded playlist becomes its folder, pin and all', () async {
    final root = await Directory.systemTemp.createTemp('musify_dl');
    addTearDown(() => root.delete(recursive: true));
    for (final name in ['a', 'b']) {
      await File(p.join(root.path, 'Rock', '$name.mp3'))
          .create(recursive: true);
    }
    SharedPreferences.setMockInitialValues({
      'library_folders': [root.path],
    });
    final library = Library.instance;
    await library.ensureLoaded();
    final mix = library.createPlaylist('Road Trip');
    for (final song in library.allSongs) {
      library.addTrack(mix, song);
    }
    library.togglePin(library.custom.single);

    final done = <(int, int, bool)>[];
    final (queued, folder) = await Downloads.instance.downloadPlaylist(
      library.custom.single,
      root.path,
      onDone: (saved, failed, converted) =>
          done.add((saved, failed, converted)),
    );

    // Only songs on the device: nothing to fetch, so it converts at once.
    expect(queued, 0);
    expect(folder, p.join(root.path, 'Road Trip'));
    expect(done, [(0, 0, true)]);
    expect(
      Directory(folder).listSync().map((e) => p.basename(e.path)).toSet(),
      {'a.mp3', 'b.mp3'},
    );
    expect(library.custom, isEmpty);
    final folderPlaylist = library.byId(folder)!;
    expect(folderPlaylist.tracks, hasLength(2));
    expect(library.pinned.map((pl) => pl.id), [folder]);
  });
}
