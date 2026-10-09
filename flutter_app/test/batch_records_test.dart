import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
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
    const CollectionDto(
      id: _collection,
      name: 'Headaches',
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
    ),
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
        display: DisplayMetadataDto(
          multiline: false,
          slider: false,
          sliderStep: null,
        ),
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
    expect(find.byTooltip('Record actions'), findsNWidgets(3));

    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(
      find.byTooltip('Record actions'),
      findsNothing,
      reason: 'the row menu is hidden while selecting',
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
    expect(find.byTooltip('Record actions'), findsNWidgets(3));
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
    // Delete is the secondary action at the leading edge; Keep records is the primary one.
    final delete = find.byKey(const Key('confirm-batch-delete'));
    final keep = find.byKey(const Key('dismiss-batch-delete'));
    expect(tester.widget(delete), isA<TextButton>());
    expect(tester.widget(keep), isA<FilledButton>());
    expect(
      find.descendant(of: keep, matching: find.text('Keep records')),
      findsOneWidget,
    );
    expect(tester.getCenter(delete).dx, lessThan(tester.getCenter(keep).dx));

    // Keep records sends nothing and leaves the selection intact.
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
    expect(find.text('Deleted 3 records'), findsOneWidget);
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
    expect(find.text('New value'), findsOneWidget);
    expect(
      find.text('Uses the same control as the record form.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField).last, 'triage');
    await tester.tap(find.byKey(const Key('batch-edit-continue')));
    await tester.pumpAndSettle();
    expect(find.text('Set Title on 2 records?'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('confirm-batch-edit')),
        matching: find.text('Set Title'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('confirm-batch-edit')));
    await tester.pumpAndSettle();

    expect(bridge.batchFieldCalls, hasLength(1), reason: 'one batch call');
    expect(bridge.batchFieldCalls.single, hasLength(2));
    expect(find.text('Set Title on 2 records'), findsOneWidget);
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

  testWidgets('the desktop action bar reads Edit field', (tester) async {
    tester.view.physicalSize = const Size(1240, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byKey(const Key('select-records')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 0'));
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('in Headaches'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('batch-edit')),
        matching: find.text('Edit field'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('selection-clone')),
        matching: find.text('Clone'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a selected phone card has the accent outline', (tester) async {
    useDarkPlatform(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    BorderSide side(String id) =>
        (tester.widget<Material>(find.byKey(ValueKey(id))).shape!
                as RoundedRectangleBorder)
            .side;
    expect(side('record-0').color, NocturneColors.mocha.accent);
    expect(side('record-0').width, 1);
    expect(side('record-1').color, isNot(NocturneColors.mocha.accent));
    expect(
      tester.widget<Material>(find.byKey(const ValueKey('record-0'))).color,
      NocturneColors.mocha.accentFill,
    );
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(
              of: find.byKey(const ValueKey('record-0')),
              matching: find.byType(Checkbox),
            ),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('single delete outside selection mode has no dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byTooltip('Delete record').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.batchDeleteCalls, isEmpty);
    expect(find.text('row 0'), findsNothing);
    expect(find.text('row 1'), findsOneWidget);
  });

  testWidgets('selection Clone sends one command and Undo deletes the copies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 1'));
    await tester.tap(find.text('row 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selection-clone')));
    await tester.pumpAndSettle();
    expect(bridge.batchCloneCalls, [
      ['record-0', 'record-1', 'record-2'],
    ]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Cloned 3 records'), findsOneWidget);
    expect(find.text('3 selected'), findsNothing);
    expect(bridge.records[_collection], hasLength(6));
    final created = [
      for (final record in bridge.records[_collection]!.skip(3)) record.id,
    ];

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(bridge.batchDeleteCalls, [created]);
    expect(bridge.records[_collection]!.map((record) => record.id), [
      'record-0',
      'record-1',
      'record-2',
    ]);
  });

  testWidgets('cloning one record says Cloned 1 record', (tester) async {
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selection-clone')));
    await tester.pumpAndSettle();
    expect(bridge.batchCloneCalls, [
      ['record-0'],
    ]);
    expect(find.text('Cloned 1 record'), findsOneWidget);
    expect(find.text('row 0'), findsNWidgets(2));
  });

  testWidgets('the wide row menu clones through the prefilled form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byKey(const Key('record-row-menu-record-0')));
    await tester.pumpAndSettle();
    expect(find.text('Clone'), findsOneWidget);
    expect(find.text('Delete…'), findsOneWidget);
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(find.text('New record'), findsWidgets);
    expect(find.text('Clone of ‘row 0’'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'row 0'), findsOneWidget);
    expect(bridge.records[_collection], hasLength(2));
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(bridge.records[_collection], hasLength(3));
    expect(bridge.batchCloneCalls, isEmpty);
  });

  testWidgets('the wide row menu Delete… confirms first', (tester) async {
    tester.view.physicalSize = const Size(1240, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byKey(const Key('record-row-menu-record-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const Key('dismiss-record-delete')));
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('record-row-menu-record-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-record-delete')));
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing);
    expect(find.text('row 1'), findsOneWidget);
  });
}
