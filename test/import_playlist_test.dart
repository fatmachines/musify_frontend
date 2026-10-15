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

  test('Spotify links give their playlist id', () {
    const id = '37i9dQZF1DWXRqgorJj26U';
    for (final link in [
      'https://open.spotify.com/playlist/$id',
      'https://open.spotify.com/playlist/$id?si=9f2c1d7a4b3e4c5d',
      'https://open.spotify.com/intl-de/playlist/$id',
      'spotify:playlist:$id',
    ]) {
      expect(MusifyServer.spotifyPlaylistIdOf(link), id, reason: link);
      expect(MusifyServer.playlistIdOf(link), isNull, reason: link);
    }
    expect(
      MusifyServer.spotifyPlaylistIdOf('https://open.spotify.com/album/$id'),
      isNull,
    );
  });
}
