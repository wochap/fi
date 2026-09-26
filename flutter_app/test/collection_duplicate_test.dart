import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show seeded;
import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
final _name = find.byKey(const Key('duplicate-collection-name'));

StructuredValueDto _emptyMap() => const StructuredValueDto(
  kind: StructuredValueKindDto.map,
  items: [],
  entries: [],
);

const _query = QueryDefinitionDto(
  id: 'query-0',
  collectionId: _collection,
  name: 'Count',
  queryVersion: 1,
  query: CollectionQueryDto(
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
  order: 0,
  deleted: false,
);

WidgetDefinitionDto _widget() => WidgetDefinitionDto(
  id: 'widget-0',
  collectionId: _collection,
  widgetType: 'core.aggregate-number',
  queryId: _query.id,
  title: 'Count',
  configuration: WidgetConfigurationDto(version: 1, body: _emptyMap()),
  layout: WidgetLayoutDto(
    version: 1,
    size: WidgetSizeDto.medium,
    hints: _emptyMap(),
  ),
  order: 0,
  deleted: false,
);

/// The seeded "Headaches" collection with records, a saved query and a widget.
FakeCollectionBridge _source() {
  final bridge = seeded(2);
  bridge.queryDefinitions[_collection] = [_query];
  bridge.widgetDefinitions[_collection] = [_widget()];
  return bridge;
}

/// Opens the collection list and chooses Duplicate from the collection's menu.
Future<FakeCollectionBridge> _chooseDuplicate(WidgetTester tester) async {
  final bridge = _source();
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Duplicate'));
  await tester.pumpAndSettle();
  return bridge;
}

String _nameText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _name, matching: find.byType(EditableText)),
    )
    .controller
    .text;

void main() {
  test('controller clones a collection and refreshes the list', () async {
    final bridge = _source();
    final controller = CollectionsController(bridge);
    await controller.start();
    final id = await controller.cloneCollection(_collection, 'Migraine');
    expect(controller.collections.map((item) => item.name), [
      'Headaches',
      'Migraine',
    ]);
    expect(bridge.clones, [(_collection, 'Migraine')]);
    expect(bridge.records[id], isEmpty);
    expect(bridge.records[_collection], hasLength(2));
    expect(bridge.schemas[id]!.fields.map((field) => field.name), ['Title']);
    expect(
      bridge.schemas[id]!.fields.single.id,
      isNot(bridge.schemas[_collection]!.fields.single.id),
    );
    final query = bridge.queryDefinitions[id]!.single;
    expect(query.id, isNot(_query.id));
    final widget = bridge.widgetDefinitions[id]!.single;
    expect(widget.id, isNot('widget-0'));
    expect(widget.queryId, query.id);
    controller.dispose();
  });

  testWidgets('Save without editing duplicates as "<name> (copy)"', (
    tester,
  ) async {
    final bridge = await _chooseDuplicate(tester);
    expect(find.text('Duplicate collection'), findsOneWidget);
    expect(_nameText(tester), 'Headaches (copy)');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.clones, [(_collection, 'Headaches (copy)')]);
    expect(find.text('Duplicate collection'), findsNothing);
    await pumpUntilFound(tester, find.text('Headaches (copy)'));
    // The list stays in view: duplicating never opens the copy.
    expect(find.text('Headaches'), findsOneWidget);
  });

  testWidgets('a custom name is trimmed and used', (tester) async {
    final bridge = await _chooseDuplicate(tester);
    await tester.enterText(_name, '  Migraine ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.clones, [(_collection, 'Migraine')]);
    await pumpUntilFound(tester, find.text('Migraine'));
  });

  testWidgets('Cancel sends no command', (tester) async {
    final bridge = await _chooseDuplicate(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.clones, isEmpty);
    expect(bridge.collections, hasLength(1));
    expect(find.text('Duplicate collection'), findsNothing);
  });

  testWidgets('a Rust name error stays inline and keeps the dialog open', (
    tester,
  ) async {
    final bridge = await _chooseDuplicate(tester);
    await tester.enterText(_name, '');
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [
        BridgeIssueDto(
          fields: ['name'],
          code: 'invalid',
          message: 'Name is required.',
        ),
      ],
      message: 'Name is required.',
      resetResolvable: false,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.clones, isEmpty);
    expect(find.text('Duplicate collection'), findsOneWidget);
    expect(
      find.descendant(of: _name, matching: find.text('Name is required.')),
      findsOneWidget,
    );
  });
}
