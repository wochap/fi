import 'package:fi/src/rust/api/models.dart';
import 'package:fi/controllers.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _missing = 'field-text-multiline';

FieldDefinitionDto _field(
  String id,
  String name,
  FieldTypeKindDto kind,
  int order, {
  bool required = false,
}) => FieldDefinitionDto(
  id: id,
  name: name,
  fieldType: FieldTypeDto(kind: kind),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
  order: order,
  deleted: false,
  enumOptions: const [],
);

/// Nine fields: an Integer "integer slider" first, a required Text "text multiline" second.
final _fields = [
  _field('field-integer', 'integer slider', FieldTypeKindDto.integer, 0),
  _field(_missing, 'text multiline', FieldTypeKindDto.text, 1, required: true),
  for (var i = 2; i < 9; i++)
    _field('field-$i', 'extra $i', FieldTypeKindDto.text, i),
];

final _created = DateTime(2026, 9, 22, 10, 15);

RecordDto _record(
  String id, {
  int? integer,
  String? text,
  int? createdAtMs,
  bool incomplete = false,
}) => RecordDto(
  id: id,
  collectionId: _collection,
  values: [
    if (integer != null)
      RecordValueDto(
        fieldId: 'field-integer',
        value: FieldValueDto(
          kind: FieldValueKindDto.integer,
          integerValue: integer,
        ),
      ),
    if (text != null)
      RecordValueDto(
        fieldId: _missing,
        value: FieldValueDto(kind: FieldValueKindDto.text, textValue: text),
      ),
  ],
  valid: !incomplete,
  diagnostics: [
    if (incomplete)
      DiagnosticDto(
        kind: 'record_validation',
        entityId: id,
        fieldId: _missing,
        message: 'required field is missing',
      ),
  ],
  createdAtMs: createdAtMs,
);

FakeCollectionBridge _seed(List<RecordDto> records) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: _collection,
      name: 'test',
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
    ),
  );
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'test',
    description: '',
    fields: _fields,
  );
  bridge.records[_collection] = records;
  return bridge;
}

Future<void> _open(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('test'));
  await tester.tap(find.text('test'));
  await tester.pumpAndSettle();
}

const _desktop = Size(1240, 900);
const _phone = Size(390, 844);

