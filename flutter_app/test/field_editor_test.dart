import 'package:fi/collections_page.dart';
import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/src/rust/api/models.dart';
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
  display: const DisplayMetadataDto(multiline: false),
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
  CollectionsController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
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

Future<void> toggleRequired(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(SwitchListTile, 'Required'));
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
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
      find.descendant(of: row, matching: find.byIcon(Icons.drag_handle)),
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
      display: const DisplayMetadataDto(multiline: false),
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

void main() {
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

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('required-confirmation')), findsOneWidget);
    expect(find.textContaining('1 record has no value'), findsWidgets);

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
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
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
    await tester.enterText(find.byKey(const Key('field-default')), 'none');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
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
    expect(find.byIcon(Icons.warning_amber), findsWidgets);

    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();
    expect(find.text('Edit record'), findsOneWidget);
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
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-name')), name);
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<FieldTypeKindDto>, 'Type'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(fieldKindLabel(kind)).last);
    await tester.pumpAndSettle();
  }

  testWidgets('a date default and range are picked, never typed as epoch days', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Onset', FieldTypeKindDto.date);

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
        matching: find.byIcon(Icons.calendar_today),
      ),
      findsOneWidget,
    );
    expect(find.text('UTC epoch days'), findsNothing);

    // Picking a day stores the epoch day the bound is actually compared as.
    await tester.tap(find.byKey(const Key('field-minimum')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

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

  testWidgets('a fixed-decimal default and range are stored exactly, scaled', (
    tester,
  ) async {
    final seeded = await seed(tester);
    await pumpPage(tester, seeded.controller);
    await addFieldOfKind(tester, 'Dose', FieldTypeKindDto.fixedDecimal);

    // The scale is stated where the digits are typed.
    expect(find.text('Exact to 2 decimal places'), findsWidgets);

    await tester.enterText(find.byKey(const Key('field-default')), '10.25');
    await tester.enterText(find.byKey(const Key('field-minimum')), '1.50');
    await tester.enterText(find.byKey(const Key('field-maximum')), '99.99');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

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

    // A switch cannot say "no default", so the control is a three-way choice.
    expect(
      find.descendant(
        of: find.byKey(const Key('field-default')),
        matching: find.byType(SwitchListTile),
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

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
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

    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<FieldTypeKindDto>, 'Type'),
    );
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
      if (kind.name != fieldKindLabel(kind).toLowerCase()) {
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
    // Options live in the field editor only.
    expect(find.byIcon(Icons.list_alt), findsNothing);
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
    await tester.tap(find.byKey(ValueKey('remove-option-${ids['Low']}')));
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
    await tester.tap(find.byKey(ValueKey('remove-option-${ids['Low']}')));
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

    await tester.tap(find.byKey(ValueKey('remove-option-${ids['Medium']}')));
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
    await tester.enterText(find.byKey(const Key('field-default')), '42');
    await tester.enterText(find.byKey(const Key('field-minimum')), '1');
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(DropdownButtonFormField<FieldTypeKindDto>, 'Type'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final field = seeded.controller.schema!.fields.firstWhere(
      (item) => item.name == 'Switched',
    );
    // 42 meant an integer; it must not survive as the text "42" or as a stale bound.
    expect(field.defaultValue, isNull);
    expect(field.validation.minInteger, isNull);
  });
}
