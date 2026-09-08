import 'package:fi/field_registry.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FieldDefinitionDto field(
  String id,
  FieldTypeKindDto kind, {
  int? scale,
  List<EnumOptionDto> options = const [],
}) => FieldDefinitionDto(
  id: id,
  name: id,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: false,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false),
  order: 0,
  deleted: false,
  enumOptions: options,
);

void main() {
  test('scaled decimals parse and format exactly at signed boundaries', () {
    expect(parseScaled('-12.30', 2), -1230);
    expect(formatScaled(-1230, 2), '-12.30');
    expect(parseScaled('-9223372036854775808', 0), -9223372036854775808);
    expect(parseScaled('9223372036854775808', 0), isNull);
    expect(parseScaled('1.001', 2), isNull);
  });

  testWidgets('registry displays every field kind with enum labels', (
    tester,
  ) async {
    const option = EnumOptionDto(
      id: 'option',
      label: 'Active',
      order: 0,
      deleted: false,
    );
    final cases = <(FieldDefinitionDto, FieldValueDto, String)>[
      (
        field('text', FieldTypeKindDto.text),
        const FieldValueDto(kind: FieldValueKindDto.text, textValue: 'hello'),
        'hello',
      ),
      (
        field('integer', FieldTypeKindDto.integer),
        const FieldValueDto(kind: FieldValueKindDto.integer, integerValue: -7),
        '-7',
      ),
      (
        field('decimal', FieldTypeKindDto.fixedDecimal, scale: 2),
        const FieldValueDto(
          kind: FieldValueKindDto.fixedDecimal,
          integerValue: -125,
        ),
        '-1.25',
      ),
      (
        field('boolean', FieldTypeKindDto.boolean),
        const FieldValueDto(
          kind: FieldValueKindDto.boolean,
          booleanValue: true,
        ),
        'Yes',
      ),
      (
        field('date', FieldTypeKindDto.date),
        const FieldValueDto(kind: FieldValueKindDto.date, integerValue: 1),
        '1970-01-02',
      ),
      (
        field('datetime', FieldTypeKindDto.dateTime),
        const FieldValueDto(kind: FieldValueKindDto.dateTime, integerValue: 0),
        DateTime.fromMillisecondsSinceEpoch(
          0,
          isUtc: true,
        ).toLocal().toString(),
      ),
      (
        field('duration', FieldTypeKindDto.duration),
        const FieldValueDto(
          kind: FieldValueKindDto.duration,
          integerValue: 90000,
        ),
        '90000 ms',
      ),
      (
        field('enum', FieldTypeKindDto.enum_, options: const [option]),
        const FieldValueDto(kind: FieldValueKindDto.enum_, textValue: 'option'),
        'Active',
      ),
    ];
    for (final (definition, value, expected) in cases) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldRendererRegistry().display(definition, value),
          ),
        ),
      );
      expect(find.text(expected), findsOneWidget);
    }
  });

  testWidgets('registry provides editors for every field kind', (tester) async {
    const option = EnumOptionDto(
      id: 'option',
      label: 'Active',
      order: 0,
      deleted: false,
    );
    final definitions = [
      field('text', FieldTypeKindDto.text),
      field('integer', FieldTypeKindDto.integer),
      field('decimal', FieldTypeKindDto.fixedDecimal, scale: 2),
      field('boolean', FieldTypeKindDto.boolean),
      field('date', FieldTypeKindDto.date),
      field('datetime', FieldTypeKindDto.dateTime),
      field('duration', FieldTypeKindDto.duration),
      field('enum', FieldTypeKindDto.enum_, options: const [option]),
    ];
    for (final definition in definitions) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FieldRendererRegistry().editor(definition, null, (_) {}),
          ),
        ),
      );
      expect(find.text(definition.name), findsOneWidget);
    }
  });
}