void main() {
  group('desktop table', () {
    testWidgets('headers carry the type icon and the required mark', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([_record('r1', integer: 3, text: 'a')]),
        _desktop,
      );
      final integer = find.byKey(const Key('column-header-field-integer'));
      final text = find.byKey(const Key('column-header-$_missing'));
      expect(
        find.descendant(of: integer, matching: find.byIcon(FiIcons.integer)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: integer, matching: find.text('INTEGER SLIDER')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: integer, matching: find.text(' *')),
        findsNothing,
      );
      expect(
        find.descendant(of: text, matching: find.byIcon(FiIcons.text)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: text, matching: find.text(' *')),
        findsOneWidget,
      );
      // Empty cells read as a dash.
      expect(find.text('—'), findsWidgets);
    });

    testWidgets(
      'the first column and header stay put while scrolling sideways',
      (tester) async {
        await _open(
          tester,
          _seed([
            for (var i = 0; i < 30; i++)
              _record('r$i', integer: i, text: 'row $i', createdAtMs: 1000 + i),
          ]),
          _desktop,
        );
        final table = find.byKey(const Key('records-table'));
        final first = find.byKey(const Key('column-header-field-integer'));
        final second = find.byKey(const Key('column-header-$_missing'));
        final hint = find.byKey(const Key('table-scroll-hint'));
        expect(hint, findsOneWidget);
        expect(find.text('Scroll for more columns →'), findsOneWidget);
        final firstBefore = tester.getTopLeft(first);
        final secondBefore = tester.getTopLeft(second);
        final newest = tester.getTopLeft(find.text('29').first);

        await tester.drag(table, const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(first), firstBefore);
        expect(tester.getTopLeft(find.text('29').first), newest);
        expect(tester.getTopLeft(second).dx, lessThan(secondBefore.dx));
        expect(tester.getTopLeft(second).dy, secondBefore.dy);

        // Vertically the header row stays while the rows move.
        await tester.drag(table, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(first), firstBefore);

        // Once the last column is in view the hint goes.
        await tester.drag(table, const Offset(-3000, 0));
        await tester.pumpAndSettle();
        expect(hint, findsNothing);
      },
    );

    testWidgets('an incomplete row is marked and the status line explains', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([
          _record('r1', integer: 7, incomplete: true),
          _record('r2', integer: 8, text: 'done'),
        ]),
        _desktop,
      );
      expect(find.byKey(const Key('required-cell')), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      expect(find.byIcon(FiIcons.warning), findsNWidgets(2));
      expect(
        find.text('1 record is missing a required field. Click it to finish.'),
        findsOneWidget,
      );
    });

    testWidgets('the status line is plural for several records', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([
          _record('r1', integer: 7, incomplete: true),
          _record('r2', integer: 8, incomplete: true),
        ]),
        _desktop,
      );
      expect(
        find.text(
          '2 records are missing a required field. Click one to finish.',
        ),
        findsOneWidget,
      );
    });
  });

  group('phone cards', () {
    testWidgets('a card shows three fields, then what is left and the date', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([
          _record(
            'r1',
            integer: 4,
            text: 'hello',
            createdAtMs: _created.millisecondsSinceEpoch,
          ),
        ]),
        _phone,
      );
      expect(find.text('Newest first'), findsOneWidget);
      expect(find.text('integer slider'), findsOneWidget);
      expect(find.text('text multiline'), findsOneWidget);
      expect(find.text('extra 2'), findsOneWidget);
      expect(find.text('extra 3'), findsNothing);
      expect(find.byIcon(FiIcons.integer), findsOneWidget);
      expect(find.text('+ 6 more fields · Sep 22, 2026'), findsOneWidget);
    });

    testWidgets('records are newest first, undated ones last by id', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([
          _record('r-b', integer: 1),
          _record('r-old', integer: 2, createdAtMs: 1000),
          _record('r-a', integer: 3),
          _record('r-new', integer: 4, createdAtMs: 5000),
        ]),
        _phone,
      );
      final tops = [
        for (final id in ['r-new', 'r-old', 'r-a', 'r-b'])
          tester.getTopLeft(find.byKey(ValueKey(id))).dy,
      ];
      expect(tops, [...tops]..sort());
    });

    testWidgets('an incomplete card is tagged and its field reads Needed', (
      tester,
    ) async {
      await _open(
        tester,
        _seed([_record('r1', integer: 7, incomplete: true)]),
        _phone,
      );
      expect(find.byKey(const Key('record-incomplete-r1')), findsOneWidget);
      expect(find.text('Incomplete'), findsOneWidget);
      expect(find.byType(NeededMarker), findsOneWidget);
      expect(find.text('1 record is missing a required field'), findsOneWidget);
      expect(find.text('Tap it to finish.'), findsOneWidget);
    });

    test('newestFirst orders by creation time, then id', () {
      final ordered = newestFirst([
        _record('b'),
        _record('x', createdAtMs: 1),
        _record('a'),
        _record('z', createdAtMs: 9),
        _record('y', createdAtMs: 9),
      ]);
      expect(ordered.map((r) => r.id), ['y', 'z', 'x', 'a', 'b']);
    });
  });

  group('phone header', () {
    testWidgets('back, title, counts, Schema, and a ⋮ menu', (tester) async {
      final bridge = _seed([_record('r1', integer: 1, text: 'x')]);
      await _open(tester, bridge, _phone);
      final header = find.byKey(const Key('collection-phone-header'));
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: header, matching: find.text('1 record · 9 fields')),
        findsOneWidget,
      );
      expect(find.byTooltip('Back to collections'), findsOneWidget);
      expect(find.byTooltip('Schema'), findsOneWidget);
      expect(find.text('Record'), findsOneWidget);
      await tester.tap(find.byKey(const Key('collection-more')));
      await tester.pumpAndSettle();
      expect(find.text('Queries'), findsOneWidget);
      expect(find.text('Select records'), findsOneWidget);
      expect(find.text('Collection actions…'), findsOneWidget);

      await tester.tap(find.text('Collection actions…'));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate'), findsOneWidget);
      expect(find.text('Delete…'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('collection-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select records'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
    });

    testWidgets('a long press on a card starts selection', (tester) async {
      await _open(
        tester,
        _seed([_record('r1', integer: 1, text: 'x')]),
        _phone,
      );
      await tester.longPress(find.byKey(const ValueKey('r1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
    });
  });

  group('finishing an incomplete record', () {
    testWidgets('opens on the missing field, focused, and the marks clear', (
      tester,
    ) async {
      final bridge = _seed([_record('r1', integer: 7, incomplete: true)]);
      await _open(tester, bridge, _desktop);
      await tester.tap(find.text('7'));
      await tester.pumpAndSettle();
      expect(find.text('Edit record · 1 field needed'), findsOneWidget);
      final needed = find.byKey(const Key('needed-$_missing'));
      expect(needed, findsOneWidget);
      expect(
        find.descendant(of: needed, matching: find.byType(NeededMarker)),
        findsOneWidget,
      );
      expect(find.text('Needed to complete this record'), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find
            .descendant(of: needed, matching: find.byWidget(focused!.widget))
            .evaluate(),
        isNotEmpty,
      );

      await tester.enterText(
        find.descendant(of: needed, matching: find.byType(EditableText)),
        'finished',
      );
      await tester.pump();
      expect(find.text('Needed to complete this record'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Edit record · 1 field needed'), findsNothing);
      expect(find.byKey(const Key('required-cell')), findsNothing);
      expect(find.byKey(const Key('incomplete-status')), findsNothing);
      expect(find.text('finished'), findsOneWidget);
    });
  });
}
