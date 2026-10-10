import 'package:fi/bridge/collection_bridge.dart' show allViewId;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/views.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'pains';
const _type = 'field-type';
const _phone = Size(360, 780);
const _desktop = Size(1240, 900);

/// Ids of the seeded views.
late String _headaches;
late String _stomach;

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

/// "type is any of [options]", the shape the editor emits.
ViewBodyDto _typeIs(List<String> options) => ViewBodyDto(
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
          listValue: options,
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
);

/// Six records; the even ones are headaches. "Headaches" keeps 3, "Stomach" none.
Future<FakeCollectionBridge> _seed({bool stomach = false}) async {
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
        valid: true,
        diagnostics: const [],
        createdAtMs: (i + 1) * 1000,
      ),
  ];
  bridge.viewFilter = (record, filter) {
    for (final node in filter.nodes) {
      final options = node.value?.listValue;
      if (options == null) continue;
      final value = record.values
          .where((item) => item.fieldId == _type)
          .firstOrNull
          ?.value
          .textValue;
      if (!options.contains(value)) return false;
    }
    return true;
  };
  _headaches = await bridge.createView(
    _collection,
    'Headaches',
    _typeIs(['headache']),
  );
  if (stomach) {
    _stomach = await bridge.createView(
      _collection,
      'Stomach',
      _typeIs(['stomach']),
    );
  }
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

/// Opens a chip's menu the way the width does: long press on a phone, secondary click otherwise.
Future<void> _openMenu(WidgetTester tester, String id, Size size) async {
  await tester.ensureVisible(_chip(id));
  await tester.pumpAndSettle();
  if (size == _phone) {
    await tester.longPress(_chip(id));
  } else {
    await tester.tap(_chip(id), buttons: kSecondaryButton);
  }
  await tester.pumpAndSettle();
}

/// How many records without a type the list shows: phone cards by key, table rows by their
/// empty "—" cell.
int _untyped(WidgetTester tester, Size size) => size == _phone
    ? [
        for (final id in ['r1', 'r3', 'r5'])
          if (find.byKey(ValueKey(id)).evaluate().isNotEmpty) id,
      ].length
    : find.text('—').evaluate().length;

String _line(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('view-line-text')))
    .textSpan!
    .toPlainText();

