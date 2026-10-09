import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/choice_input.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';
const _note = 'field-note';
const _tags = 'field-tags';

EnumOptionDto _option(String id, String label, int order) =>
    EnumOptionDto(id: id, label: label, order: order, deleted: false);

/// "Spending": an optional Text note and a Choices `tags` (food, work, travel).
FakeCollectionBridge _seeded({bool allow = true}) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: _collection,
      name: 'Spending',
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
    ),
  );
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'Spending',
    description: '',
    fields: [
      const FieldDefinitionDto(
        id: _note,
        name: 'Note',
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
      FieldDefinitionDto(
        id: _tags,
        name: 'Tags',
        fieldType: const FieldTypeDto(kind: FieldTypeKindDto.enumSet),
        required_: false,
        validation: const ValidationMetadataDto(),
        display: const DisplayMetadataDto(
          multiline: false,
          slider: false,
          sliderStep: null,
        ),
        order: 1,
        deleted: false,
        enumOptions: [
          _option('food', 'food', 0),
          _option('work', 'work', 1),
          _option('travel', 'travel', 2),
        ],
        allowOptionsFromRecords: allow,
      ),
    ],
  );
  bridge.records[_collection] = [];
  return bridge;
}

Future<void> _openNewRecord(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  await tester.pumpWidget(app(bridge));
  await pumpUntilFound(tester, find.text('Spending'));
  await tester.tap(find.text('Spending'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('New record').first);
  await tester.pumpAndSettle();
}

Future<void> _addByChip(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(const Key('choice-add-chip')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.descendant(
      of: find.byKey(const Key('choice-add-input')),
      matching: find.byType(TextField),
    ),
    text,
  );
  await tester.tap(find.byKey(const Key('choice-add-confirm')));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save record'));
  await tester.pumpAndSettle();
}

List<String> _labels(FakeCollectionBridge bridge) => [
  for (final option
      in bridge.schemas[_collection]!.fields
          .firstWhere((field) => field.id == _tags)
          .enumOptions)
    option.label,
];

void main() {
  testWidgets('the ＋ Add chip adds in place, tags New, and saves once', (
    tester,
  ) async {
    final bridge = _seeded();
    await _openNewRecord(tester, bridge);
    await _addByChip(tester, 'coffee');
    expect(find.text('coffee'), findsOneWidget);
    expect(find.byKey(const Key('choice-new-tag')), findsOneWidget);
    // Still toggle chips: the layout follows the stored options.
    expect(find.byKey(const Key('choices-chips')), findsOneWidget);
    expect(_labels(bridge), isNot(contains('coffee')));

    await _save(tester);
    expect(bridge.draftSaves, hasLength(1));
    final (recordId, values, pending) = bridge.draftSaves.single;
    expect(recordId, isNull);
    expect(pending.single.label, 'coffee');
    expect(values.firstWhere((item) => item.fieldId == _tags).value.listValue, [
      pending.single.key,
    ]);
    expect(_labels(bridge), contains('coffee'));
    final coffee = bridge.schemas[_collection]!.fields[1].enumOptions
        .firstWhere((option) => option.label == 'coffee')
        .id;
    expect(
      bridge.records[_collection]!.single.values
          .firstWhere((item) => item.fieldId == _tags)
          .value
          .listValue,
      [coffee],
    );
  });

  testWidgets('a case-insensitive match picks the existing option', (
    tester,
  ) async {
    final bridge = _seeded();
    await _openNewRecord(tester, bridge);
    await _addByChip(tester, 'WORK');
    expect(find.byKey(const Key('choice-new-tag')), findsNothing);
    await _save(tester);
    final (_, values, pending) = bridge.draftSaves.single;
    expect(pending, isEmpty);
    expect(values.firstWhere((item) => item.fieldId == _tags).value.listValue, [
      'work',
    ]);
  });

  testWidgets('unpicking a new option drops it', (tester) async {
    final bridge = _seeded();
    await _openNewRecord(tester, bridge);
    await _addByChip(tester, 'coffee');
    await tester.tap(find.text('coffee'));
    await tester.pumpAndSettle();
    expect(find.text('coffee'), findsNothing);
    await _save(tester);
    expect(bridge.draftSaves.single.$3, isEmpty);
    expect(_labels(bridge), isNot(contains('coffee')));
  });

  testWidgets('cancelling the form creates nothing', (tester) async {
    final bridge = _seeded();
    await _openNewRecord(tester, bridge);
    await _addByChip(tester, 'coffee');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.draftSaves, isEmpty);
    expect(_labels(bridge), isNot(contains('coffee')));
  });

  testWidgets('with the setting off nothing new is shown', (tester) async {
    final bridge = _seeded(allow: false);
    await _openNewRecord(tester, bridge);
    expect(find.byKey(const Key('choices-chips')), findsOneWidget);
    expect(find.byKey(const Key('choice-add-chip')), findsNothing);
  });

  group('search with an Add row', () {
    final options = [
      for (final (index, label) in [
        'work',
        'Groceries',
        'home',
        'rent',
        'gifts',
        'fuel',
        'bills',
      ].indexed)
        ChoiceOption(id: 'o$index', label: label),
    ];

    Future<List<String?>> pump(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final picked = <String?>[];
      final added = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: nocturneTheme(NocturneColors.mocha),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: StatefulBuilder(
                builder: (context, setState) => FiChoiceInput(
                  title: 'category',
                  options: [
                    ...options,
                    for (final (index, label) in added.indexed)
                      ChoiceOption(
                        id: 'pending:$index',
                        label: label,
                        isNew: true,
                      ),
                  ],
                  value: picked.lastOrNull,
                  onChanged: (id) => setState(() => picked.add(id)),
                  onAdd: (label) {
                    added.add(label);
                    return 'pending:${added.length - 1}';
                  },
                ),
              ),
            ),
          ),
        ),
      );
      return picked;
    }

    Finder searchField() => find.descendant(
      of: find.byKey(const Key('choice-search')),
      matching: find.byType(TextField),
    );

    testWidgets('on a phone the sheet ends with Add, or offers a match', (
      tester,
    ) async {
      final picked = await pump(tester, 390);
      // 7 options with adding allowed: always the search sheet.
      await tester.tap(find.text('Search 7 options'));
      await tester.pumpAndSettle();
      await tester.enterText(searchField(), 'WORK');
      await tester.pump();
      expect(find.byKey(const Key('choice-existing-tag')), findsOneWidget);
      expect(find.byKey(const Key('choice-add-row')), findsNothing);
      await tester.enterText(searchField(), 'groc');
      await tester.pump();
      expect(find.text('Add “groc”'), findsOneWidget);
      await tester.tap(find.byKey(const Key('choice-add-row')));
      await tester.pumpAndSettle();
      expect(picked.last, 'pending:0');
      expect(find.text('groc'), findsOneWidget);
      expect(find.byKey(const Key('choice-new-tag')), findsOneWidget);
    });

    testWidgets('on desktop the search list ends with Add', (tester) async {
      final picked = await pump(tester, 1240);
      expect(find.byType(RawAutocomplete<ChoiceOption>), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(RawAutocomplete<ChoiceOption>),
          matching: find.byType(TextField),
        ),
        'coffee',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choice-add-row')));
      await tester.pumpAndSettle();
      expect(picked.last, 'pending:0');
    });
  });
}
