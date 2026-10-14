import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/playlist.dart';
import 'package:musify/services/local_copies.dart';
import 'package:musify/services/metadata_service.dart';

YouTubeTrack yt(String id, String name, String? channel, int? seconds) =>
    YouTubeTrack(
      videoId: id,
      name: name,
      channel: channel,
      length: seconds == null ? null : Duration(seconds: seconds),
    );

void main() {
  final copies = LocalCopies.instance;
  const billie = Track('/music/MJ/Billie Jean.mp3');
  const beatIt = Track('/music/MJ/02 - Beat It.mp3');
  const kya = Track('/music/Hindi/Kya Mujhe Pyar Hai.m4a');
  const intro = Track('/music/Other/Intro.mp3');
  const thriller = Track('/music/MJ/Michael Jackson - Thriller.mp3');

  setUp(() {
    copies.debugIndex(
      [billie, beatIt, kya, intro, thriller],
      {
        billie.path: const TrackInfo(
          title: 'Billie Jean',
          artist: 'Michael Jackson',
          duration: Duration(seconds: 294),
        ),
        // No title or artist: the file name has to do, with the length.
        beatIt.path: const TrackInfo(duration: Duration(seconds: 258)),
        kya.path: const TrackInfo(duration: Duration(seconds: 250)),
        intro.path: const TrackInfo(
          title: 'Intro',
          artist: 'The xx',
          duration: Duration(seconds: 127),
        ),
      },
    );
  });

  test('names compare without YouTube extras', () {
    expect(LocalCopies.norm('Billie Jean (Official Video)'), 'billie jean');
    expect(LocalCopies.norm('Beat It [HD] feat. Eddie'), 'beat it');
    expect(
      LocalCopies.titles('Kya Mujhe Pyar Hai | Woh Lamhe | KK'),
      contains('kya mujhe pyar hai'),
    );
    expect(
      LocalCopies.titles('Michael Jackson - Billie Jean'),
      containsAll(['michael jackson', 'billie jean']),
    );
  });

  test('a song on the device is found by title and artist', () {
    expect(
      copies.copyOf(yt('a', 'Billie Jean', 'Michael Jackson', 293))?.path,
      billie.path,
    );
    // A music video's title and a VEVO channel.
    expect(
      copies
          .copyOf(
            yt(
              'b',
              'Michael Jackson - Billie Jean (Official Video)',
              'MichaelJacksonVEVO',
              null,
            ),
          )
          ?.path,
      billie.path,
    );
    // Artist from "Artist - Title" file names; numbered files.
    expect(
      copies.copyOf(yt('c', 'Thriller', 'Michael Jackson', 357))?.path,
      thriller.path,
    );
    expect(
      copies.copyOf(yt('d', 'Beat It', 'Michael Jackson', 258))?.path,
      beatIt.path,
    );
  });

  test("a label's upload matches by length", () {
    expect(
      copies
          .copyOf(
            yt(
              'e',
              'Kya Mujhe Pyar Hai | Woh Lamhe | KK',
              'T-Series Bollywood Classics',
              251,
            ),
          )
          ?.path,
      kya.path,
    );
    // Same title, other length and artist: not this one.
    expect(
      copies.copyOf(yt('f', 'Kya Mujhe Pyar Hai', 'T-Series', 300)),
      isNull,
    );
  });

  test('same title by someone else, or another take, is not a copy', () {
    expect(copies.copyOf(yt('g', 'Intro', 'M83', 330)), isNull);
    // A live version of a different length.
    expect(
      copies.copyOf(yt('h', 'Billie Jean (Live)', 'Michael Jackson', 380)),
      isNull,
    );
  });

  test('playing swaps in the file, keeping queued songs queued', () {
    final song = yt('i', 'Billie Jean', 'Michael Jackson', 294);
    expect(copies.resolve(song).path, billie.path);
    expect(copies.resolve(song), isNot(isA<YouTubeTrack>()));
    final queued = QueuedYouTubeTrack(
      videoId: 'i',
      name: 'Billie Jean',
      channel: 'Michael Jackson',
    );
    expect(copies.resolve(queued), isA<QueuedTrack>());
    final other = yt('j', 'Smooth Criminal', 'Michael Jackson', 257);
    expect(copies.resolve(other), same(other));
  });
}
