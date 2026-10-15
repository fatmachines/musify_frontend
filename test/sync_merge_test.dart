import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/sync_merge.dart';

Map<String, dynamic> item(int t, Map<String, Object?> v, {String? by}) => {
  't': t,
  'v': v,
  'by': ?by,
};

void main() {
  group('library: changed on both devices while apart', () {
    final base = {
      'p:road': item(1, {
        'name': 'Road Trip',
        'tracks': ['a', 'b', 'c'],
      }),
      'liked': item(1, {
        'tracks': ['a'],
      }),
    };

    test('renamed two ways: theirs for now, and the user is asked', () {
      final (:merged, :clashes) = mergeLibrary(
        {
          'p:road': item(10, {
            'name': 'Summer Drive',
            'tracks': ['a', 'b', 'c'],
          }),
          'liked': base['liked']!,
        },
        {
          'p:road': item(8, {
            'name': 'Road Trip 2026',
            'tracks': ['a', 'b', 'c'],
          }, by: 'MacBook Pro'),
          'liked': base['liked']!,
        },
        base,
      );
      expect(merged['p:road']['v']['name'], 'Road Trip 2026');
      expect(clashes, hasLength(1));
      final clash = clashes.single;
      expect(clash.key, 'p:road');
      expect(clash.mine, 'Summer Drive');
      expect(clash.theirs, 'Road Trip 2026');
      expect(clash.by, 'MacBook Pro');
    });

    test('different changes to one playlist are both kept, no question', () {
      final (:merged, :clashes) = mergeLibrary(
        {
          // Renamed here, a song added and one taken off.
          'p:road': item(10, {
            'name': 'Summer Drive',
            'tracks': ['a', 'c', 'x'],
          }),
          'liked': item(10, {
            'tracks': ['a', 'm'],
          }),
        },
        {
          // A song added there.
          'p:road': item(8, {
            'name': 'Road Trip',
            'tracks': ['a', 'b', 'c', 'y'],
          }),
          'liked': item(8, {
            'tracks': ['t', 'a'],
          }),
        },
        base,
      );
      expect(clashes, isEmpty);
      expect(merged['p:road']['v'], {
        'name': 'Summer Drive',
        'tracks': ['a', 'c', 'y', 'x'],
      });
      expect(merged['liked']['v']['tracks'], ['t', 'a', 'm']);
    });

    test('changed on one side only: that side, as before', () {
      final mine = {
        'p:road': item(10, {
          'name': 'Mine',
          'tracks': ['a'],
        }),
        'liked': base['liked']!,
      };
      final (:merged, :clashes) = mergeLibrary(mine, base, base);
      expect(merged['p:road'], mine['p:road']);
      expect(clashes, isEmpty);
    });

    test('an edit beats a deletion', () {
      final edited = item(8, {
        'name': 'Road Trip',
        'tracks': ['a', 'b', 'c', 'd'],
      });
      var result = mergeLibrary(
        {
          'p:road': {'t': 10, 'del': true},
        },
        {'p:road': edited},
        base,
      );
      expect(result.merged['p:road'], edited);
      result = mergeLibrary(
        {'p:road': edited},
        {
          'p:road': {'t': 10, 'del': true},
        },
        base,
      );
      expect(result.merged['p:road']['v'], edited['v']);
      expect(result.clashes, isEmpty);
    });

    test('Liked Songs on two new devices: both lists', () {
      final (:merged, :clashes) = mergeLibrary(
        {
          'liked': item(5, {
            'tracks': ['a', 'b'],
          }),
        },
        {
          'liked': item(4, {
            'tracks': ['c', 'a'],
          }),
        },
        {},
      );
      expect(merged['liked']['v']['tracks'], ['c', 'a', 'b']);
      expect(clashes, isEmpty);
    });
  });

  group('files renamed two ways', () {
    test('a song renamed differently here and there', () {
      final clashes = findRenames(
        upload: ['Rock/Bohemian.mp3'],
        download: ['Rock/Bohemian Rhapsody.mp3'],
        local: {'Rock/Bohemian.mp3': 's1'},
        remote: {
          'Rock/Bohemian Rhapsody.mp3': {'sha1': 's1'},
          'Rock/b.mp3': {'sha1': 's1', 'deleted': true},
        },
        synced: {'Rock/b.mp3': 's1'},
      );
      expect(clashes, hasLength(1));
      expect(clashes.single.mine, ['Rock/Bohemian.mp3']);
      expect(clashes.single.theirs, ['Rock/Bohemian Rhapsody.mp3']);
      expect(clashes.single.folder, isFalse);
    });

    test('a folder renamed two ways is one question', () {
      final clashes = findRenames(
        upload: ['Classic Rock/a.mp3', 'Classic Rock/b.mp3'],
        download: ['Old Rock/a.mp3', 'Old Rock/b.mp3'],
        local: {'Classic Rock/a.mp3': 's1', 'Classic Rock/b.mp3': 's2'},
        remote: {
          'Old Rock/a.mp3': {'sha1': 's1'},
          'Old Rock/b.mp3': {'sha1': 's2'},
        },
        synced: {'Rock/a.mp3': 's1', 'Rock/b.mp3': 's2'},
      );
      expect(clashes, hasLength(1));
      expect(clashes.single.folder, isTrue);
      expect(clashes.single.mine, ['Classic Rock/a.mp3', 'Classic Rock/b.mp3']);
    });

    test('the same new song added on both sides is no clash', () {
      expect(
        findRenames(
          upload: ['A/new.mp3'],
          download: ['B/new.mp3'],
          local: {'A/new.mp3': 's9'},
          remote: {
            'B/new.mp3': {'sha1': 's9'},
          },
          synced: {},
        ),
        isEmpty,
      );
    });
  });
}
