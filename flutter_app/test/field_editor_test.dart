import 'dart:ui' show PointerDeviceKind, Tristate;

import 'package:clock/clock.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/field_editor.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

FieldDefinitionDto _field(
  String name,
  FieldTypeKindDto kind, {
  bool required = false,
  int order = 0,
}) => FieldDefinitionDto(
  id: '',
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

final class Seeded {
  Seeded(this.bridge, this.controller, this.collectionId);
  final FakeCollectionBridge bridge;
  final CollectionsController controller;
  final String collectionId;
}

/// A collection with Intensity and Notes, and one record that holds only Intensity.
Future<Seeded> seed(WidgetTester tester, {int recordsWithNotes = 0}) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1400);

  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  final controller = CollectionsController(bridge);
  addTearDown(controller.dispose);
  await controller.start();
  final collectionId = await controller.createCollection('Headaches');
  await controller.selectCollection(collectionId);
  await controller.addField(_field('Intensity', FieldTypeKindDto.integer));
  await controller.addField(_field('Notes', FieldTypeKindDto.text, order: 1));
  final intensity = controller.schema!.fields
      .firstWhere((field) => field.name == 'Intensity')
      .id;
  final notes = controller.schema!.fields
      .firstWhere((field) => field.name == 'Notes')
      .id;
  await controller.createRecord([
    RecordValueDto(
      fieldId: intensity,
      value: const FieldValueDto(
        kind: FieldValueKindDto.integer,
        integerValue: 7,
      ),
      // Notes is deliberately absent so making it required invalidates this record.
    ),
    if (recordsWithNotes > 0)
      RecordValueDto(
        fieldId: notes,
        value: const FieldValueDto(
          kind: FieldValueKindDto.text,
          textValue: 'after lunch',
        ),
      ),
  ]);
  return Seeded(bridge, controller, collectionId);
}

Future<void> pumpPage(
  WidgetTester tester,
  CollectionsController controller, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => CollectionsPage(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openFieldEditor(WidgetTester tester, String fieldName) async {
  await tester.tap(find.text('Schema'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(fieldName));
  await tester.pumpAndSettle();
}

Future<void> toggleRequired(WidgetTester tester) => tapChip(tester, 'required');

/// Taps the field editor's option chip keyed `chip-<name>`, turning it on or off.
Future<void> tapChip(WidgetTester tester, String name) async {
  final chip = find.byKey(Key('chip-$name'));
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('field-save')));
  await tester.pumpAndSettle();
}

/// Adds a row to the open field editor's Options section and types [label] into it.
Future<void> addOption(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('add-option')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find
        .descendant(
          of: find.byKey(const Key('field-options')),
          matching: find.byType(TextField),
        )
        .last,
    label,
  );
  await tester.pumpAndSettle();
}

