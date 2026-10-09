import 'package:clock/clock.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/choice_input.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

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
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
  order: 0,
  deleted: false,
  enumOptions: options,
);

/// An Integer field bounded to 1..5, optionally presented as a slider.
FieldDefinitionDto painField({
  bool slider = true,
  int min = 1,
  int max = 5,
  int? step,
}) => FieldDefinitionDto(
  id: 'pain',
  name: 'Pain',
  fieldType: const FieldTypeDto(kind: FieldTypeKindDto.integer),
  required_: false,
  validation: ValidationMetadataDto(minInteger: min, maxInteger: max),
  display: DisplayMetadataDto(
    multiline: false,
    slider: slider,
    sliderStep: step,
  ),
  order: 0,
  deleted: false,
  enumOptions: const [],
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
      // Now is hidden while the input holds a value; clearing brings it back.
      expect(find.byKey(const ValueKey('field-seen-now')), findsNothing);
      await tester.tap(find.byKey(const Key('input-clear')));
      await tester.pump();
      await withClock(Clock.fixed(lateEvening), () async {
        await tester.tap(find.byKey(const ValueKey('field-seen-now')));
      });
      await tester.pump();
      expect(inputText(tester), '2026-09-24 23:30');
      expect(emitted, hasLength(2));
      expect(emitted.first.kind, FieldValueKindDto.null_);
      expect(emitted.last.kind, FieldValueKindDto.dateTime);
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

  group('slider', () {
    Future<List<FieldValueDto>> pumpEditor(
      WidgetTester tester,
      FieldDefinitionDto definition, {
      FieldValueDto? initial,
    }) async {
      final emitted = <FieldValueDto>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const FieldRendererRegistry().editor(
              definition,
              initial,
              emitted.add,
            ),
          ),
        ),
      );
      return emitted;
    }

    testWidgets('a flagged bounded Integer renders as a slider', (
      tester,
    ) async {
      await pumpEditor(
        tester,
        painField(),
        initial: const FieldValueDto(
          kind: FieldValueKindDto.integer,
          integerValue: 2,
        ),
      );
      expect(find.byType(FiSlider), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect((slider.min, slider.max, slider.divisions), (1.0, 5.0, 4));
      expect(
        tester.widget<Text>(find.byKey(const Key('slider-value'))).data,
        '2',
      );
    });

    testWidgets('dragging reports an integer value', (tester) async {
      final emitted = await pumpEditor(
        tester,
        painField(),
        initial: const FieldValueDto(
          kind: FieldValueKindDto.integer,
          integerValue: 1,
        ),
      );
      await tester.drag(find.byType(Slider), const Offset(2000, 0));
      await tester.pump();
      expect(emitted.last.kind, FieldValueKindDto.integer);
      expect(emitted.last.integerValue, 5);
      expect(
        tester.widget<Text>(find.byKey(const Key('slider-value'))).data,
        '5',
      );
    });

    testWidgets('the step reaches the slider', (tester) async {
      await pumpEditor(
        tester,
        painField(min: 0, max: 100, step: 10),
        initial: const FieldValueDto(
          kind: FieldValueKindDto.integer,
          integerValue: 40,
        ),
      );
      expect(tester.widget<FiSlider>(find.byType(FiSlider)).step, 10);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect((slider.min, slider.max, slider.divisions), (0.0, 100.0, 10));
    });

    testWidgets('an unset slider reports nothing until touched, then clears '
        'to null', (tester) async {
      final emitted = await pumpEditor(tester, painField());
      expect(find.byKey(const Key('slider-unset')), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      await tester.pump();
      expect(emitted, isEmpty);
      await tester.tap(find.byType(Slider));
      await tester.pump();
      expect(emitted.single.kind, FieldValueKindDto.integer);
      expect(emitted.single.integerValue, 3);
      await tester.tap(find.byKey(const Key('slider-clear')));
      await tester.pump();
      expect(emitted.last.kind, FieldValueKindDto.null_);
      expect(find.byKey(const Key('slider-unset')), findsOneWidget);
    });

    for (final (width, full) in [(1280.0, true), (390.0, false)]) {
      testWidgets('the record editor labels the slider scale at '
          '${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const registry = FieldRendererRegistry();
        await tester.pumpWidget(
          MaterialApp(
            theme: nocturneTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyedSubtree(
                      key: const Key('text'),
                      child: registry.editor(
                        field('name', FieldTypeKindDto.text),
                        null,
                        (_) {},
                      ),
                    ),
                    registry.editor(
                      painField(min: 0, max: 100, step: 10),
                      null,
                      (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final ticks = [
          for (final element
              in find
                  .byWidgetPredicate(
                    (w) =>
                        w.key is ValueKey<String> &&
                        (w.key! as ValueKey<String>).value.startsWith(
                          'slider-tick-',
                        ),
                  )
                  .evaluate())
            (element.widget.key! as ValueKey<String>).value.substring(12),
        ];
        expect(
          ticks,
          full ? [for (var v = 0; v <= 100; v += 10) '$v'] : ['0', '100'],
        );
        final text = find
            .descendant(
              of: find.byKey(const Key('text')),
              matching: find.byType(InputDecorator),
            )
            .first;
        expect(tester.getSize(text).height, width < 720 ? 48 : 40);
        final slider = find
            .descendant(
              of: find.byType(FiSlider),
              matching: find.byType(InputDecorator),
            )
            .first;
        expect(
          tester.getSize(slider).height,
          greaterThan(tester.getSize(text).height),
        );
      });
    }

    testWidgets('without the flag the field is the plain integer input', (
      tester,
    ) async {
      await pumpEditor(tester, painField(slider: false));
      expect(find.byType(FiSlider), findsNothing);
      expect(find.byType(EditableText), findsOneWidget);
    });

    testWidgets('the record list shows a slider value as a plain number', (
      tester,
    ) async {
      const value = FieldValueDto(
        kind: FieldValueKindDto.integer,
        integerValue: 3,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const FieldRendererRegistry().display(painField(), value),
          ),
        ),
      );
      expect(find.text('3'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(
        const FieldRendererRegistry().displayText(
          painField(),
          value,
          human: true,
        ),
        '3',
      );
    });
  });

  group('record controls by kind', () {
    List<EnumOptionDto> options(int count, {List<String>? labels}) => [
      for (var i = 0; i < count; i++)
        EnumOptionDto(
          id: 'o$i',
          label: labels?[i] ?? 'option ${i + 1}',
          order: i,
          deleted: false,
        ),
    ];

    Future<List<FieldValueDto>> pumpForm(
      WidgetTester tester,
      double width,
      List<FieldDefinitionDto> fields, {
      Map<String, FieldValueDto> initial = const {},
    }) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final emitted = <FieldValueDto>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: nocturneTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                spacing: 12,
                children: [
                  for (final field in fields)
                    const FieldRendererRegistry().editor(
                      field,
                      initial[field.id],
                      emitted.add,
                      quickFill: true,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      return emitted;
    }

    const countries = [
      'Albania', 'Andorra', 'Austria', 'Belarus', 'Belgium', 'Bosnia', //
      'Bulgaria', 'Croatia', 'Cyprus', 'Czechia', 'Denmark', 'Estonia',
      'Finland', 'France', 'Germany', 'Greece', 'Hungary', 'Iceland',
      'Ireland', 'Italy', 'Kosovo', 'Latvia', 'Liechtenstein', 'Lithuania',
      'Luxembourg', 'Malta', 'Moldova', 'Monaco', 'Montenegro', 'Netherlands',
      'Norway', 'Poland', 'Portugal', 'Romania', 'Russia', 'San Marino',
      'Serbia', 'Singapore', 'Slovakia', 'Slovenia', 'Spain', 'Sweden',
      'Switzerland', 'Turkey', 'Ukraine', 'United Kingdom', 'Vatican', 'Wales',
    ];

    List<FieldDefinitionDto> choices() => [
      field('priority', FieldTypeKindDto.enum_, options: options(3)),
      field('weekday', FieldTypeKindDto.enum_, options: options(7)),
      field(
        'country',
        FieldTypeKindDto.enum_,
        options: options(48, labels: countries),
      ),
    ];

    testWidgets('choice follows the option count on a phone', (tester) async {
      final emitted = await pumpForm(tester, 390, choices());
      expect(find.byType(FiSegmented<String>), findsOneWidget);
      expect(find.text('option 1'), findsOneWidget);

      // 7 options: a picker sheet titled with the field name, Clear, and a check.
      await tester.tap(find.text('Choose…'));
      await tester.pumpAndSettle();
      expect(find.text('weekday'), findsWidgets);
      expect(find.byKey(const Key('choice-sheet-clear')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choice-row-o2')));
      await tester.pumpAndSettle();
      expect(emitted.last.textValue, 'o2');
      await tester.tap(find.text('option 3').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choice-selected')), findsOneWidget);
      Navigator.of(tester.element(find.text('Clear'))).pop();
      await tester.pumpAndSettle();

      // 48 options: a full-height search sheet with highlighted matches.
      await tester.tap(find.text('Search 48 options'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choice-search-sheet')), findsOneWidget);
      expect(find.text('48 options'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('choice-search-sheet'))).height,
        greaterThan(1000),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('choice-search')),
          matching: find.byType(TextField),
        ),
        'po',
      );
      await tester.pump();
      expect(find.text('3 of 48 match'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choice-row-o32')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choice-search-sheet')), findsNothing);
      expect(emitted.last.textValue, 'o32');
      expect(find.text('Portugal'), findsOneWidget);
    });

    testWidgets('choice follows the option count on desktop', (tester) async {
      final emitted = await pumpForm(tester, 1240, choices());
      expect(find.byType(FiSegmented<String>), findsOneWidget);
      expect(find.byType(FiSelect<String>), findsOneWidget);
      expect(find.byType(RawAutocomplete<ChoiceOption>), findsOneWidget);
      expect(find.text('Type to search 48 options'), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(RawAutocomplete<ChoiceOption>),
          matching: find.byType(TextField),
        ),
        'po',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('3 of 48'), findsOneWidget);
      await tester.tap(find.textContaining('rtugal', findRichText: true).first);
      await tester.pumpAndSettle();
      expect(emitted.last.textValue, 'o32');
    });

    testWidgets('a removed option reads "(deleted)" and is not offered', (
      tester,
    ) async {
      final kind = field(
        'kind',
        FieldTypeKindDto.enum_,
        options: [
          ...options(2),
          const EnumOptionDto(
            id: 'gone',
            label: 'option 3',
            order: 2,
            deleted: true,
          ),
        ],
      );
      const held = FieldValueDto(
        kind: FieldValueKindDto.enum_,
        textValue: 'gone',
      );
      await pumpForm(tester, 1240, [kind], initial: {'kind': held});
      expect(find.text('option 3 (deleted)'), findsOneWidget);
      expect(find.byKey(const ValueKey('segment-option 3')), findsNothing);
      expect(
        const FieldRendererRegistry().displayText(kind, held),
        'option 3 (deleted)',
      );
    });

    List<FieldDefinitionDto> choicesFields() => [
      field('mood', FieldTypeKindDto.enumSet, options: options(3)),
      field(
        'tags',
        FieldTypeKindDto.enumSet,
        options: options(7, labels: ['a', 'b', 'c', 'd', 'e', 'f', 'g']),
      ),
      field(
        'places',
        FieldTypeKindDto.enumSet,
        options: options(48, labels: countries),
      ),
    ];

    testWidgets('choices follow the option count on a phone', (tester) async {
      final emitted = await pumpForm(tester, 390, choicesFields());

      // 3 options: toggle chips with a check when on.
      expect(find.byKey(const Key('choices-chips')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choices-chip-o0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('choices-chip-o2')));
      await tester.pump();
      expect(emitted.last.kind, FieldValueKindDto.enumSet);
      expect(emitted.last.listValue, ['o0', 'o2']);
      expect(find.byKey(const Key('choices-chip-check')), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('choices-chip-o0')));
      await tester.pump();
      expect(emitted.last.listValue, ['o2']);

      // 7 options: a field that opens a checkbox sheet with Done.
      await tester.tap(find.text('Choose…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choices-sheet')), findsOneWidget);
      expect(find.byKey(const Key('choices-search')), findsNothing);
      expect(find.byType(Checkbox), findsNWidgets(7));
      await tester.tap(find.byKey(const ValueKey('choices-row-o4')));
      await tester.tap(find.byKey(const ValueKey('choices-row-o1')));
      await tester.pump();
      expect(find.text('2 picked'), findsOneWidget);
      await tester.tap(find.byKey(const Key('choices-sheet-done')));
      await tester.pumpAndSettle();
      expect(emitted.last.listValue, ['o1', 'o4']);
      expect(find.text('b, e'), findsOneWidget);

      // 48 options: the same sheet with a search.
      await tester.tap(find.text('Search 48 options'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('choices-search')), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('choices-search')),
          matching: find.byType(TextField),
        ),
        'po',
      );
      await tester.pump();
      expect(find.byType(Checkbox), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('choices-row-o32')));
      await tester.tap(find.byKey(const Key('choices-sheet-done')));
      await tester.pumpAndSettle();
      expect(emitted.last.listValue, ['o32']);
    });

    testWidgets('picked labels give way to "N picked" when they do not fit', (
      tester,
    ) async {
      final tags = field(
        'tags',
        FieldTypeKindDto.enumSet,
        options: options(
          7,
          labels: [for (var i = 0; i < 7; i++) 'a rather long label $i'],
        ),
      );
      await pumpForm(
        tester,
        390,
        [tags],
        initial: {
          'tags': const FieldValueDto(
            kind: FieldValueKindDto.enumSet,
            listValue: ['o0', 'o1', 'o2'],
          ),
        },
      );
      expect(find.text('3 picked'), findsOneWidget);
    });

    testWidgets('a removed member reads "(deleted)" and can be unpicked', (
      tester,
    ) async {
      final tags = field(
        'tags',
        FieldTypeKindDto.enumSet,
        options: [
          ...options(2),
          const EnumOptionDto(
            id: 'gone',
            label: 'urgent',
            order: 2,
            deleted: true,
          ),
        ],
      );
      const held = FieldValueDto(
        kind: FieldValueKindDto.enumSet,
        listValue: ['o0', 'gone'],
      );
      final emitted = await pumpForm(
        tester,
        1240,
        [tags],
        initial: {'tags': held},
      );
      expect(find.text('urgent (deleted)'), findsOneWidget);
      expect(
        const FieldRendererRegistry().displayText(tags, held),
        'option 1, urgent (deleted)',
      );
      await tester.tap(find.byKey(const ValueKey('choices-chip-gone')));
      await tester.pump();
      expect(emitted.last.listValue, ['o0']);
      expect(find.text('urgent (deleted)'), findsNothing);
    });

    testWidgets('list tags collapse the ones that do not fit into "+N"', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: nocturneTheme(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 150,
                child: ChoicesTagRow([
                  'work',
                  'urgent',
                  'food',
                  'travel',
                  'home',
                ]),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('choices-tag-more')), findsOneWidget);
      final shown = tester
          .widgetList(find.byType(Tag))
          .where((tag) => tag.key != const Key('choices-tag-more'))
          .length;
      expect(shown, inInclusiveRange(1, 4));
      expect(find.text('+${5 - shown}'), findsOneWidget);
    });

    testWidgets('booleans, decimals and durations use their controls', (
      tester,
    ) async {
      final requiredFlag = FieldDefinitionDto(
        id: 'done',
        name: 'done',
        fieldType: const FieldTypeDto(kind: FieldTypeKindDto.boolean),
        required_: true,
        validation: const ValidationMetadataDto(),
        display: const DisplayMetadataDto(multiline: false, slider: false),
        order: 0,
        deleted: false,
        enumOptions: const [],
      );
      final emitted = await pumpForm(tester, 1240, [
        requiredFlag,
        field('flag', FieldTypeKindDto.boolean),
        field('amount', FieldTypeKindDto.fixedDecimal, scale: 2),
        field('spent', FieldTypeKindDto.duration),
      ]);
      expect(find.byType(FiSwitch), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
      expect(find.text('2 dp'), findsOneWidget);
      expect(find.byType(FiDurationInput), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(emitted.last.booleanValue, isTrue);
      await tester.tap(find.text('Yes'));
      await tester.pump();
      expect(emitted.last.kind, FieldValueKindDto.null_);
    });
  });

  testWidgets(
    'a Spanish decimal input takes a comma and stores the exact value',
    (tester) async {
      addTearDown(() => Intl.defaultLocale = null);
      final amount = field('amount', FieldTypeKindDto.fixedDecimal, scale: 2);
      FieldValueDto? stored;
      Widget host(FieldValueDto? value) => MaterialApp(
        locale: const Locale('es'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Column(
            children: [
              const FieldRendererRegistry().editor(
                amount,
                value,
                (updated) => stored = updated,
              ),
              const FieldRendererRegistry().display(amount, value),
            ],
          ),
        ),
      );
      await tester.pumpWidget(host(null));
      await tester.enterText(find.byType(TextField), '12,50');
      expect(stored?.integerValue, 1250);
      await tester.pumpWidget(host(stored));
      expect(find.text('12,50'), findsWidgets);
    },
  );
}
