import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _note = 'field-note';
const _kind = 'field-kind';

/// 2026-09-22T10:15:00Z.
const _createdMs = 1790072100000;

FieldDefinitionDto _field(
  String id,
  String name,
  FieldTypeKindDto kind, {
  List<EnumOptionDto> options = const [],
  int order = 0,
}) => FieldDefinitionDto(
  id: id,
  name: name,
  fieldType: FieldTypeDto(kind: kind),
  required_: false,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false, slider: false),
  order: order,
  deleted: false,
  enumOptions: options,
);

const _held = RecordDto(
  id: 'record-held',
  collectionId: _collection,
  values: [
    RecordValueDto(
      fieldId: _note,
      value: FieldValueDto(kind: FieldValueKindDto.text, textValue: 'Buy oat'),
    ),
    RecordValueDto(
      fieldId: _kind,
      value: FieldValueDto(kind: FieldValueKindDto.enum_, textValue: 'o3'),
    ),
  ],
  valid: true,
  diagnostics: [],
  createdAtMs: _createdMs,
);

FakeCollectionBridge _seeded({List<RecordDto> records = const []}) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: _collection,
      name: 'tst',
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
    ),
  );
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'tst',
    description: '',
    fields: [
      _field(_note, 'note', FieldTypeKindDto.text),
      _field(
        _kind,
        'kind',
        FieldTypeKindDto.enum_,
        order: 1,
        options: const [
          EnumOptionDto(id: 'o1', label: 'option 1', order: 0, deleted: false),
          EnumOptionDto(id: 'o2', label: 'option 2', order: 1, deleted: false),
          EnumOptionDto(id: 'o3', label: 'option 3', order: 2, deleted: true),
        ],
      ),
    ],
  );
  bridge.records[_collection] = [...records];
  return bridge;
}

Future<void> _open(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('tst'));
  await tester.tap(find.text('tst'));
  await tester.pumpAndSettle();
}

Future<void> _newRecord(WidgetTester tester) async {
  final tip = find.byTooltip('New record');
  await tester.tap(
    tip.evaluate().isNotEmpty ? tip.first : find.text('New record').first,
  );
  await tester.pumpAndSettle();
}

const _desktop = Size(1240, 900);
const _phone = Size(390, 844);

Finder _noteInput() => find.descendant(
  of: find.byKey(const ValueKey('record-field-$_note')),
  matching: find.byType(TextField),
);

void main() {
  testWidgets('new record on desktop: hint, Cancel, Save record, Ctrl+Enter', (
    tester,
  ) async {
    final bridge = _seeded();
    await _open(tester, bridge, _desktop);
    await _newRecord(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('New record'),
      ),
      findsOneWidget,
    );
    expect(find.text('in tst'), findsOneWidget);
    expect(find.byKey(const Key('form-footer-hint')), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save record'), findsOneWidget);
    // Labels sit in a column beside the controls.
    expect(
      tester.getTopLeft(_noteInput()).dx,
      greaterThan(tester.getTopRight(find.text('note')).dx),
    );

    await tester.enterText(_noteInput(), 'Groceries');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(bridge.records[_collection], hasLength(1));
  });

  testWidgets('new record on a phone: close ✕ and a full-width Save record', (
    tester,
  ) async {
    await _open(tester, _seeded(), _phone);
    await _newRecord(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('New record'), findsOneWidget);
    expect(find.text('in tst'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsNothing);
    final save = find.widgetWithText(FilledButton, 'Save record');
    expect(tester.getSize(save).height, 52);
    expect(
      tester.getSize(save).width,
      closeTo(tester.getSize(find.byType(BottomSheet)).width - 36, 1),
    );
    // Labels sit above the controls.
    expect(
      tester.getTopLeft(_noteInput()).dy,
      greaterThan(tester.getBottomLeft(find.text('note')).dy),
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('edit record on desktop: created date, Save changes, Delete…', (
    tester,
  ) async {
    final bridge = _seeded(records: const [_held]);
    await _open(tester, bridge, _desktop);
    await tester.tap(find.text('Buy oat').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit record'), findsOneWidget);
    expect(find.text('in tst · created Sep 22, 2026'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    final delete = find.byKey(const Key('record-delete'));
    expect(
      tester.getTopLeft(delete).dx,
      lessThan(tester.getTopLeft(find.text('Cancel')).dx),
    );
    // The held removed option reads "(deleted)" and is not offered.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('option 3 (deleted)'),
      ),
      findsOneWidget,
    );

    await tester.enterText(_noteInput(), 'Buy oat milk');
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dismiss-record-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Buy oat milk'), findsOneWidget);

    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-record-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(bridge.records[_collection], isEmpty);
  });

  testWidgets('saving an edit sends only the changed field and keeps a '
      'removed option', (tester) async {
    final bridge = _seeded(records: const [_held]);
    await _open(tester, bridge, _desktop);
    await tester.tap(find.text('Buy oat').first);
    await tester.pumpAndSettle();
    await tester.enterText(_noteInput(), 'Buy oat milk');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(bridge.fieldUpdates.map((update) => update.$2), [_note]);
    final stored = bridge.records[_collection]!.single.values;
    expect(
      stored.firstWhere((value) => value.fieldId == _kind).value.textValue,
      'o3',
    );
  });

  testWidgets('duplicate on a phone opens a prefilled new record', (
    tester,
  ) async {
    final bridge = _seeded(records: const [_held]);
    await _open(tester, bridge, _phone);
    await tester.tap(find.text('Buy oat').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit record'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Delete record…'), findsOneWidget);
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(find.text('New record'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Buy oat'), findsOneWidget);
    expect(bridge.records[_collection], hasLength(1));
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(bridge.records[_collection], hasLength(2));
    // The removed option is not carried into the copy.
    expect(
      bridge.records[_collection]!.last.values.map((value) => value.fieldId),
      [_note],
    );
  });

  testWidgets('delete from the phone ⋮ asks first', (tester) async {
    final bridge = _seeded(records: const [_held]);
    await _open(tester, bridge, _phone);
    await tester.tap(find.text('Buy oat').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete record…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this record?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-record-delete')));
    await tester.pumpAndSettle();
    expect(bridge.records[_collection], isEmpty);
    expect(find.byType(BottomSheet), findsNothing);
  });
}