/// Drags the option [id] by [rows] rows (negative is up) with its handle.
Future<void> dragOption(WidgetTester tester, String id, int rows) async {
  final row = find.byKey(ValueKey(id));
  final height = tester.getSize(row).height;
  final gesture = await tester.startGesture(
    tester.getCenter(
      find.descendant(of: row, matching: find.byIcon(FiIcons.dragHandle)),
    ),
  );
  await tester.pump();
  for (var step = 0; step < 10; step++) {
    await gesture.moveBy(Offset(0, rows * (height + 4) / 10));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Adds a stored Choice field Priority with Low, Medium, High, and returns option IDs by label.
Future<Map<String, String>> seedChoice(
  Seeded seeded, {
  String? defaultLabel,
}) async {
  const labels = ['Low', 'Medium', 'High'];
  await seeded.controller.saveFieldWithOptions(
    FieldDefinitionDto(
      id: '',
      name: 'Priority',
      fieldType: const FieldTypeDto(kind: FieldTypeKindDto.enum_),
      required_: false,
      defaultValue: defaultLabel == null
          ? null
          : FieldValueDto(
              kind: FieldValueKindDto.enum_,
              textValue: tempOptionId(labels.indexOf(defaultLabel)),
            ),
      validation: const ValidationMetadataDto(),
      display: const DisplayMetadataDto(
        multiline: false,
        slider: false,
        sliderStep: null,
      ),
      order: 2,
      deleted: false,
      enumOptions: const [],
    ),
    [
      for (final (index, label) in labels.indexed)
        EnumOptionDto(
          id: tempOptionId(index),
          label: label,
          order: index,
          deleted: false,
        ),
    ],
  );
  seeded.bridge.schemaCalls.clear();
  return {
    for (final option
        in seeded.controller.schema!.fields
            .firstWhere((field) => field.name == 'Priority')
            .enumOptions)
      option.label: option.id,
  };
}

/// Picks [kind] in the open field editor's type grid.
Future<void> pickType(WidgetTester tester, FieldTypeKindDto kind) async {
  final tile = find.byKey(Key('type-${kind.name}'));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  mergeTests();
  _spanishHelpTest();
  testWidgets('the warning tracks Required, the default, and the record set', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await openFieldEditor(tester, 'Notes');

    expect(find.byKey(const Key('required-warning')), findsNothing);

    await toggleRequired(tester);
    expect(find.byKey(const Key('required-warning')), findsOneWidget);
    expect(
      find.textContaining('1 record has no value for this field'),
      findsOneWidget,
    );

    // A default satisfies the constraint, so nothing becomes invalid.
    await tapChip(tester, 'default');
    await tester.enterText(find.byKey(const Key('field-default')), 'none');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('required-warning')), findsNothing);

    await tester.enterText(find.byKey(const Key('field-default')), '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('required-warning')), findsOneWidget);

    // Turning Required back off clears it too.
    await toggleRequired(tester);
    expect(find.byKey(const Key('required-warning')), findsNothing);
  });

  testWidgets('no warning when every record already holds a value', (
    tester,
  ) async {
    final seeded = await seed(tester, recordsWithNotes: 1);
    await pumpPage(tester, seeded.controller);
    await openFieldEditor(tester, 'Notes');
    await toggleRequired(tester);
    expect(find.byKey(const Key('required-warning')), findsNothing);
  });

  testWidgets('saving asks for confirmation and cancelling keeps the editor', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await openFieldEditor(tester, 'Notes');
    await toggleRequired(tester);
    await tester.enterText(find.byKey(const Key('field-name')), 'Remarks');
    await tester.pumpAndSettle();

    await save(tester);
    expect(find.byKey(const Key('required-confirmation')), findsOneWidget);
    expect(find.text('Make “Remarks” required?'), findsOneWidget);
    expect(
      find.text('1 record has no value and will be marked incomplete.'),
      findsOneWidget,
    );
    expect(find.text('Keep optional'), findsOneWidget);

    await tester.tap(find.byKey(const Key('required-cancel')));
    await tester.pumpAndSettle();

    // The editor is still open with everything the user typed.
    expect(find.byKey(const Key('field-name')), findsOneWidget);
    expect(find.text('Remarks'), findsOneWidget);
    expect(
      seeded.controller.schema!.fields
          .firstWhere((field) => field.name == 'Notes')
          .required_,
      isFalse,
    );

    // Confirming submits exactly one schema command.
    final fieldsBefore = seeded.controller.schema!.fields.length;
    await save(tester);
    await tester.tap(find.byKey(const Key('required-confirm')));
    await tester.pumpAndSettle();
    expect(seeded.controller.schema!.fields, hasLength(fieldsBefore));
    final updated = seeded.controller.schema!.fields.firstWhere(
      (field) => field.name == 'Remarks',
    );
    expect(updated.required_, isTrue);
  });

  testWidgets('a required field with a default needs no confirmation', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await openFieldEditor(tester, 'Notes');
    await toggleRequired(tester);
    await tapChip(tester, 'default');
    await tester.enterText(find.byKey(const Key('field-default')), 'none');
    await tester.pumpAndSettle();

    await save(tester);
    expect(find.byKey(const Key('required-confirmation')), findsNothing);
    expect(
      seeded.controller.schema!.fields
          .firstWhere((field) => field.name == 'Notes')
          .required_,
      isTrue,
    );
  });

  testWidgets('an invalid record highlights the field it is missing', (
    tester,
  ) async {
    final seeded = await seed(tester);
    final notes = seeded.controller.schema!.fields
        .firstWhere((field) => field.name == 'Notes')
        .id;
    // Stand in for the projection: the record is recoverable, marked invalid, and diagnosed.
    final existing = seeded.bridge.records[seeded.collectionId]!.single;
    seeded.bridge.records[seeded.collectionId]![0] = RecordDto(
      id: existing.id,
      collectionId: existing.collectionId,
      values: existing.values,
      valid: false,
      diagnostics: [
        DiagnosticDto(
          kind: 'record_validation',
          entityId: existing.id,
          fieldId: notes,
          message: 'required field is missing',
        ),
      ],
    );
    await seeded.controller.refresh();
    await pumpPage(tester, seeded.controller);

    // The list marks it before the user opens anything.
    expect(find.byIcon(FiIcons.warning), findsWidgets);

    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();
    expect(find.text('Edit record · 1 field needed'), findsOneWidget);
    expect(find.text('required field is missing'), findsOneWidget);
  });

  /// Opens the schema dialog and starts a new field of [kind] named [name].
  Future<void> addFieldOfKind(
    WidgetTester tester,
    String name,
    FieldTypeKindDto kind,
  ) async {
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-name')), name);
    await pickType(tester, kind);
  }

  testWidgets('a date default and range are picked, never typed as epoch days', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Onset', FieldTypeKindDto.date);
    await tapChip(tester, 'default');
    await tester.tap(find.text('Fixed date'));
    await tester.pumpAndSettle();
    await tapChip(tester, 'date-range');

    // The control is the same read-only picker a record uses, not a free-text number box.
    final defaultInput = find.descendant(
      of: find.byKey(const Key('field-default')),
      matching: find.byType(TextFormField),
    );
    expect(defaultInput, findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: defaultInput, matching: find.byType(EditableText)),
    );
    expect(editable.readOnly, isTrue);
    expect(editable.controller.text, isEmpty);
    expect(
      find.descendant(
        of: find.byKey(const Key('field-default')),
        matching: find.byIcon(FiIcons.date),
      ),
      findsOneWidget,
    );
    expect(find.text('UTC epoch days'), findsNothing);

    // Picking a day stores the epoch day the bound is actually compared as.
    await tester.tap(find.byKey(const Key('field-minimum')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await save(tester);

    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Onset',
    );
    final today = DateTime.now();
    final expected =
        DateTime.utc(
          today.year,
          today.month,
          today.day,
        ).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    expect(field.validation.minInteger, expected);
    expect(field.defaultValue, isNull);
  });

  for (final kind in [FieldTypeKindDto.date, FieldTypeKindDto.dateTime]) {
    testWidgets(
      '${fieldKindLabel(lookupAppLocalizations(const Locale('en')), kind)} default and range slots offer no Today or Now',
      (tester) async {
        final seeded = await seed(tester);
        await pumpPage(tester, seeded.controller);
        await addFieldOfKind(tester, 'Onset', kind);
        await tapChip(tester, 'default');
        if (kind == FieldTypeKindDto.date) {
          await tester.tap(find.text('Fixed date'));
          await tester.pumpAndSettle();
        }
        await tapChip(tester, 'date-range');

        for (final slot in [
          'field-default',
          'field-minimum',
          'field-maximum',
        ]) {
          expect(find.byKey(Key(slot)), findsOneWidget);
          expect(find.byKey(ValueKey('$slot-today')), findsNothing);
          expect(find.byKey(ValueKey('$slot-now')), findsNothing);
        }
        expect(find.text('Today'), findsNothing);
        expect(find.text('Now'), findsNothing);
      },
    );
  }

  testWidgets('a fixed-decimal default and range are stored exactly, scaled', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Dose', FieldTypeKindDto.fixedDecimal);
    await tapChip(tester, 'range');
    await tapChip(tester, 'default');

    // The scale is stated where the digits are typed.
    expect(find.text('2 dp'), findsWidgets);

    await tester.enterText(find.byKey(const Key('field-default')), '10.25');
    await tester.enterText(find.byKey(const Key('field-minimum')), '1.50');
    await tester.enterText(find.byKey(const Key('field-maximum')), '99.99');
    await tester.pumpAndSettle();

    await save(tester);

    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Dose',
    );
    expect(field.defaultValue?.kind, FieldValueKindDto.fixedDecimal);
    expect(field.defaultValue?.integerValue, 1025);
    expect(field.validation.minInteger, 150);
    expect(field.validation.maxInteger, 9999);
  });

  testWidgets('a boolean default offers None as well as the two values', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Recurring', FieldTypeKindDto.boolean);
    await tapChip(tester, 'default');

    // A switch cannot say "no default", so the control is a three-way choice.
    expect(
      find.descendant(
        of: find.byKey(const Key('field-default')),
        matching: find.byType(FiSwitchTile),
      ),
      findsNothing,
    );
    expect(find.text('true or false'), findsNothing);
    await tester.tap(find.byKey(const Key('field-default')));
    await tester.pumpAndSettle();
    expect(find.text('None'), findsWidgets);
    expect(find.text('True'), findsOneWidget);
    await tester.tap(find.text('True').last);
    await tester.pumpAndSettle();

    await save(tester);
    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Recurring',
    );
    expect(field.defaultValue?.booleanValue, isTrue);
    // No numeric range control for a boolean.
    expect(field.validation.minInteger, isNull);
  });

  testWidgets('an enum default is chosen by label, not by pasting an id', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Kind', FieldTypeKindDto.enum_);
    await addOption(tester, 'Migraine');
    await addOption(tester, 'Tension');
    await save(tester);

    await tester.tap(find.text('Kind'));
    await tester.pumpAndSettle();
    expect(find.text('Enum option UUID'), findsNothing);
    await tapChip(tester, 'default');
    await tester.tap(find.byKey(const Key('field-default')));
    await tester.pumpAndSettle();
    expect(find.text('Migraine'), findsWidgets);
    await tester.tap(find.text('Tension').last);
    await tester.pumpAndSettle();
    await save(tester);

    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Kind',
    );
    final tension = field.enumOptions.firstWhere(
      (item) => item.label == 'Tension',
    );
    expect(field.defaultValue?.kind, FieldValueKindDto.enum_);
    expect(field.defaultValue?.textValue, tension.id);
  });

  testWidgets('kinds read as words, never as generated identifiers', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    // The field rows already name their kinds.
    expect(find.text('Integer'), findsOneWidget);
    expect(find.text('Text'), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-field')));
    await tester.pumpAndSettle();
    for (final label in [
      'Integer',
      'Decimal',
      'Boolean',
      'Date',
      'Date & time',
      'Duration',
      'Choice',
    ]) {
      expect(find.text(label), findsWidgets);
    }
    for (final kind in FieldTypeKindDto.values) {
      if (kind.name !=
          fieldKindLabel(
            lookupAppLocalizations(const Locale('en')),
            kind,
          ).toLowerCase()) {
        expect(find.text(kind.name), findsNothing);
      }
    }
  });

  testWidgets('a Choice field gets options and a default in one save', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Priority', FieldTypeKindDto.enum_);
    await addOption(tester, 'Low');
    await addOption(tester, 'Medium');
    await addOption(tester, 'High');
    await tapChip(tester, 'default');
    await tester.tap(find.byKey(const Key('field-default')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medium').last);
    await tester.pumpAndSettle();
    seeded.bridge.schemaCalls.clear();
    await save(tester);

    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Priority',
    );
    final medium = field.enumOptions.firstWhere(
      (item) => item.label == 'Medium',
    );
    expect(seeded.bridge.schemaCalls, [
      'addField',
      'upsertEnumOption -|Low|0',
      'upsertEnumOption -|Medium|1',
      'upsertEnumOption -|High|2',
      'updateField default=${medium.id}',
    ]);
    expect(find.text('Choice · Low, Medium, High'), findsOneWidget);
    // Options live in the field editor only: the only Choice glyphs are the records table's
    // column type icons and the field row's own type icon in the schema sheet.
    final glyphs = find.byIcon(FiIcons.choice).evaluate().length;
    final inTable = find
        .descendant(
          of: find.byKey(const Key('records-table')),
          matching: find.byIcon(FiIcons.choice),
        )
        .evaluate()
        .length;
    expect(glyphs - inTable, 1);
  });

  group('Choices', () {
    /// Adds a stored Choices field "tags" with work, urgent, food; returns ids by label.
    Future<Map<String, String>> seedChoices(Seeded seeded) async {
      const labels = ['work', 'urgent', 'food'];
      await seeded.controller.saveFieldWithOptions(
        const FieldDefinitionDto(
          id: '',
          name: 'tags',
          fieldType: FieldTypeDto(kind: FieldTypeKindDto.enumSet),
          required_: false,
          validation: ValidationMetadataDto(),
          display: DisplayMetadataDto(
            multiline: false,
            slider: false,
            sliderStep: null,
          ),
          order: 2,
          deleted: false,
          enumOptions: [],
        ),
        [
          for (final (index, label) in labels.indexed)
            EnumOptionDto(
              id: tempOptionId(index),
              label: label,
              order: index,
              deleted: false,
            ),
        ],
      );
      seeded.bridge.schemaCalls.clear();
      return {
        for (final option
            in seeded.controller.schema!.fields
                .firstWhere((field) => field.name == 'tags')
                .enumOptions)
          option.label: option.id,
      };
    }

    testWidgets('the type grid is three rows of three, Choices after Choice', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'tags', FieldTypeKindDto.enumSet);
      final choice = tester.getTopLeft(find.byKey(const Key('type-enum_')));
      final choices = tester.getTopLeft(find.byKey(const Key('type-enumSet')));
      final text = tester.getTopLeft(find.byKey(const Key('type-text')));
      expect(choices.dy, choice.dy);
      expect(choices.dx, greaterThan(choice.dx));
      expect(choice.dy, greaterThan(text.dy));
      expect(find.text('Choices'), findsWidgets);
      expect(
        find.text('Required means at least one option is picked.'),
        findsOneWidget,
      );
    });

    testWidgets('a Choices field gets options and a set default in one save', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'tags', FieldTypeKindDto.enumSet);
      await addOption(tester, 'work');
      await addOption(tester, 'urgent');
      await addOption(tester, 'food');
      await tapChip(tester, 'default');
      expect(
        find.text('A set of options, picked on new records.'),
        findsOneWidget,
      );
      for (final id in ['new-1', 'new-2']) {
        final chip = find.byKey(ValueKey('choices-chip-$id'));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
      }
      seeded.bridge.schemaCalls.clear();
      await tester.ensureVisible(find.byKey(const Key('field-save')));
      await save(tester);

      final field = seeded.controller.schema!.fields.firstWhere(
        (item) => item.name == 'tags',
      );
      expect(field.fieldType.kind, FieldTypeKindDto.enumSet);
      String id(String label) =>
          field.enumOptions.firstWhere((item) => item.label == label).id;
      expect(seeded.bridge.schemaCalls, [
        'addField',
        'upsertEnumOption -|work|0',
        'upsertEnumOption -|urgent|1',
        'upsertEnumOption -|food|2',
        'updateField default=${id('work')}+${id('urgent')}',
      ]);
      expect(find.text('Choices · work, urgent, food'), findsOneWidget);
    });

    testWidgets('a ";" in a Choices option label is refused in place', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'tags', FieldTypeKindDto.enumSet);
      await addOption(tester, 'work; play');
      expect(
        find.text('Options of a Choices field can\'t contain “;”.'),
        findsOneWidget,
      );
      final saveButton = tester.widget<FilledButton>(
        find.byKey(const Key('field-save')),
      );
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('an existing Choice field turns into Choices', (tester) async {
      final seeded = await seed(tester);
      final ids = await seedChoice(seeded, defaultLabel: 'Medium');
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Priority');
      final text = tester.widget<InkWell>(find.byKey(const Key('type-text')));
      expect(text.onTap, isNull);
      await pickType(tester, FieldTypeKindDto.enumSet);
      seeded.bridge.schemaCalls.clear();
      await tester.ensureVisible(find.byKey(const Key('field-save')));
      await save(tester);
      final field = seeded.controller.schema!.fields.firstWhere(
        (item) => item.name == 'Priority',
      );
      expect(field.fieldType.kind, FieldTypeKindDto.enumSet);
      expect(field.defaultValue?.listValue, [ids['Medium']]);
      expect(seeded.bridge.schemaCalls, [
        'updateField default=${ids['Medium']}',
      ]);
    });

    testWidgets(
      'Choices back to Choice is blocked while records hold several',
      (tester) async {
        final seeded = await seed(tester);
        final ids = await seedChoices(seeded);
        final tags = seeded.controller.schema!.fields
            .firstWhere((field) => field.name == 'tags')
            .id;
        seeded.bridge.nextUpdateFieldError = BridgeError(
          kind: BridgeErrorKind.validation,
          issues: [
            BridgeIssueDto(
              fields: [tags],
              code: 'choices_conversion_blocked',
              message: '3 records hold more than one choice. Edit them first.',
              count: 3,
            ),
          ],
          message: '3 records hold more than one choice. Edit them first.',
          resetResolvable: false,
        );
        await pumpPage(tester, seeded.controller);
        await openFieldEditor(tester, 'tags');
        await pickType(tester, FieldTypeKindDto.enum_);
        await tester.ensureVisible(find.byKey(const Key('field-save')));
        await save(tester);
        expect(
          find.text('3 records hold more than one choice. Edit them first.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('field-save')), findsOneWidget);
        final field = seeded.controller.schema!.fields.firstWhere(
          (item) => item.id == tags,
        );
        expect(field.fieldType.kind, FieldTypeKindDto.enumSet);
        expect(ids, hasLength(3));
      },
    );
  });

  testWidgets('editing options sends only what changed', (tester) async {
    final seeded = await seed(tester);
    final ids = await seedChoice(seeded);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    expect(find.text('Choice · Low, Medium, High'), findsOneWidget);
    await tester.tap(find.text('Priority'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(ValueKey('option-label-${ids['Medium']}')),
      'Mid',
    );
    await tester.pumpAndSettle();
    await dragOption(tester, ids['High']!, -2);
    await deleteOption(tester, ids['Low']!);
    await tester.pumpAndSettle();
    await save(tester);

    expect(seeded.bridge.schemaCalls, [
      'updateField default=-',
      'removeEnumOption ${ids['Low']}',
      'upsertEnumOption ${ids['High']}|High|0',
      'upsertEnumOption ${ids['Medium']}|Mid|1',
    ]);
    expect(find.text('Choice · High, Mid'), findsOneWidget);
  });

  testWidgets('Cancel discards option edits', (tester) async {
    final seeded = await seed(tester);
    final ids = await seedChoice(seeded);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Priority'));
    await tester.pumpAndSettle();

    await addOption(tester, 'Urgent');
    await deleteOption(tester, ids['Low']!);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(seeded.bridge.schemaCalls, isEmpty);
    expect(find.text('Choice · Low, Medium, High'), findsOneWidget);
  });

  testWidgets('removing the default option clears the default', (tester) async {
    final seeded = await seed(tester);
    final ids = await seedChoice(seeded, defaultLabel: 'Medium');
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Priority'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('field-default')),
        matching: find.text('Medium'),
      ),
      findsOneWidget,
    );

    await deleteOption(tester, ids['Medium']!);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('field-default')),
        matching: find.text('None'),
      ),
      findsOneWidget,
    );
    await save(tester);

    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Priority',
    );
    expect(field.defaultValue, isNull);
    expect(seeded.bridge.schemaCalls, [
      'updateField default=-',
      'removeEnumOption ${ids['Medium']}',
      'upsertEnumOption ${ids['High']}|High|1',
    ]);
  });

  testWidgets('changing the type drops a default typed for the old one', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Switched', FieldTypeKindDto.integer);
    await tapChip(tester, 'default');
    await tapChip(tester, 'range');
    await tester.enterText(find.byKey(const Key('field-default')), '42');
    await tester.enterText(find.byKey(const Key('field-minimum')), '1');
    await tester.pumpAndSettle();

    await pickType(tester, FieldTypeKindDto.text);

    await save(tester);
    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Switched',
    );
    // 42 meant an integer; it must not survive as the text "42" or as a stale bound.
    expect(field.defaultValue, isNull);
    expect(field.validation.minInteger, isNull);
  });

  group('Show as slider', () {
    final sliderSwitch = find.byKey(const Key('field-slider'));

    FieldOptionChip switchTile(WidgetTester tester) =>
        tester.widget<FieldOptionChip>(sliderSwitch);

    Future<void> fillBounds(WidgetTester tester) async {
      await tapChip(tester, 'range');
      await tester.enterText(find.byKey(const Key('field-minimum')), '1');
      await tester.enterText(find.byKey(const Key('field-maximum')), '5');
      await tester.pumpAndSettle();
    }

    FieldDefinitionDto saved(Seeded seeded, String name) => seeded
        .controller
        .schema!
        .fields
        .firstWhere((item) => item.name == name);

    testWidgets('is shown and enabled for an Integer with both bounds', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await fillBounds(tester);

      expect(sliderSwitch, findsOneWidget);
      expect(switchTile(tester).onTap, isNotNull);
      await tester.ensureVisible(sliderSwitch);
      await tester.tap(sliderSwitch);
      await tester.pumpAndSettle();
      expect(switchTile(tester).selected, isTrue);
      await save(tester);

      final field = saved(seeded, 'Pain');
      expect(field.display.slider, isTrue);
      expect(field.validation.minInteger, 1);
      expect(field.validation.maxInteger, 5);
    });

    testWidgets('is disabled and off while a bound is empty', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await tapChip(tester, 'range');
      await tester.enterText(find.byKey(const Key('field-minimum')), '1');
      await tester.pumpAndSettle();

      expect(sliderSwitch, findsOneWidget);
      expect(switchTile(tester).onTap, isNull);
      expect(switchTile(tester).selected, isFalse);
    });

    testWidgets('clearing a bound turns it off for good', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await fillBounds(tester);
      await tester.ensureVisible(sliderSwitch);
      await tester.tap(sliderSwitch);
      await tester.pumpAndSettle();
      expect(switchTile(tester).selected, isTrue);

      await tester.enterText(find.byKey(const Key('field-minimum')), '');
      await tester.pumpAndSettle();
      expect(switchTile(tester).selected, isFalse);
      expect(switchTile(tester).onTap, isNull);

      // Filling the bound again does not bring the slider back on its own.
      await tester.enterText(find.byKey(const Key('field-minimum')), '1');
      await tester.pumpAndSettle();
      expect(switchTile(tester).selected, isFalse);
      await save(tester);
      expect(saved(seeded, 'Pain').display.slider, isFalse);
    });

    testWidgets('retyping hides it and saves without the flag', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await fillBounds(tester);
      await tester.ensureVisible(sliderSwitch);
      await tester.tap(sliderSwitch);
      await tester.pumpAndSettle();

      await pickType(tester, FieldTypeKindDto.fixedDecimal);
      expect(sliderSwitch, findsNothing);
      await save(tester);
      expect(saved(seeded, 'Pain').display.slider, isFalse);
    });

    final stepInput = find.byKey(const Key('field-slider-step'));

    Future<void> turnOn(WidgetTester tester, {String min = '0'}) async {
      await tapChip(tester, 'range');
      await tester.enterText(find.byKey(const Key('field-minimum')), min);
      await tester.enterText(find.byKey(const Key('field-maximum')), '100');
      await tester.pumpAndSettle();
      await tester.ensureVisible(sliderSwitch);
      await tester.tap(sliderSwitch);
      await tester.pumpAndSettle();
    }

    String? stepError(WidgetTester tester) => decorationErrorText(
      tester
          .widget<TextField>(
            find.descendant(of: stepInput, matching: find.byType(TextField)),
          )
          .decoration,
    );

    testWidgets('the Step input shows only while the switch is on', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      expect(stepInput, findsNothing);
      await turnOn(tester);
      expect(stepInput, findsOneWidget);
      await save(tester);
      final field = saved(seeded, 'Pain');
      expect(field.display.slider, isTrue);
      expect(field.display.sliderStep, isNull);
    });

    testWidgets('a dividing step is saved', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await turnOn(tester);
      await tester.enterText(stepInput, '10');
      await tester.pumpAndSettle();
      await save(tester);
      expect(saved(seeded, 'Pain').display.sliderStep, 10);
    });

    testWidgets('turning the switch off saves neither flag nor step', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await turnOn(tester);
      await tester.enterText(stepInput, '10');
      await tester.pumpAndSettle();
      await tester.tap(sliderSwitch);
      await tester.pumpAndSettle();
      expect(stepInput, findsNothing);
      await save(tester);
      final field = saved(seeded, 'Pain');
      expect(field.display.slider, isFalse);
      expect(field.display.sliderStep, isNull);
    });

    testWidgets('a step that does not divide the range is refused in place', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await turnOn(tester);
      final calls = seeded.bridge.schemaCalls.length;
      await tester.enterText(stepInput, '30');
      await tester.pumpAndSettle();
      await save(tester);
      expect(stepError(tester), 'Step must divide the range.');
      expect(seeded.bridge.schemaCalls.length, calls);

      await tester.enterText(stepInput, '0');
      await tester.pumpAndSettle();
      expect(stepError(tester), isNull);
      await save(tester);
      expect(stepError(tester), 'Step must be a positive whole number');
      expect(seeded.bridge.schemaCalls.length, calls);
    });

    testWidgets('a Rust slider_step error lands under the Step input', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
      await turnOn(tester);
      await tester.enterText(stepInput, '10');
      await tester.pumpAndSettle();
      seeded.bridge.nextFieldError = const BridgeError(
        kind: BridgeErrorKind.validation,
        issues: [
          BridgeIssueDto(
            fields: ['slider_step'],
            code: 'invalid',
            message: 'slider_step must divide the range',
          ),
        ],
        message: 'Invalid field',
        resetResolvable: false,
      );
      await save(tester);
      expect(stepError(tester), 'slider_step must divide the range');
    });

    testWidgets('is not offered for other kinds', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'Note', FieldTypeKindDto.text);
      expect(sliderSwitch, findsNothing);
    });
  });

  testWidgets('the New field panel shows Name at the normal height above the '
      'type grid', (tester) async {
    final seeded = await seed(tester);
    await pumpPage(
      tester,
      seeded.controller,
      theme: nocturneTheme(NocturneColors.mocha),
    );
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-field')));
    await tester.pumpAndSettle();

    final name = tester.getRect(
      find
          .descendant(
            of: find.byKey(const Key('field-name')),
            matching: find.byType(InputDecorator),
          )
          .first,
    );
    expect(name.height, 40);
    expect(
      tester.getTopLeft(find.byKey(const Key('type-grid'))).dy,
      greaterThan(name.bottom),
    );
  });

  group('type grid and chips', () {
    testWidgets('a Date field shows its chips, each opening a block', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await addFieldOfKind(tester, 'due', FieldTypeKindDto.date);
      final chips = tester
          .widgetList<FieldOptionChip>(find.byType(FieldOptionChip))
          .map((chip) => chip.label);
      expect(chips, ['Required', 'Date range', 'Default value']);
      await tapChip(tester, 'default');
      await tapChip(tester, 'date-range');
      expect(find.byKey(const Key('block-chip-default')), findsOneWidget);
      expect(find.byKey(const Key('block-chip-date-range')), findsOneWidget);
      expect(find.text('Earliest'), findsOneWidget);
      expect(find.text('Latest'), findsOneWidget);
      // The ✕ turns the chip off and closes its block.
      await tester.tap(find.byKey(const Key('close-chip-date-range')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('block-chip-date-range')), findsNothing);
      expect(
        tester
            .widget<FieldOptionChip>(find.byKey(const Key('chip-date-range')))
            .selected,
        isFalse,
      );
    });

    testWidgets('the type is fixed for an existing field', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Notes');
      final grid = find.byKey(const Key('type-grid'));
      expect(grid, findsOneWidget);
      for (final kind in FieldTypeKindDto.values) {
        final tile = tester.widget<InkWell>(
          find.byKey(Key('type-${kind.name}')),
        );
        expect(
          tile.onTap,
          isNull,
          reason: '${kind.name} tile is disabled for an existing field',
        );
      }
      final text = tester.getSemantics(find.byKey(const Key('type-text')));
      expect(text.flagsCollection.isSelected, Tristate.isTrue);
    });
  });

  testWidgets('a relative date default previews and saves as days', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'due', FieldTypeKindDto.date);
    await tapChip(tester, 'default');
    await withClock(Clock.fixed(DateTime(2026, 9, 28, 10)), () async {
      await tester.enterText(find.byKey(const Key('default-days')), '7');
      await tester.pumpAndSettle();
      expect(find.text('→ Oct 5, 2026'), findsOneWidget);
      await save(tester);
    });
    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'due',
    );
    expect(field.defaultRelativeDays, 7);
    expect(field.defaultValue, isNull);
  });

  testWidgets('a default outside the length limits disables saving', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'code', FieldTypeKindDto.text);
    await tapChip(tester, 'length');
    await tester.enterText(find.byKey(const Key('field-min-length')), '4');
    await tester.enterText(find.byKey(const Key('field-max-length')), '8');
    await tapChip(tester, 'default');
    await tester.enterText(find.byKey(const Key('field-default')), 'AB');
    await tester.pumpAndSettle();
    expect(find.text('2 / 4–8'), findsOneWidget);
    expect(find.text('Default must be 4–8 characters.'), findsOneWidget);
    FilledButton saveButton() =>
        tester.widget<FilledButton>(find.byKey(const Key('field-save')));
    expect(saveButton().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('field-default')), 'ABCD');
    await tester.pumpAndSettle();
    expect(find.text('4 / 4–8'), findsOneWidget);
    expect(find.text('Default must be 4–8 characters.'), findsNothing);
    expect(saveButton().onPressed, isNotNull);
  });

  testWidgets('a default outside the range shows the range', (tester) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Pain', FieldTypeKindDto.integer);
    await tapChip(tester, 'range');
    await tester.enterText(find.byKey(const Key('field-minimum')), '5');
    await tester.enterText(find.byKey(const Key('field-maximum')), '30');
    await tapChip(tester, 'default');
    await tester.enterText(find.byKey(const Key('field-default')), '2');
    await tester.pumpAndSettle();
    expect(find.text('Default must be between 5 and 30.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('field-save')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('deleting a used option asks first and says records keep it', (
    tester,
  ) async {
    final seeded = await seed(tester);
    final ids = await seedChoice(seeded);
    final priority = seeded.controller.schema!.fields
        .firstWhere((field) => field.name == 'Priority')
        .id;
    for (var i = 0; i < 2; i++) {
      await seeded.controller.createRecord([
        RecordValueDto(
          fieldId: priority,
          value: FieldValueDto(
            kind: FieldValueKindDto.enum_,
            textValue: ids['Low'],
          ),
        ),
      ]);
    }
    seeded.bridge.schemaCalls.clear();
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Priority').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deleted-option-note')), findsOneWidget);

    await deleteOption(tester, ids['Low']!);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('option-delete-confirmation')), findsOneWidget);
    expect(find.text('Delete option “Low”?'), findsOneWidget);
    expect(
      find.text(
        "2 records use it and keep it. It can't be picked for new records.",
      ),
      findsOneWidget,
    );
    expect(find.text('Keep option'), findsOneWidget);
    await tester.tap(find.byKey(const Key('option-delete-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('option-label-${ids['Low']}')), findsOneWidget);

    await deleteOption(tester, ids['Low']!);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('option-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('option-label-${ids['Low']}')), findsNothing);
    await save(tester);
    expect(
      seeded.bridge.schemaCalls,
      contains('removeEnumOption ${ids['Low']}'),
    );
  });

  testWidgets('the desktop schema sheet edits fields inline', (tester) async {
    final seeded = await seed(tester);
    tester.view.physicalSize = const Size(1240, 1400);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.text('Schema'));
    await tester.pumpAndSettle();
    expect(find.text('HEADACHES · 2 FIELDS'), findsOneWidget);
    expect(find.text('Collection schema'), findsOneWidget);
    expect(
      find.text('Drag to reorder · click a field to edit'),
      findsOneWidget,
    );
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(FiIcons.integer), findsWidgets);

    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(FieldEditorBody), findsOneWidget);
    expect(find.text('Save field'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-field')));
    await tester.pumpAndSettle();
    expect(find.text('Add field'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field-name')), 'Mood');
    await save(tester);
    expect(find.text('HEADACHES · 3 FIELDS'), findsOneWidget);
  });

  testWidgets('a phone opens each field as its own screen', (tester) async {
    final seeded = await seed(tester);
    tester.view.physicalSize = const Size(390, 844);
    await pumpPage(tester, seeded.controller);
    await tester.tap(find.byTooltip('Schema').first);
    await tester.pumpAndSettle();
    expect(find.text('Long-press to reorder'), findsOneWidget);
    expect(find.byKey(const Key('add-field')), findsOneWidget);
    final row = find
        .ancestor(of: find.text('Notes').last, matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(row).height, greaterThanOrEqualTo(52));
    expect(find.byIcon(FiIcons.chevronRight), findsNWidgets(2));
    expect(
      find.ancestor(
        of: find.byIcon(FiIcons.text),
        matching: find.byType(IconTile),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();
    expect(find.byType(FieldEditorScreen), findsOneWidget);
    expect(find.text('Field in Headaches'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Save field'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Delete field'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(FieldEditorScreen), findsNothing);

    await tester.tap(find.byKey(const Key('add-field')));
    await tester.pumpAndSettle();
    expect(find.text('New field'), findsOneWidget);
    expect(find.text('Add field'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field-name')), 'Mood');
    await save(tester);
    expect(find.byType(FieldEditorScreen), findsNothing);
    expect(
      seeded.controller.schema!.fields.any((field) => field.name == 'Mood'),
      isTrue,
    );
  });

  group('help beside the chips', () {
    testWidgets('each chip has one help button, on or off', (tester) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Notes');
      const helps = [
        'help-fieldRequired',
        'help-fieldMultiline',
        'help-fieldMinMaxLength',
        'help-fieldDefault',
      ];
      for (final help in helps) {
        expect(find.byKey(Key(help)), findsOneWidget, reason: help);
      }

      await tester.tap(find.byKey(const Key('help-fieldRequired')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('help-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('help-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('required-warning')), findsNothing);

      await tapChip(tester, 'multiline');
      await tapChip(tester, 'length');
      await tapChip(tester, 'default');
      for (final help in helps) {
        expect(find.byKey(Key(help)), findsOneWidget, reason: help);
      }
    });
  });

  group('deleting a field', () {
    testWidgets('the row delete icon shows on hover and asks first', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await tester.tap(find.text('Schema'));
      await tester.pumpAndSettle();
      final intensity = seeded.controller.schema!.fields.firstWhere(
        (field) => field.name == 'Intensity',
      );
      final delete = find.byKey(Key('field-row-delete-${intensity.id}'));
      double opacity() => tester
          .widget<Opacity>(
            find.ancestor(of: delete, matching: find.byType(Opacity)).first,
          )
          .opacity;
      expect(opacity(), 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Intensity').last));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expect(find.byTooltip('Delete field Intensity'), findsOneWidget);

      seeded.bridge.schemaCalls.clear();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('field-delete-confirmation')),
        findsOneWidget,
      );
      expect(find.text('Delete field “Intensity”?'), findsOneWidget);
      expect(
        find.text(
          'Removes the field from the schema. 1 record loses its value for it.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getCenter(find.byKey(const Key('field-delete-confirm'))).dx,
        lessThan(
          tester.getCenter(find.byKey(const Key('field-delete-keep'))).dx,
        ),
      );

      await tester.tap(find.byKey(const Key('field-delete-keep')));
      await tester.pumpAndSettle();
      expect(seeded.bridge.schemaCalls, isEmpty);
      expect(find.text('Intensity'), findsWidgets);

      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('field-delete-confirm')));
      await tester.pumpAndSettle();
      expect(
        seeded.controller.schema!.fields.any(
          (field) => field.name == 'Intensity' && !field.deleted,
        ),
        isFalse,
      );
    });

    testWidgets('the panel delete asks and Keep field submits nothing', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Notes');
      seeded.bridge.schemaCalls.clear();
      await tester.tap(find.byKey(const Key('field-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete field “Notes”?'), findsOneWidget);
      expect(find.text('Removes the field from the schema.'), findsOneWidget);
      await tester.tap(find.text('Keep field'));
      await tester.pumpAndSettle();
      expect(seeded.bridge.schemaCalls, isEmpty);
      expect(find.byType(FieldEditorBody), findsOneWidget);
    });

    testWidgets('the phone ⋮ delete removes the field and closes the screen', (
      tester,
    ) async {
      final seeded = await seed(tester);
      tester.view.physicalSize = const Size(390, 844);
      await pumpPage(tester, seeded.controller);
      await tester.tap(find.byTooltip('Schema').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notes').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('field-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Removes the field from the schema.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('field-delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(FieldEditorScreen), findsNothing);
      expect(
        seeded.controller.schema!.fields.any(
          (field) => field.name == 'Notes' && !field.deleted,
        ),
        isFalse,
      );
    });
  });

  test('an Integer slider names itself in the summary', () {
    final l = lookupAppLocalizations(const Locale('en'));
    FieldDefinitionDto integer({required bool slider}) => FieldDefinitionDto(
      id: 'f',
      name: 'Pain',
      fieldType: const FieldTypeDto(kind: FieldTypeKindDto.integer),
      required_: false,
      validation: const ValidationMetadataDto(minInteger: 0, maxInteger: 10),
      display: DisplayMetadataDto(
        multiline: false,
        slider: slider,
        sliderStep: null,
      ),
      order: 0,
      deleted: false,
      enumOptions: const [],
    );
    expect(fieldSummary(l, integer(slider: true)), 'Integer · 0–10 · slider');
    expect(fieldSummary(l, integer(slider: false)), 'Integer · 0–10');
  });
}

void _spanishHelpTest() {
  testWidgets('field editor help opens in Spanish', (tester) async {
    final seeded = await seed(tester);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: FieldEditorBody(
              controller: seeded.controller,
              onClosed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapChip(tester, 'default');
    final help = find.byKey(const Key('help-fieldDefault'));
    await tester.ensureVisible(help);
    await tester.tap(help);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('help-dialog')),
        matching: find.text('Predeterminado'),
      ),
      findsOneWidget,
    );
  });
}

/// Opens the ⋯ of option [id] and picks Delete….
Future<void> deleteOption(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('option-menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('option-menu-delete')));
}

/// Adds a stored field Tags of [kind] with [labels], and returns option IDs in label order.
Future<List<String>> seedTags(
  Seeded seeded,
  FieldTypeKindDto kind,
  List<String> labels,
) async {
  await seeded.controller.saveFieldWithOptions(
    FieldDefinitionDto(
      id: '',
      name: 'Tags',
      fieldType: FieldTypeDto(kind: kind),
      required_: false,
      validation: const ValidationMetadataDto(),
      display: const DisplayMetadataDto(
        multiline: false,
        slider: false,
        sliderStep: null,
      ),
      order: 2,
      deleted: false,
      enumOptions: const [],
    ),
    [
      for (final (index, label) in labels.indexed)
        EnumOptionDto(
          id: tempOptionId(index),
          label: label,
          order: index,
          deleted: false,
        ),
    ],
  );
  final options = seeded.controller.schema!.fields
      .firstWhere((field) => field.name == 'Tags')
      .enumOptions;
  return [
    for (final label in labels)
      options.firstWhere((option) => option.label == label).id,
  ];
}

String tagsId(Seeded seeded) => seeded.controller.schema!.fields
    .firstWhere((field) => field.name == 'Tags')
    .id;

Future<void> addTagRecords(
  Seeded seeded,
  int count,
  List<String> ids, {
  bool set = false,
}) async {
  for (var i = 0; i < count; i++) {
    await seeded.controller.createRecord([
      RecordValueDto(
        fieldId: tagsId(seeded),
        value: set
            ? FieldValueDto(kind: FieldValueKindDto.enumSet, listValue: ids)
            : FieldValueDto(kind: FieldValueKindDto.enum_, textValue: ids[0]),
      ),
    ]);
  }
}

void mergeTests() {
  group('adding options from records', () {
    testWidgets('the switch is off, saved with the field, and Choice only', (
      tester,
    ) async {
      final seeded = await seed(tester);
      await seedTags(seeded, FieldTypeKindDto.enum_, ['A', 'B']);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Tags');
      final toggle = find.byKey(const Key('allow-adding-options'));
      expect(toggle, findsOneWidget);
      expect(
        find.text(
          'New options are added to this field when the record is saved.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<FiSwitchTile>(toggle).value, isFalse);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await save(tester);
      final tags = seeded.controller.schema!.fields.firstWhere(
        (field) => field.name == 'Tags',
      );
      expect(tags.allowOptionsFromRecords, isTrue);

      await tester.tap(find.text('Notes').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('allow-adding-options')), findsNothing);
    });
  });

  group('merging options', () {
    testWidgets('a phone ⋯ is 44px and opens Merge… and Delete…', (
      tester,
    ) async {
      final seeded = await seed(tester);
      final ids = await seedTags(seeded, FieldTypeKindDto.enum_, ['A', 'B']);
      tester.view.physicalSize = const Size(390, 844);
      await pumpPage(tester, seeded.controller);
      await tester.tap(find.byTooltip('Schema').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tags').last);
      await tester.pumpAndSettle();
      final menu = find.byKey(ValueKey('option-menu-${ids[0]}'));
      await tester.ensureVisible(menu);
      expect(tester.getSize(menu).height, greaterThanOrEqualTo(44));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('Merge…'), findsOneWidget);
      expect(find.text('Delete…'), findsOneWidget);
    });

    testWidgets('the duplicate banner opens the sheet with the bigger kept', (
      tester,
    ) async {
      final seeded = await seed(tester);
      final ids = await seedTags(seeded, FieldTypeKindDto.enum_, [
        'groceries',
        'Groceries',
        'Rent',
      ]);
      await addTagRecords(seeded, 3, [ids[0]]);
      await addTagRecords(seeded, 9, [ids[1]]);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Tags');
      expect(
        find.text('2 options are named “groceries”. Merge them?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('duplicate-options-merge')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('merge-options-sheet')), findsOneWidget);
      expect(find.text('9 records'), findsOneWidget);
      expect(find.text('3 records'), findsOneWidget);
      expect(find.text('12 records will use “Groceries”'), findsOneWidget);
      expect(find.text('Its label stays'), findsOneWidget);
      expect(find.text("This can't be undone."), findsOneWidget);

      await tester.tap(find.byKey(const Key('merge-confirm')));
      await tester.pumpAndSettle();
      final (field, keep, merged) = seeded.bridge.merges.single;
      expect((field, keep), (tagsId(seeded), ids[1]));
      expect(merged, [ids[0]]);
      expect(find.byKey(const Key('merge-options-sheet')), findsNothing);
    });

    testWidgets('a Choices sheet counts records that had both', (tester) async {
      final seeded = await seed(tester);
      final ids = await seedTags(seeded, FieldTypeKindDto.enumSet, [
        'Groceries',
        'groceries',
      ]);
      await addTagRecords(seeded, 7, [ids[0]], set: true);
      await addTagRecords(seeded, 2, ids, set: true);
      await addTagRecords(seeded, 1, [ids[1]], set: true);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Tags');
      await tester.tap(find.byKey(const Key('duplicate-options-merge')));
      await tester.pumpAndSettle();
      expect(find.text('10 records will use “Groceries”'), findsOneWidget);
      expect(
        find.text('2 records had both. Each keeps one “Groceries”.'),
        findsOneWidget,
      );
    });

    testWidgets('Merge… pre-checks its row and needs a second option', (
      tester,
    ) async {
      final seeded = await seed(tester);
      final ids = await seedTags(seeded, FieldTypeKindDto.enum_, ['A', 'B']);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Tags');
      await tester.tap(find.byKey(ValueKey('option-menu-${ids[0]}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('option-menu-merge')));
      await tester.pumpAndSettle();
      FilledButton confirm() => tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Merge').last,
          matching: find.byType(FilledButton),
        ),
      );
      expect(confirm().onPressed, isNull);
      await tester.tap(find.byKey(ValueKey('merge-check-${ids[1]}')));
      await tester.pumpAndSettle();
      expect(confirm().onPressed, isNotNull);
    });

    testWidgets('Move them merges records left on a merged option', (
      tester,
    ) async {
      final seeded = await seed(tester);
      final ids = await seedTags(seeded, FieldTypeKindDto.enum_, ['A', 'a']);
      await seeded.controller.mergeEnumOptions(tagsId(seeded), ids[0], [
        ids[1],
      ]);
      // Written offline before the merge arrived.
      await addTagRecords(seeded, 3, [ids[1]]);
      await pumpPage(tester, seeded.controller);
      await openFieldEditor(tester, 'Tags');
      expect(find.text('3 records still use merged options.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('merged-options-move')));
      await tester.pumpAndSettle();
      final (field, keep, merged) = seeded.bridge.merges.last;
      expect((field, keep), (tagsId(seeded), ids[0]));
      expect(merged, [ids[1]]);
      expect(find.byKey(const Key('merged-options-banner')), findsNothing);
    });
  });
}