void main() {
  for (final (label, size) in [('phone', _phone), ('desktop', _desktop)]) {
    group('at $label width', () {
      testWidgets('chips show names and counts; selecting filters the list', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _open(tester, await _seed(), size);
        expect(find.text('All'), findsOneWidget);
        expect(find.text('· 6'), findsOneWidget);
        expect(find.text('Headaches'), findsOneWidget);
        expect(find.text('· 3'), findsOneWidget);
        expect(find.byKey(const Key('new-view')), findsOneWidget);
        expect(_line(tester), 'Sort: Created · newest');
        expect(find.bySemanticsLabel('All, 6 records'), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel('All, 6 records')),
          matchesSemantics(
            label: 'All, 6 records',
            isSelected: true,
            hasSelectedState: true,
            hasTapAction: true,
            hasLongPressAction: true,
          ),
        );

        await _select(tester, _headaches);
        expect(_untyped(tester, size), 0);
        expect(
          _line(tester),
          'Sort: Created · newest  ·  Filter: type is headache',
        );
        handle.dispose();
      });

      testWidgets('⇅ flips the sort and marks the view modified', (
        tester,
      ) async {
        await _open(tester, await _seed(), size);
        await _select(tester, _headaches);
        await tester.tap(find.byKey(const Key('view-flip')));
        await tester.pumpAndSettle();
        expect(_line(tester), startsWith('Sort: Created · oldest'));
        expect(find.byKey(Key('view-modified-$_headaches')), findsOneWidget);
        expect(find.byKey(const Key('view-save')), findsOneWidget);
        expect(find.byKey(const Key('view-save-as-new')), findsOneWidget);
        await tester.tap(find.byKey(const Key('view-reset')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('view-modified-$_headaches')), findsNothing);

        // All offers no Save.
        await _select(tester, allViewId);
        await tester.tap(find.byKey(const Key('view-flip')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('view-modified-all')), findsOneWidget);
        expect(find.byKey(const Key('view-save')), findsNothing);
        expect(find.byKey(const Key('view-save-as-new')), findsOneWidget);
      });

      testWidgets('"+ View" creates a view through the editor', (tester) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await tester.ensureVisible(find.byKey(const Key('new-view')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('new-view')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-view')));
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('view-editor-save'));
        expect(
          tester
              .widget<ButtonStyleButton>(
                find
                    .descendant(
                      of: save,
                      matching: find.bySubtype<ButtonStyleButton>(),
                      matchRoot: true,
                    )
                    .first,
              )
              .onPressed,
          isNull,
        );

        await tester.enterText(
          find.byKey(const Key('view-editor-name')),
          'headaches',
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Another view is already called headaches'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ButtonStyleButton>(
                find
                    .descendant(
                      of: save,
                      matching: find.bySubtype<ButtonStyleButton>(),
                      matchRoot: true,
                    )
                    .first,
              )
              .onPressed,
          isNotNull,
        );

        await tester.enterText(
          find.byKey(const Key('view-editor-name')),
          ' all ',
        );
        await tester.pumpAndSettle();
        expect(find.text('“All” is reserved'), findsOneWidget);
        expect(
          tester
              .widget<ButtonStyleButton>(
                find
                    .descendant(
                      of: save,
                      matching: find.bySubtype<ButtonStyleButton>(),
                      matchRoot: true,
                    )
                    .first,
              )
              .onPressed,
          isNull,
        );

        await tester.enterText(
          find.byKey(const Key('view-editor-name')),
          'Oldest',
        );
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(bridge.views[_collection]!.map((view) => view.name), [
          'Headaches',
          'Oldest',
        ]);
        expect(find.text('Oldest'), findsOneWidget);
        expect(
          find.byKey(const Key('view-editor-name')),
          findsNothing,
          reason: 'the editor closes on save',
        );
      });

      testWidgets('the chip menu differs for saved views and All', (
        tester,
      ) async {
        await _open(tester, await _seed(), size);
        await _openMenu(tester, _headaches, size);
        for (final item in ['Rename', 'Edit', 'Reorder views…', 'Delete…']) {
          expect(find.text(item), findsOneWidget, reason: item);
        }
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await _openMenu(tester, allViewId, size);
        expect(find.text('Reorder views…'), findsOneWidget);
        expect(find.text('Rename'), findsNothing);
        expect(find.text('Delete…'), findsNothing);
      });

      testWidgets('reorder by handle and by the move action', (tester) async {
        final handle = tester.ensureSemantics();
        final bridge = await _seed(stomach: true);
        await _open(tester, bridge, size);
        await _openMenu(tester, allViewId, size);
        await tester.tap(find.text('Reorder views…'));
        await tester.pumpAndSettle();
        expect(find.text('Always first'), findsOneWidget);
        expect(
          find.byKey(const Key('reorder-handle-$allViewId')),
          findsNothing,
        );

        final row = find.byKey(ValueKey(_stomach));
        final height = tester.getSize(row).height;
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(Key('reorder-handle-$_stomach'))),
        );
        await tester.pump();
        for (var step = 0; step < 10; step++) {
          await drag.moveBy(Offset(0, -(height + 4) / 10));
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        expect(bridge.views[_collection]!.map((view) => view.name), [
          'Stomach',
          'Headaches',
        ]);

        // The list's built-in "Move up" action moves Headaches back.
        final node = tester.getSemantics(
          find.ancestor(
            of: find.text('Headaches').last,
            matching: find.byKey(ValueKey(_headaches)),
          ),
        );
        final moveUp = CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Move up'),
        );
        var target = node;
        while (!target.getSemanticsData().customSemanticsActionIds!.contains(
          moveUp,
        )) {
          target = target.parent!;
        }
        tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
          target.id,
          SemanticsAction.customAction,
          moveUp,
        );
        await tester.pumpAndSettle();
        expect(bridge.views[_collection]!.map((view) => view.name), [
          'Headaches',
          'Stomach',
        ]);
        await tester.tap(find.byKey(const Key('reorder-done')));
        await tester.pumpAndSettle();
        expect(find.text('Always first'), findsNothing);
        handle.dispose();
      });

      testWidgets('delete asks first and selects All', (tester) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await _select(tester, _headaches);
        await _openMenu(tester, _headaches, size);
        await tester.tap(find.text('Delete…'));
        await tester.pumpAndSettle();
        expect(find.text('Delete view “Headaches”?'), findsOneWidget);
        expect(find.text("Records aren't affected."), findsOneWidget);
        await tester.tap(find.byKey(const Key('view-delete-keep')));
        await tester.pumpAndSettle();
        expect(_chip(_headaches), findsOneWidget);

        await _openMenu(tester, _headaches, size);
        await tester.tap(find.text('Delete…'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('view-delete-confirm')));
        await tester.pumpAndSettle();
        expect(_chip(_headaches), findsNothing);
        expect(bridge.views[_collection], isEmpty);
        expect(find.text('· 6'), findsOneWidget);
      });

      testWidgets('select all covers what the view shows', (tester) async {
        await _open(tester, await _seed(), size);
        await _select(tester, _headaches);
        if (size == _phone) {
          await tester.tap(find.byKey(const Key('collection-more')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('select-records')));
        } else {
          await tester.tap(find.text('Select'));
        }
        await tester.pumpAndSettle();
        final selectAll = size == _phone
            ? find.byTooltip('Select all 3')
            : find.text('Select all 3');
        expect(selectAll, findsOneWidget);
        await tester.tap(selectAll);
        await tester.pumpAndSettle();
        expect(find.text('3 selected'), findsOneWidget);
      });

      testWidgets('a broken view warns and lists every record', (tester) async {
        final bridge = await _seed();
        bridge.brokenViews[_headaches] = 'field deleted';
        await _open(tester, bridge, size);
        expect(find.byKey(Key('view-broken-$_headaches')), findsOneWidget);
        await _select(tester, _headaches);
        expect(
          find.text('This view uses a field that was deleted'),
          findsOneWidget,
        );
        expect(_untyped(tester, size), 3);
        await tester.tap(find.text('Edit view'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('view-editor-name')), findsOneWidget);
      });

      testWidgets('discarded changes are announced with OK', (tester) async {
        final bridge = await _seed();
        await _open(tester, bridge, size);
        await _select(tester, _headaches);
        await tester.tap(find.byKey(const Key('view-flip')));
        await tester.pumpAndSettle();
        bridge.isBrokenBody = (body) =>
            body.sorting.first.direction == SortDirectionDto.ascending;
        bridge.changedViews();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Your unsaved changes used a field that was deleted, so they '
            'were discarded.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(Key('view-modified-$_headaches')), findsNothing);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('view-discarded-notice')), findsNothing);
      });

      testWidgets('an empty view offers Edit view and Show all', (
        tester,
      ) async {
        await _open(tester, await _seed(stomach: true), size);
        await _select(tester, _stomach);
        expect(find.text('No records match Stomach.'), findsOneWidget);
        expect(find.byKey(const Key('view-empty-edit')), findsOneWidget);
        await tester.tap(find.byKey(const Key('view-show-all')));
        await tester.pumpAndSettle();
        expect(find.text('No records match Stomach.'), findsNothing);
        expect(_untyped(tester, size), 3);
      });
    });
  }

  testWidgets('Spanish strings fit at 360px', (tester) async {
    tester.platformDispatcher.localesTestValue = const [Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(await _seed(stomach: true)));
    await pumpUntilFound(tester, find.text('pains'));
    await tester.tap(find.text('pains'));
    await tester.pumpAndSettle();
    expect(find.text('Todos'), findsOneWidget);
    await _select(tester, _headaches);
    await tester.tap(find.byKey(const Key('view-flip')));
    await tester.pumpAndSettle();
    expect(find.text('Guardar como vista nueva'), findsOneWidget);
    expect(_line(tester), startsWith('Orden: Creación · más antiguo'));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('collection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-records')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Seleccionar los 3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-selection')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('new-view')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-view')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('view-editor-name')), 'todos');
    await tester.pumpAndSettle();
    expect(find.text('“Todos” está reservado'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
