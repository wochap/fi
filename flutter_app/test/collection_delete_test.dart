import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show seeded;
import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';

StructuredValueDto _emptyMap() => const StructuredValueDto(
  kind: StructuredValueKindDto.map,
  items: [],
  entries: [],
);

WidgetDefinitionDto _widget(int index, {bool deleted = false}) =>
    WidgetDefinitionDto(
      id: 'widget-$index',
      collectionId: _collection,
      widgetType: 'core.aggregate-number',
      queryId: 'query-0',
      title: 'Widget $index',
      configuration: WidgetConfigurationDto(version: 1, body: _emptyMap()),
      layout: WidgetLayoutDto(
        version: 1,
        size: WidgetSizeDto.medium,
        hints: _emptyMap(),
      ),
      order: index,
      deleted: deleted,
    );

QueryDefinitionDto _query(int index) => QueryDefinitionDto(
  id: 'query-$index',
  collectionId: _collection,
  name: 'Query $index',
  queryVersion: 1,
  query: const CollectionQueryDto(
    collectionId: _collection,
    shape: QueryShapeDto(
      kind: QueryShapeKindDto.scalar,
      aggregation: AggregationDto(kind: AggregationKindDto.count),
      fields: [],
    ),
    sorting: [],
    calendar: CalendarPolicyDto(
      timezone: 'UTC',
      weekStart: WeekStartDto.monday,
    ),
  ),
  order: index,
  deleted: false,
);

/// Opens the collection list and chooses Delete from the collection's menu.
Future<void> chooseDelete(
  WidgetTester tester,
  FakeCollectionBridge bridge, {
  Object? countError,
}) async {
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  bridge.nextError = countError;
  await tester.tap(find.text('Delete'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancel sends no command and keeps the collection', (
    tester,
  ) async {
    final bridge = seeded(2);
    await chooseDelete(tester, bridge);
    expect(find.text('Delete "Headaches"?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dismiss-delete-collection')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.collections, hasLength(1));
    expect(find.text('Headaches'), findsOneWidget);
  });

  testWidgets('confirm sends the delete command', (tester) async {
    final bridge = seeded(2);
    await chooseDelete(tester, bridge);

    await tester.tap(find.byKey(const Key('confirm-delete-collection')));
    await tester.pumpAndSettle();
    expect(bridge.collections, isEmpty);
    await pumpUntilFound(
      tester,
      find.text('Create a collection to start shaping your data.'),
    );
    expect(find.text('Headaches'), findsNothing);
  });

  testWidgets('states the counts of what is deleted with it', (tester) async {
    final bridge = seeded(142);
    bridge.widgetDefinitions[_collection] = [
      for (var index = 0; index < 3; index++) _widget(index),
      _widget(3, deleted: true),
    ];
    bridge.queryDefinitions[_collection] = [_query(0), _query(1)];
    await chooseDelete(tester, bridge);
    expect(
      find.text(
        '142 records, 3 widgets and 2 saved queries are deleted with it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('leaves out zero counts', (tester) async {
    final bridge = seeded(5);
    await chooseDelete(tester, bridge);
    expect(find.text('5 records are deleted with it.'), findsOneWidget);
  });

  testWidgets('says an empty collection is empty', (tester) async {
    final bridge = seeded(0);
    await chooseDelete(tester, bridge);
    expect(find.text('This collection is empty.'), findsOneWidget);
  });

  testWidgets('a failed count keeps the generic sentence and Delete usable', (
    tester,
  ) async {
    final bridge = seeded(3);
    await chooseDelete(tester, bridge, countError: Exception('boom'));
    expect(
      find.text('Its records, widgets and saved queries are deleted with it.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('confirm-delete-collection')));
    await tester.pumpAndSettle();
    expect(bridge.collections, isEmpty);
  });

  test('sentence pluralizes and joins its parts', () {
    String sentence(int records, int widgets, int savedQueries) =>
        collectionContentsSentence(
          CollectionContents(
            records: records,
            widgets: widgets,
            savedQueries: savedQueries,
          ),
        );
    expect(sentence(1, 0, 0), '1 record is deleted with it.');
    expect(
      sentence(0, 1, 1),
      '1 widget and 1 saved query are deleted with it.',
    );
    expect(
      sentence(2, 0, 3),
      '2 records and 3 saved queries are deleted with it.',
    );
    expect(sentence(0, 0, 0), 'This collection is empty.');
  });
}
