import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _title = 'field-title';
const _intensity = 'field-intensity';
const _mood = 'field-mood';

FieldDefinitionDto _field(
  String id,
  String name,
  FieldTypeKindDto kind, {
  bool required = false,
  FieldValueDto? defaultValue,
  int order = 0,
}) => FieldDefinitionDto(
  id: id,
  name: name,
  fieldType: FieldTypeDto(kind: kind),
  required_: required,
  defaultValue: defaultValue,
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

/// A collection with a required Title, an optional Intensity, and a required Mood that has a
/// default (so it is not marked).
FakeCollectionBridge _seeded({List<RecordDto> records = const []}) {
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
    fields: [
      _field(_title, 'Title', FieldTypeKindDto.text, required: true),
      _field(_intensity, 'Intensity', FieldTypeKindDto.integer, order: 1),
      _field(
        _mood,
        'Mood',
        FieldTypeKindDto.text,
        required: true,
        defaultValue: const FieldValueDto(
          kind: FieldValueKindDto.text,
          textValue: 'fine',
        ),
        order: 2,
      ),
    ],
  );
  bridge.records[_collection] = [...records];
  return bridge;
}

Future<void> _openNewRecord(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.text('Headaches'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('New record').first);
  await tester.pumpAndSettle();
}

const _ids = {'Title': _title, 'Intensity': _intensity, 'Mood': _mood};

/// The record form's text input for the field named [label].
Finder _input(String label) => find.descendant(
  of: find.byKey(ValueKey('record-field-${_ids[label]}')),
  matching: find.byType(TextFormField),
);

