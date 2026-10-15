import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/musify_server.dart';

void main() {
  test('the playlist id comes out of any kind of link', () {
    const id = 'PLDIoUOhQQPlXr63I_vwF9GD8sAKh77dWU';
    for (final link in [
      'https://www.youtube.com/playlist?list=$id',
      'https://music.youtube.com/playlist?list=$id&si=abc123',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=$id&index=3',
      'youtube.com/playlist?list=$id',
      '  $id  ',
    ]) {
      expect(MusifyServer.playlistIdOf(link), id, reason: link);
    }
    expect(MusifyServer.playlistIdOf('https://youtu.be/dQw4w9WgXcQ'), isNull);
    expect(MusifyServer.playlistIdOf('hello'), isNull);
  });
}
