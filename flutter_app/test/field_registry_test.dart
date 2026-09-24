import 'package:clock/clock.dart';
import 'package:fi/exact_format.dart';
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

  group('quick fill', () {
    /// Local 23:30:37.250, late enough that the UTC day is often already the next one.
    final lateEvening = DateTime(2026, 9, 24, 23, 30, 37, 250);

    Future<List<FieldValueDto>> pumpEditor(
      WidgetTester tester,
      FieldDefinitionDto definition, {
      FieldValueDto? initial,
      bool quickFill = true,
    }) async {
      final emitted = <FieldValueDto>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const FieldRendererRegistry().editor(
              definition,
              initial,
              emitted.add,
              quickFill: quickFill,
            ),
          ),
        ),
      );
      return emitted;
    }

    String inputText(WidgetTester tester) =>
        tester.widget<EditableText>(find.byType(EditableText)).controller.text;

    testWidgets('Today fills the local calendar day, not the UTC one', (
      tester,
    ) async {
      final emitted = await pumpEditor(
        tester,
        field('onset', FieldTypeKindDto.date),
      );
      await withClock(Clock.fixed(lateEvening), () async {
        await tester.tap(find.byKey(const ValueKey('field-onset-today')));
      });
      await tester.pump();

      final expected =
          DateTime.utc(2026, 9, 24).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay;
      expect(emitted.single.kind, FieldValueKindDto.date);
      expect(emitted.single.integerValue, expected);
      expect(inputText(tester), '2026-09-24');
    });

    testWidgets('Now fills the local minute as UTC milliseconds', (
      tester,
    ) async {
      final emitted = await pumpEditor(
        tester,
        field('seen', FieldTypeKindDto.dateTime),
      );
      await withClock(Clock.fixed(lateEvening), () async {
        await tester.tap(find.byKey(const ValueKey('field-seen-now')));
      });
      await tester.pump();

      final expected = DateTime(
        2026,
        9,
        24,
        23,
        30,
      ).toUtc().millisecondsSinceEpoch;
      expect(emitted.single.kind, FieldValueKindDto.dateTime);
      expect(emitted.single.integerValue, expected);
      expect(emitted.single.integerValue! % 60000, 0);
      expect(inputText(tester), '2026-09-24 23:30');
    });

    testWidgets('Now replaces an existing value', (tester) async {
      final emitted = await pumpEditor(
        tester,
        field('seen', FieldTypeKindDto.dateTime),
        initial: FieldValueDto(
          kind: FieldValueKindDto.dateTime,
          integerValue: DateTime(
            2020,
            1,
            2,
            3,
            4,
          ).toUtc().millisecondsSinceEpoch,
        ),
      );
      expect(inputText(tester), '2020-01-02 03:04');
      await withClock(Clock.fixed(lateEvening), () async {
        await tester.tap(find.byKey(const ValueKey('field-seen-now')));
      });
      await tester.pump();
      expect(inputText(tester), '2026-09-24 23:30');
      expect(emitted, hasLength(1));
    });

    testWidgets('an existing DateTime opens as local yyyy-MM-dd HH:mm', (
      tester,
    ) async {
      final instant = DateTime(2026, 9, 24, 23, 0).toUtc();
      await pumpEditor(
        tester,
        field('seen', FieldTypeKindDto.dateTime),
        initial: FieldValueDto(
          kind: FieldValueKindDto.dateTime,
          integerValue: instant.millisecondsSinceEpoch,
        ),
      );
      expect(inputText(tester), '2026-09-24 23:00');
      expect(
        formatDateTime(instant.millisecondsSinceEpoch),
        '2026-09-24 23:00',
      );
    });

    testWidgets('editors without quick fill offer neither action', (
      tester,
    ) async {
      await pumpEditor(
        tester,
        field('onset', FieldTypeKindDto.date),
        quickFill: false,
      );
      expect(find.text('Today'), findsNothing);
      await pumpEditor(
        tester,
        field('seen', FieldTypeKindDto.dateTime),
        quickFill: false,
      );
      expect(find.text('Now'), findsNothing);
    });
  });
}
