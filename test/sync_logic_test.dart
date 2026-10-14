import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/sync_service.dart';

void main() {
  group('library merge', () {
    test('only what changed here gets a new time', () {
      final before = {
        'p:a': {
          't': 1,
          'v': {'name': 'Road'},
        },
        'p:b': {
          't': 2,
          'v': {'name': 'Gym'},
        },
      };
      final mine = stampChanges(
        {
          'p:a': {'name': 'Road'},
          'p:b': {'name': 'Gym 2'},
          'p:c': {'name': 'New'},
        },
        before,
        10,
      );
      expect(mine['p:a'], {
        't': 1,
        'v': {'name': 'Road'},
      });
      expect(mine['p:b'], {
        't': 10,
        'v': {'name': 'Gym 2'},
      });
      expect(mine['p:c'], {
        't': 10,
        'v': {'name': 'New'},
      });
    });

    test('deleted here becomes a deletion, which stays', () {
      final mine = stampChanges({}, {
        'p:a': {
          't': 1,
          'v': {'name': 'Road'},
        },
        'p:x': {'t': 3, 'del': true},
      }, 10);
      expect(mine['p:a'], {'t': 10, 'del': true});
      expect(mine['p:x'], {'t': 3, 'del': true});
    });

    test('the latest change wins, item by item', () {
      final merged = mergeItems(
        {
          'p:a': {'t': 10, 'v': 'mine'},
          'p:b': {'t': 1, 'v': 'mine'},
          'p:c': {'t': 5, 'del': true},
        },
        {
          'p:a': {'t': 5, 'v': 'theirs'},
          'p:b': {'t': 7, 'v': 'theirs'},
          'p:d': {'t': 2, 'v': 'theirs'},
        },
      );
      expect(merged['p:a'], {'t': 10, 'v': 'mine'});
      expect(merged['p:b'], {'t': 7, 'v': 'theirs'});
      expect(merged['p:c'], {'t': 5, 'del': true});
      expect(merged['p:d'], {'t': 2, 'v': 'theirs'});
    });
  });

  group('music files', () {
    Map<String, dynamic> file(String sha1, {bool deleted = false}) => {
      'sha1': sha1,
      'deleted': deleted,
    };

    test('new on either side goes to the other', () {
      final plan = planFiles(
        {'EDM/mine.mp3': 'aaa'},
        {'EDM/theirs.mp3': file('bbb')},
        {},
      );
      expect(plan.upload, ['EDM/mine.mp3']);
      expect(plan.download, ['EDM/theirs.mp3']);
      expect(plan.deleteHere, isEmpty);
      expect(plan.deleteThere, isEmpty);
    });

    test('the same file on both sides is just noted', () {
      final synced = <String, dynamic>{};
      final plan = planFiles({'a.mp3': 'aaa'}, {'a.mp3': file('aaa')}, synced);
      expect([...plan.upload, ...plan.download], isEmpty);
      expect(synced, {'a.mp3': 'aaa'});
    });

    test('deleted here after syncing: deleted there too', () {
      final plan = planFiles({}, {'a.mp3': file('aaa')}, {'a.mp3': 'aaa'});
      expect(plan.deleteThere, ['a.mp3']);
      expect(plan.download, isEmpty);
    });

    test('deleted there: deleted here, unless it changed here', () {
      final plan = planFiles(
        {'a.mp3': 'aaa', 'b.mp3': 'new'},
        {
          'a.mp3': file('aaa', deleted: true),
          'b.mp3': file('bbb', deleted: true),
        },
        {'a.mp3': 'aaa', 'b.mp3': 'bbb'},
      );
      expect(plan.deleteHere, ['a.mp3']);
      expect(plan.upload, ['b.mp3']);
    });

    test('changed on one side: that side wins', () {
      final plan = planFiles(
        {'here.mp3': 'new', 'there.mp3': 'old'},
        {'here.mp3': file('old'), 'there.mp3': file('new')},
        {'here.mp3': 'old', 'there.mp3': 'old'},
      );
      expect(plan.upload, ['here.mp3']);
      expect(plan.download, ['there.mp3']);
    });
  });
}
