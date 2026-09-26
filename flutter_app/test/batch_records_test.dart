import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _title = 'field-title';

/// A ready bridge holding one collection with a text `Title` field and
/// [count] records, so a test starts in the record list.
FakeCollectionBridge seeded(int count) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(id: _collection, name: 'Headaches', description: ''),
  );
  bridge.schemas[_collection] = const CollectionSchemaDto(
    id: _collection,
    name: 'Headaches',
    description: '',
    fields: [
      FieldDefinitionDto(
        id: _title,
        name: 'Title',
        fieldType: FieldTypeDto(kind: FieldTypeKindDto.text),
        required_: false,
        validation: ValidationMetadataDto(),
        display: DisplayMetadataDto(multiline: false, slider: false),
        order: 0,
        deleted: false,
        enumOptions: [],
      ),
    ],
  );
  bridge.records[_collection] = [
    for (var index = 0; index < count; index++)
      RecordDto(
        id: 'record-$index',
        collectionId: _collection,
        values: [
          RecordValueDto(
            fieldId: _title,
            value: FieldValueDto(
              kind: FieldValueKindDto.text,
              textValue: 'row $index',
            ),
          ),
        ],
        valid: true,
        diagnostics: const [],
      ),
  ];
  return bridge;
}

Future<void> openCollection(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.text('Headaches'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long press enters selection mode and counts the selection', (
    tester,
  ) async {
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    expect(find.byTooltip('Delete record'), findsNWidgets(3));

    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.byTooltip('Delete record'),
      findsNothing,
      reason: 'the per-tile delete is hidden while selecting',
    );
    expect(find.byType(Checkbox), findsNWidgets(3));

    // A tap toggles instead of opening the record editor.
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Edit record'), findsNothing);

    await tester.tap(find.byKey(const Key('cancel-selection')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsNothing);
    expect(find.byTooltip('Delete record'), findsNWidgets(3));
  });

  testWidgets('the header Select action opens an empty selection', (
    tester,
  ) async {
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byKey(const Key('select-records')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(find.text('row 0'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('batch delete confirms with the count, then reports it', (
    tester,
  ) async {
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 2'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('batch-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 3 records?'), findsOneWidget);

    // Dismissing sends nothing and leaves the selection intact.
    await tester.tap(find.byKey(const Key('dismiss-batch-delete')));
    await tester.pumpAndSettle();
    expect(bridge.batchDeleteCalls, isEmpty);
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('batch-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-batch-delete')));
    await tester.pumpAndSettle();
    expect(bridge.batchDeleteCalls, hasLength(1), reason: 'one batch call');
    expect(bridge.batchDeleteCalls.single, hasLength(3));
    expect(find.text('3 records deleted'), findsOneWidget);
    expect(find.text('No records yet.'), findsOneWidget);
  });

  testWidgets('batch edit names the field and the count, then reports it', (
    tester,
  ) async {
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('batch-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit field on 2 records'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, 'triage');
    await tester.tap(find.byKey(const Key('batch-edit-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Set Title on 2 records?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-batch-edit')));
    await tester.pumpAndSettle();

    expect(bridge.batchFieldCalls, hasLength(1), reason: 'one batch call');
    expect(bridge.batchFieldCalls.single, hasLength(2));
    expect(find.text('2 records updated'), findsOneWidget);
    expect(find.text('triage'), findsNWidgets(2));
  });

  testWidgets('a rejected batch stays in selection mode with the error', (
    tester,
  ) async {
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    bridge.nextBatchError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [
        BridgeIssueDto(
          fields: ['batch'],
          code: 'invalid',
          message: 'member 0 (record record-0): record not found',
        ),
      ],
      message: 'member 0 (record record-0): record not found',
      resetResolvable: false,
    );
    await tester.tap(find.byKey(const Key('batch-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-batch-delete')));
    await tester.pumpAndSettle();

    expect(
      find.text('member 0 (record record-0): record not found'),
      findsOneWidget,
      reason: 'the typed error lands on the banner',
    );
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('row 0'), findsOneWidget);
  });

  testWidgets('single delete outside selection mode has no dialog', (
    tester,
  ) async {
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byTooltip('Delete record').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.batchDeleteCalls, isEmpty);
    expect(find.text('row 0'), findsNothing);
    expect(find.text('row 1'), findsOneWidget);
  });
}
