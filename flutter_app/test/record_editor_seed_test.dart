import 'package:clock/clock.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _place = 'field-place';
const _pain = 'field-pain';

const _integer3 = FieldValueDto(
  kind: FieldValueKindDto.integer,
  integerValue: 3,
);

FieldDefinitionDto _placeField({FieldValueDto? defaultValue}) =>
    FieldDefinitionDto(
      id: _place,
      name: 'Place',
      fieldType: const FieldTypeDto(kind: FieldTypeKindDto.text),
      required_: false,
      defaultValue: defaultValue,
      validation: const ValidationMetadataDto(),
      display: const DisplayMetadataDto(
        multiline: false,
        slider: false,
        sliderStep: null,
      ),
      order: 0,
      deleted: false,
      enumOptions: const [],
    );

FieldDefinitionDto _painField({
  bool required = false,
  FieldValueDto? defaultValue,
}) => FieldDefinitionDto(
  id: _pain,
  name: 'Pain',
  fieldType: const FieldTypeDto(kind: FieldTypeKindDto.integer),
  required_: required,
  defaultValue: defaultValue,
  validation: const ValidationMetadataDto(minInteger: 1, maxInteger: 5),
  display: const DisplayMetadataDto(
    multiline: false,
    slider: true,
    sliderStep: null,
  ),
  order: 1,
  deleted: false,
  enumOptions: const [],
);

FakeCollectionBridge _seeded(
  List<FieldDefinitionDto> fields, {
  List<RecordDto> records = const [],
}) {
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
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'Headaches',
    description: '',
    fields: fields,
  );
  bridge.records[_collection] = [...records];
  return bridge;
}

Future<void> _openCollection(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.text('Headaches'));
  await tester.pumpAndSettle();
}

Future<void> _openNewRecord(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  await _openCollection(tester, bridge);
  await tester.tap(find.byTooltip('New record').first);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save record'));
  await tester.pumpAndSettle();
}

FieldValueDto? _stored(FakeCollectionBridge bridge, String fieldId) {
  for (final value in bridge.records[_collection]!.last.values) {
    if (value.fieldId == fieldId) return value.value;
  }
  return null;
}

String? _sliderError(WidgetTester tester) => decorationErrorText(
  tester
      .widget<InputDecorator>(
        find
            .descendant(
              of: find.byType(FiSlider),
              matching: find.byType(InputDecorator),
            )
            .first,
      )
      .decoration,
);

void main() {
  testWidgets('a Text default appears in its input', (tester) async {
    final bridge = _seeded([
      _placeField(
        defaultValue: const FieldValueDto(
          kind: FieldValueKindDto.text,
          textValue: 'Home',
        ),
      ),
    ]);
    await _openNewRecord(tester, bridge);
    expect(find.widgetWithText(TextFormField, 'Home'), findsOneWidget);
  });

  testWidgets('a slider default sets the thumb', (tester) async {
    final bridge = _seeded([_painField(defaultValue: _integer3)]);
    await _openNewRecord(tester, bridge);
    expect(find.byKey(const Key('slider-value')), findsOneWidget);
    expect(tester.widget<FiSlider>(find.byType(FiSlider)).value, 3);
    expect(find.byKey(const Key('slider-clear')), findsOneWidget);
  });

  testWidgets('a required slider without default opens at the minimum and '
      'saves it untouched', (tester) async {
    final bridge = _seeded([_painField(required: true)]);
    await _openNewRecord(tester, bridge);
    expect(tester.widget<FiSlider>(find.byType(FiSlider)).value, 1);
    await _save(tester);
    expect(find.text('New record'), findsNothing);
    expect(_stored(bridge, _pain)?.integerValue, 1);
  });

  testWidgets('clearing a seeded optional slider saves an explicit null', (
    tester,
  ) async {
    final bridge = _seeded([_painField(defaultValue: _integer3)]);
    await _openNewRecord(tester, bridge);
    await tester.tap(find.byKey(const Key('slider-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slider-unset')), findsOneWidget);
    await _save(tester);
    expect(_stored(bridge, _pain)?.kind, FieldValueKindDto.null_);
  });

  testWidgets('an existing invalid record lacking a required slider shows '
      'the unset track and the Rust error', (tester) async {
    final bridge = _seeded(
      [_placeField(), _painField(required: true)],
      records: const [
        RecordDto(
          id: 'record-0',
          collectionId: _collection,
          values: [
            RecordValueDto(
              fieldId: _place,
              value: FieldValueDto(
                kind: FieldValueKindDto.text,
                textValue: 'Office',
              ),
            ),
          ],
          valid: false,
          diagnostics: [
            DiagnosticDto(
              kind: 'record_validation',
              entityId: 'record-0',
              fieldId: _pain,
              message: 'Required',
            ),
          ],
        ),
      ],
    );
    await _openCollection(tester, bridge);
    await tester.tap(find.text('Office').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit record · 1 field needed'), findsOneWidget);
    expect(find.byKey(const Key('slider-unset')), findsOneWidget);
    expect(_sliderError(tester), 'Required');
  });

  testWidgets('editing an existing record does not seed defaults', (
    tester,
  ) async {
    final bridge = _seeded(
      [_placeField(), _painField(defaultValue: _integer3)],
      records: const [
        RecordDto(
          id: 'record-0',
          collectionId: _collection,
          values: [
            RecordValueDto(
              fieldId: _place,
              value: FieldValueDto(
                kind: FieldValueKindDto.text,
                textValue: 'Office',
              ),
            ),
          ],
          valid: true,
          diagnostics: [],
        ),
      ],
    );
    await _openCollection(tester, bridge);
    await tester.tap(find.text('Office').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit record'), findsOneWidget);
    expect(find.byKey(const Key('slider-unset')), findsOneWidget);
  });

  testWidgets('a relative Date default seeds local today plus its days', (
    tester,
  ) async {
    final bridge = _seeded([
      const FieldDefinitionDto(
        id: 'field-due',
        name: 'due',
        fieldType: FieldTypeDto(kind: FieldTypeKindDto.date),
        required_: false,
        defaultRelativeDays: 7,
        validation: ValidationMetadataDto(),
        display: DisplayMetadataDto(multiline: false, slider: false),
        order: 0,
        deleted: false,
        enumOptions: [],
      ),
    ]);
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 23, 30)), () async {
      await _openNewRecord(tester, bridge);
    });
    expect(find.widgetWithText(TextFormField, '2026-10-05'), findsOneWidget);
    expect(find.byKey(const Key('default-field-due')), findsOneWidget);
    await _save(tester);
    final expected =
        DateTime.utc(2026, 10, 5).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    expect(_stored(bridge, 'field-due')?.integerValue, expected);
  });

  testWidgets('changing a defaulted field drops its Default marker', (
    tester,
  ) async {
    final bridge = _seeded([
      _placeField(
        defaultValue: const FieldValueDto(
          kind: FieldValueKindDto.text,
          textValue: 'Home',
        ),
      ),
    ]);
    await _openNewRecord(tester, bridge);
    expect(find.byKey(const Key('default-$_place')), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Home'), 'Work');
    await tester.pump();
    expect(find.byKey(const Key('default-$_place')), findsNothing);
  });
}