/// The error text rendered under the input labelled [label], or null.
String? _errorUnder(WidgetTester tester, String label) => decorationErrorText(
  tester
      .widget<TextField>(
        find.descendant(of: _input(label), matching: find.byType(TextField)),
      )
      .decoration,
);

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save record'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a pristine form shows required markers and one legend, no errors', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _openNewRecord(tester, _seeded());
    expect(find.text('New record'), findsOneWidget);
    expect(find.text('Required'), findsNothing);
    // The desktop footer carries the one legend.
    expect(find.byType(RequiredLegend), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('form-footer-hint')))
          .textSpan!
          .toPlainText(),
      '* Required · Ctrl+Enter to save',
    );
    // Title is required without a default: marked, in accent300, announced as required.
    expect(find.bySemanticsLabel('Title, required'), findsOneWidget);
    // Mood is required but has a default, and Intensity is optional: neither is marked.
    expect(find.bySemanticsLabel('Mood, required'), findsNothing);
    expect(find.bySemanticsLabel('Intensity, required'), findsNothing);
    expect(find.text(' *'), findsOneWidget);
    expect(_errorUnder(tester, 'Title'), isNull);
    semantics.dispose();
  });

  testWidgets('Save shows errors under their inputs and they clear on edit', (
    tester,
  ) async {
    final bridge = _seeded();
    await _openNewRecord(tester, bridge);
    await _save(tester);
    expect(bridge.draftValidations, hasLength(1));
    expect(_errorUnder(tester, 'Title'), 'Required');
    expect(_errorUnder(tester, 'Intensity'), isNull);
    expect(bridge.records[_collection], isEmpty, reason: 'nothing committed');

    // After the attempt every edit re-validates, so the error goes while typing.
    await tester.enterText(_input('Title'), 'Aura');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(bridge.draftValidations, hasLength(2));
    expect(_errorUnder(tester, 'Title'), isNull);

    await _save(tester);
    expect(bridge.records[_collection], hasLength(1));
    expect(find.text('New record'), findsNothing);
  });

  testWidgets('N issues render N lines, and others land in the form slot', (
    tester,
  ) async {
    final bridge = _seeded()
      ..draftIssues = (_, _, _) => const [
        BridgeIssueDto(
          fields: [_intensity],
          code: 'out_of_range',
          message: 'Must be between 1 and 10',
        ),
        BridgeIssueDto(
          fields: [_intensity],
          code: 'invalid',
          message: 'Must be even',
        ),
        BridgeIssueDto(
          fields: [_title, _intensity],
          code: 'invalid',
          message: 'Title and Intensity disagree',
        ),
        BridgeIssueDto(fields: [], code: 'invalid', message: 'Try again'),
      ];
    await _openNewRecord(tester, bridge);
    await _save(tester);
    final intensity = tester.widget<TextField>(
      find.descendant(
        of: _input('Intensity'),
        matching: find.byType(TextField),
      ),
    );
    expect(
      decorationErrorText(intensity.decoration),
      'Must be between 1 and 10\nMust be even',
    );
    expect(_errorUnder(tester, 'Title'), isNull);
    final slot = find.byType(FormErrorLines);
    expect(slot, findsOneWidget);
    expect(
      find.descendant(
        of: slot,
        matching: find.text('Title and Intensity disagree'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: slot, matching: find.text('Try again')),
      findsOneWidget,
    );
    // The slot sits above the buttons.
    expect(
      tester.getBottomLeft(slot).dy,
      lessThan(
        tester.getTopLeft(find.widgetWithText(FilledButton, 'Save record')).dy,
      ),
    );
  });

  testWidgets('a record opened because it is invalid shows its issue at once', (
    tester,
  ) async {
    final bridge = _seeded(
      records: const [
        RecordDto(
          id: 'record-0',
          collectionId: _collection,
          values: [
            RecordValueDto(
              fieldId: _intensity,
              value: FieldValueDto(
                kind: FieldValueKindDto.integer,
                integerValue: 3,
              ),
            ),
          ],
          valid: false,
          diagnostics: [
            DiagnosticDto(
              kind: 'record_validation',
              entityId: 'record-0',
              fieldId: _title,
              message: 'Required',
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.tap(find.text('Headaches'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit record · 1 field needed'), findsOneWidget);
    expect(_errorUnder(tester, 'Title'), 'Required');
  });

  testWidgets('the pinned summary counts fields and Show focuses the first', (
    tester,
  ) async {
    final bridge = _seeded()
      ..draftIssues = (_, _, _) => const [
        BridgeIssueDto(fields: [_title], code: 'required', message: 'Required'),
        BridgeIssueDto(
          fields: [_intensity],
          code: 'out_of_range',
          message: 'Must be between 1 and 10',
        ),
      ];
    await _openNewRecord(tester, bridge);
    expect(find.byType(FormErrorSummary), findsNothing);
    await _save(tester);
    expect(
      find.text("Couldn't save. 2 fields need attention."),
      findsOneWidget,
    );
    // Pinned above the footer, outside the scrolling body.
    expect(
      find.ancestor(
        of: find.byType(FormErrorSummary),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    // The field keeps an accent border, a warning icon and the message.
    expect(_errorUnder(tester, 'Title'), 'Required');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('record-field-$_title')),
        matching: find.byType(FieldErrorMessage),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      find
          .descendant(
            of: find.byKey(const ValueKey('record-field-$_title')),
            matching: find.byWidget(focused!.widget),
          )
          .evaluate(),
      isNotEmpty,
    );

    // Once no field has an error the summary goes.
    bridge.draftIssues = (_, _, _) => const [];
    await tester.enterText(_input('Title'), 'Aura');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.byType(FormErrorSummary), findsNothing);
  });

  test('FormIssues splits by field count and keeps unknown keys', () {
    final issues = FormIssues.fromIssues(const [
      BridgeIssueDto(fields: ['a'], code: 'required', message: 'Required'),
      BridgeIssueDto(fields: ['a'], code: 'length', message: 'Too long'),
      BridgeIssueDto(fields: ['a', 'b'], code: 'invalid', message: 'Both'),
      BridgeIssueDto(fields: ['c'], code: 'invalid', message: 'Elsewhere'),
    ]);
    expect(issues.of('a'), ['Required', 'Too long']);
    expect(issues.form, ['Both']);
    final restricted = issues.restrictTo({'a'});
    expect(restricted.of('c'), isEmpty);
    expect(restricted.form, ['Both', 'Elsewhere']);
    expect(
      FormIssues.from(
        const BridgeError(
          kind: BridgeErrorKind.persistence,
          issues: [],
          message: 'Local data could not be saved or loaded.',
          resetResolvable: false,
        ),
      ).form,
      ['Local data could not be saved or loaded.'],
    );
  });
}
