import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show openCollection, seeded;
import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
final _more = find.byKey(const Key('collection-desktop-more'));

Future<FakeCollectionBridge> _open(
  WidgetTester tester, {
  FakeFileDialogs? dialogs,
}) async {
  tester.view.physicalSize = const Size(1240, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final bridge = seeded(2);
  if (dialogs == null) {
    await openCollection(tester, bridge);
  } else {
    await tester.pumpWidget(app(bridge, fileDialogs: dialogs));
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.tap(find.text('Headaches'));
    await tester.pumpAndSettle();
  }
  return bridge;
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(_more);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the ⋮ sits between Select and New record and lists the actions '
      'in groups', (tester) async {
    await _open(tester);
    final select = tester.getCenter(find.byKey(const Key('select-records')));
    final more = tester.getCenter(_more);
    final create = tester.getCenter(find.text('New record'));
    expect(more.dx, greaterThan(select.dx));
    expect(more.dx, lessThan(create.dx));
    await tester.tap(_more);
    await tester.pumpAndSettle();
    const labels = [
      'Queries',
      'Select records',
      'Export CSV',
      'Export JSON',
      'Import CSV…',
      'Rename',
      'Clone',
      'Delete…',
    ];
    final menu = find.byType(PopupMenuItem<Object>);
    final tops = [
      for (final label in labels)
        tester
            .getTopLeft(find.descendant(of: menu, matching: find.text(label)))
            .dy,
    ];
    expect(tops, [...tops]..sort());
    expect(find.byType(PopupMenuDivider), findsNWidgets(2));
  });

  testWidgets('Queries opens the queries sheet', (tester) async {
    await _open(tester);
    await _choose(tester, 'Queries');
    expect(find.text('Computed fields & queries'), findsOneWidget);
  });

  testWidgets('Select records starts selection', (tester) async {
    await _open(tester);
    await _choose(tester, 'Select records');
    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('Export CSV and Export JSON write the collection', (
    tester,
  ) async {
    final dialogs = FakeFileDialogs()..saveResult = 'Headaches.csv';
    final bridge = await _open(tester, dialogs: dialogs);
    await _choose(tester, 'Export CSV');
    await _choose(tester, 'Export JSON');
    expect(bridge.exports, ['csv $_collection', 'json $_collection']);
    expect(find.text('Exported to Headaches.csv'), findsOneWidget);
  });

  testWidgets('Import CSV… imports into the collection', (tester) async {
    final dialogs = FakeFileDialogs()..openResult = 'Title\na\n';
    final bridge = await _open(tester, dialogs: dialogs);
    await _choose(tester, 'Import CSV…');
    expect(bridge.imports, [(_collection, 'Title\na\n')]);
    expect(find.text('Imported 1 record into Headaches'), findsOneWidget);
  });

  testWidgets('Rename starts the inline title editor', (tester) async {
    await _open(tester);
    await _choose(tester, 'Rename');
    expect(find.byKey(const Key('collection-title-input')), findsOneWidget);
  });

  testWidgets('Clone opens the Clone collection dialog', (tester) async {
    await _open(tester);
    await _choose(tester, 'Clone');
    expect(find.text('Clone collection'), findsOneWidget);
  });

  testWidgets('Delete… asks first', (tester) async {
    await _open(tester);
    await _choose(tester, 'Delete…');
    expect(find.text('Delete "Headaches"?'), findsOneWidget);
  });
}
