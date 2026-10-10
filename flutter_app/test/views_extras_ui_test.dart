import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/collections_page.dart' show exportOutcomeText;
import 'package:fi/controllers.dart';
import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'pains';
const _type = 'field-type';
const _phone = Size(360, 780);
const _desktop = Size(1240, 900);

late String _headaches;
late String _grouped;

final _typeField = FieldDefinitionDto(
  id: _type,
  name: 'type',
  fieldType: const FieldTypeDto(kind: FieldTypeKindDto.enum_),
  required_: false,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
  order: 0,
  deleted: false,
  enumOptions: const [
    EnumOptionDto(id: 'headache', label: 'headache', order: 0, deleted: false),
    EnumOptionDto(id: 'stomach', label: 'stomach', order: 1, deleted: false),
  ],
);

ViewBodyDto _headacheBody({ViewGroupingDto? grouping}) => ViewBodyDto(
  filter: ExpressionDto(
    root: 2,
    nodes: [
      const ExpressionNodeDto(
        kind: ExpressionKindDto.field,
        field: FieldReferenceDto(kind: FieldReferenceKindDto.source, id: _type),
      ),
      ExpressionNodeDto(
        kind: ExpressionKindDto.constant,
        value: TypedValueDto(
          valueType: const ValueTypeDto(kind: ValueTypeKindDto.enumSet),
          listValue: const ['headache'],
          fieldId: _type,
        ),
      ),
      const ExpressionNodeDto(
        kind: ExpressionKindDto.setCompare,
        setOperator: SetOperatorDto.hasAnyOf,
        left: 0,
        right: 1,
      ),
    ],
  ),
  sorting: FakeCollectionBridge.allViewBody.sorting,
  grouping: grouping,
);

/// Six records `r0`…`r5`; the even ones are headaches. [incomplete] ids are invalid. "Headaches"
/// keeps the headaches and hides every record created later (ids with a dash: clones and new
/// records). "Grouped" groups everything by type.
Future<FakeCollectionBridge> _seed({Set<String> incomplete = const {}}) async {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: _collection,
      name: 'pains',
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
    ),
  );
  bridge.schemas[_collection] = CollectionSchemaDto(
    id: _collection,
    name: 'pains',
    description: '',
    fields: [_typeField],
  );
  bridge.records[_collection] = [
    for (var i = 0; i < 6; i++)
      RecordDto(
        id: 'r$i',
        collectionId: _collection,
        values: [
          if (i.isEven)
            const RecordValueDto(
              fieldId: _type,
              value: FieldValueDto(
                kind: FieldValueKindDto.enum_,
                textValue: 'headache',
              ),
            ),
        ],
        valid: !incomplete.contains('r$i'),
        diagnostics: const [],
        createdAtMs: (i + 1) * 1000,
      ),
  ];
  bridge.viewFilter = (record, filter) {
    if (record.id.contains('-')) return false;
    final value = record.values
        .where((item) => item.fieldId == _type)
        .firstOrNull
        ?.value
        .textValue;
    return value == 'headache';
  };
  _headaches = await bridge.createView(
    _collection,
    'Headaches',
    _headacheBody(),
  );
  _grouped = await bridge.createView(
    _collection,
    'Grouped',
    ViewBodyDto(
      sorting: FakeCollectionBridge.allViewBody.sorting,
      grouping: const ViewGroupingDto(fieldId: _type),
    ),
  );
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
  await pumpUntilFound(tester, find.text('pains'));
  await tester.tap(find.text('pains'));
  await tester.pumpAndSettle();
}

Finder _chip(String id) => find.byKey(Key('view-chip-$id'));

Future<void> _select(WidgetTester tester, String id) async {
  await tester.ensureVisible(_chip(id));
  await tester.pumpAndSettle();
  await tester.tap(_chip(id));
  await tester.pumpAndSettle();
}

/// How many headache records the list shows: phone cards by key, table cells by their value.
int _headacheRows(WidgetTester tester, Size size) => size == _phone
    ? [
        for (final id in ['r0', 'r2', 'r4'])
          if (find.byKey(ValueKey(id)).evaluate().isNotEmpty) id,
      ].length
    : find.text('headache').evaluate().length;

String _line(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('view-line-text')))
    .textSpan!
    .toPlainText();

