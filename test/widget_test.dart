import 'package:flutter_test/flutter_test.dart';

import 'package:musify/main.dart';

void main() {
  testWidgets('shows Home, Search and Library tabs', (tester) async {
    await tester.pumpWidget(const MusifyApp());

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Your Library'), findsOneWidget);
  });
}
