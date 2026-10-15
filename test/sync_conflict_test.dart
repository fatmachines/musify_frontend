import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/sync_merge.dart';
import 'package:musify/services/sync_service.dart';
import 'package:musify/widgets/sync_conflict.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a conflict asks which version to keep, and settles it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncService.instance;
    const conflict = SyncConflict.name(
      NameClash('p:road', 'name', 'Summer Drive', 'Road Trip 2026', 'Mac'),
    );
    sync.conflicts.value = [conflict];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConflictDialog(context, conflict),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Playlist renamed on two devices'), findsOneWidget);
    expect(find.text('Summer Drive'), findsOneWidget);
    expect(find.text('Road Trip 2026'), findsOneWidget);
    expect(find.textContaining('Mac'), findsWidgets);

    await tester.tap(find.text('Road Trip 2026'));
    await tester.pumpAndSettle();
    expect(find.text('Playlist renamed on two devices'), findsNothing);
    expect(sync.conflicts.value, isEmpty);
  });

  testWidgets('a folder renamed two ways shows the folders', (tester) async {
    const conflict = SyncConflict.files(
      RenameClash(['s1', 's2'], ['Classic Rock/a.mp3', 'Classic Rock/b.mp3'], [
        'Old Rock/a.mp3',
        'Old Rock/b.mp3',
      ]),
    );
    final about = describeConflict(conflict);
    expect(about.title, 'Folder renamed on two devices');
    expect(about.mine, 'Classic Rock');
    expect(about.theirs, 'Old Rock');
    expect(about.detail, '2 songs');
  });
}