void main() {
  for (final (label, size) in [('phone', _phone), ('desktop', _desktop)]) {
    group('at $label width', () {
      testWidgets('grouped headers show counts and collapse', (tester) async {
        final handle = tester.ensureSemantics();
        await _open(tester, await _seed(), size);
        await _select(tester, _grouped);
        expect(_line(tester), contains('Group: type'));
        expect(find.text('headache · 3'), findsOneWidget);
        expect(find.text('No type · 3'), findsOneWidget);
        expect(_headacheRows(tester, size), 3);
        final header = find.byKey(const Key('group-header-option:headache'));
        expect(
          tester.getSemantics(header),
          isSemantics(hasExpandedState: true, isExpanded: true),
        );
        await tester.tap(find.text('headache · 3'));
        await tester.pumpAndSettle();
        expect(_headacheRows(tester, size), 0);
        expect(find.text('headache · 3'), findsOneWidget);
        expect(
          tester.getSemantics(header),
          isSemantics(hasExpandedState: true, isExpanded: false),
        );
        // Collapsed groups are remembered per view while the app runs.
        await _select(tester, allViewId);
        await _select(tester, _grouped);
        expect(_headacheRows(tester, size), 0);
        await tester.tap(find.text('headache · 3'));
        await tester.pumpAndSettle();
        expect(_headacheRows(tester, size), 3);
        handle.dispose();
      });

      testWidgets('hidden incomplete records get a second line with Show', (
        tester,
      ) async {
        await _open(tester, await _seed(incomplete: {'r0', 'r1', 'r3'}), size);
        await _select(tester, _headaches);
        expect(
          find.textContaining('1 record is missing a required field'),
          findsOneWidget,
        );
        expect(find.text('2 more in other views · '), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('incomplete-hidden-show')),
        );
        await tester.tap(find.byKey(const Key('incomplete-hidden-show')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('incomplete-hidden')), findsNothing);
        expect(
          find.textContaining('3 records are missing a required field'),
          findsOneWidget,
        );
      });

      testWidgets('only the second line when the view shows none', (
        tester,
      ) async {
        await _open(tester, await _seed(incomplete: {'r1'}), size);
        await _select(tester, _headaches);
        expect(find.textContaining('missing a required field'), findsNothing);
        expect(find.text('1 more in other views · '), findsOneWidget);
      });

      testWidgets('a hidden clone offers Show and Undo; Show keeps the badge', (
        tester,
      ) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await _select(tester, _headaches);
        if (size == _phone) {
          await tester.longPress(find.byKey(const ValueKey('r0')));
        } else {
          await tester.longPress(find.text('headache').first);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('selection-clone')));
        await tester.pumpAndSettle();
        expect(find.text('Cloned · hidden by Headaches'), findsOneWidget);
        expect(find.byKey(const Key('undo-clone')), findsOneWidget);
        final created = bridge.records[_collection]!.last.id;
        await tester.tap(find.byKey(const Key('feedback-show')));
        await tester.pumpAndSettle();
        final badge = find.byKey(Key('clone-badge-$created'));
        if (size == _phone) {
          await tester.scrollUntilVisible(
            badge,
            200,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
        }
        expect(badge, findsOneWidget);
      });

      testWidgets('Undo on a hidden clone deletes exactly the clone', (
        tester,
      ) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await _select(tester, _headaches);
        if (size == _phone) {
          await tester.longPress(find.byKey(const ValueKey('r0')));
        } else {
          await tester.longPress(find.text('headache').first);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('selection-clone')));
        await tester.pumpAndSettle();
        final created = bridge.records[_collection]!.last.id;
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(bridge.batchDeleteCalls, [
          [created],
        ]);
        expect(bridge.records[_collection], hasLength(6));
      });

      testWidgets('a new record the view hides says Saved · hidden by', (
        tester,
      ) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await _select(tester, _headaches);
        if (size == _phone) {
          await tester.tap(find.byTooltip('New record'));
        } else {
          await tester.tap(find.text('New record').first);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save record'));
        await tester.pumpAndSettle();
        expect(find.text('Saved · hidden by Headaches'), findsOneWidget);
        expect(find.byKey(const Key('undo-clone')), findsNothing);
        await tester.tap(find.byKey(const Key('feedback-show')));
        await tester.pumpAndSettle();
        expect(find.text('Saved · hidden by Headaches'), findsNothing);
        // All is selected and lists the new record (it has no type).
        if (size == _desktop) {
          expect(find.text('—'), findsNWidgets(4));
        } else {
          final saved = bridge.records[_collection]!.last.id;
          final card = find.byKey(ValueKey(saved));
          await tester.scrollUntilVisible(
            card,
            200,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(card, findsOneWidget);
        }
      });
    });
  }

  testWidgets('a header click sorts, marks ↑/↓ and modifies the view', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester, await _seed(), _desktop);
    expect(find.byKey(const Key('view-modified-all')), findsNothing);
    await tester.tap(find.byKey(const Key('sort-header-$_type')));
    await tester.pumpAndSettle();
    expect(find.text('↑'), findsOneWidget);
    expect(find.byKey(const Key('view-modified-all')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('sort-header-$_type'))),
      isSemantics(label: 'type, sorted ascending', isButton: true),
    );
    // Clicking the primary key again flips it.
    await tester.tap(find.byKey(const Key('sort-header-$_type')));
    await tester.pumpAndSettle();
    expect(find.text('↓'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('Spanish group, incomplete and feedback lines fit at 360px', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await _open(tester, await _seed(incomplete: {'r1', 'r3'}), _phone);
    await _select(tester, _grouped);
    expect(find.text('Sin type · 3'), findsOneWidget);
    expect(_line(tester), contains('Agrupar: type'));
    await _select(tester, _headaches);
    expect(find.text('2 más en otras vistas · '), findsOneWidget);
    expect(find.text('Mostrar'), findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('r0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selection-clone')));
    await tester.pumpAndSettle();
    expect(find.text('Clonado · oculto por Headaches'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'controller: incomplete counts, hidden ids, header sort and select all',
    () async {
      final bridge = await _seed(incomplete: {'r0', 'r1'});
      final controller = CollectionsController(bridge);
      await controller.start();
      await controller.selectCollection(_collection);
      await controller.selectView(_headaches);
      expect(controller.visibleIncomplete, 1);
      expect(controller.hiddenIncomplete, 1);
      expect(controller.hiddenByView(['r0', 'r1', 'r3']), ['r1', 'r3']);

      await controller.selectView(_grouped);
      final headache = controller.recordGroups.first.group.key;
      controller.toggleGroup(headache);
      expect(controller.isGroupCollapsed(headache), isTrue);
      controller.startSelection();
      controller.selectAllShown();
      expect(controller.selectedRecordIds, hasLength(6));
      controller.clearSelection();

      await controller.selectView(allViewId);
      await controller.sortByColumn(_typeField);
      expect(controller.isModified, isTrue);
      expect(
        controller.activeBody.sorting.single.direction,
        SortDirectionDto.ascending,
      );
      expect(sortFieldId(controller.activeBody.sorting.single), _type);
      await controller.sortByColumn(_typeField);
      expect(
        controller.activeBody.sorting.single.direction,
        SortDirectionDto.descending,
      );
      controller.dispose();
    },
  );

  test('default header directions follow the field type', () {
    expect(
      defaultSortDirection(FieldTypeKindDto.dateTime),
      SortDirectionDto.descending,
    );
    expect(
      defaultSortDirection(FieldTypeKindDto.text),
      SortDirectionDto.ascending,
    );
    expect(
      defaultSortDirection(FieldTypeKindDto.integer),
      SortDirectionDto.descending,
    );
    expect(
      defaultSortDirection(FieldTypeKindDto.enum_),
      SortDirectionDto.ascending,
    );
    expect(
      defaultSortDirection(FieldTypeKindDto.boolean),
      SortDirectionDto.descending,
    );
  });

  test('export outcome names the broken views left out', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final es = lookupAppLocalizations(const Locale('es'));
    const clean = JsonExportDto(
      text: '',
      recordCount: 47,
      viewsWritten: 2,
      viewsOmitted: [],
    );
    expect(exportOutcomeText(en, clean), 'Exported 47 records and 2 views.');
    const omitted = JsonExportDto(
      text: '',
      recordCount: 47,
      viewsWritten: 2,
      viewsOmitted: ['Old scale'],
    );
    expect(
      exportOutcomeText(en, omitted),
      'Exported 47 records and 2 views. 1 broken view wasn\'t included: Old scale.',
    );
    expect(
      exportOutcomeText(es, omitted),
      'Se exportaron 47 registros y 2 vistas. No se incluyó 1 vista rota: Old scale.',
    );
  });
}
