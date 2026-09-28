import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

FieldDefinitionDto _field(String id, String name, {bool required = false}) =>
    FieldDefinitionDto(
      id: id,
      name: name,
      fieldType: const FieldTypeDto(kind: FieldTypeKindDto.text),
      required_: required,
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

RecordDto _record(String collection, int index, {bool valid = true}) =>
    RecordDto(
      id: '$collection-record-$index',
      collectionId: collection,
      values: const [],
      valid: valid,
      diagnostics: const [],
    );

/// Adds a collection holding [fields] fields and [records] records, [invalid] of them invalid,
/// last edited at [editedMs].
void _addCollection(
  FakeCollectionBridge bridge,
  String id,
  String name, {
  int fields = 0,
  int records = 0,
  int invalid = 0,
  int? editedMs,
}) {
  bridge.collections.add(
    CollectionDto(
      id: id,
      name: name,
      description: '',
      recordCount: 0,
      fieldCount: 0,
      incompleteCount: 0,
      lastEditedMs: editedMs,
    ),
  );
  bridge.schemas[id] = CollectionSchemaDto(
    id: id,
    name: name,
    description: '',
    fields: [for (var i = 0; i < fields; i++) _field('$id-f$i', 'field $i')],
  );
  bridge.records[id] = [
    for (var i = 0; i < records; i++) _record(id, i, valid: i >= invalid),
  ];
}

FakeCollectionBridge _ready() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Names of the collection rows, top to bottom.
List<String> _rowOrder(WidgetTester tester, List<String> names) {
  final tops = {
    for (final name in names) name: tester.getTopLeft(find.text(name)).dy,
  };
  return [...names]..sort((a, b) => tops[a]!.compareTo(tops[b]!));
}

void main() {
  final now = DateTime(2026, 9, 28, 12);
  final twoHoursAgo = now
      .subtract(const Duration(hours: 2))
      .millisecondsSinceEpoch;

  group('collection rows', () {
    testWidgets('a desktop row shows its size, recency and no tag', (
      tester,
    ) async {
      await withClock(Clock.fixed(now), () async {
        _size(tester, const Size(1240, 800));
        final bridge = _ready();
        _addCollection(
          bridge,
          'c1',
          'test',
          fields: 3,
          records: 6,
          editedMs: twoHoursAgo,
        );
        await tester.pumpWidget(app(bridge));
        await pumpUntilFound(tester, find.text('test'));
        expect(find.text('6 records · 3 fields'), findsOneWidget);
        expect(find.text('Edited 2 h ago'), findsOneWidget);
        expect(find.byKey(const Key('collection-incomplete-c1')), findsNothing);
      });
    });

    testWidgets('incomplete records get an outline tag with a warning icon', (
      tester,
    ) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'tst', fields: 1, records: 1, invalid: 1);
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('tst'));
      final tag = find.byKey(const Key('collection-incomplete-c1'));
      expect(tag, findsOneWidget);
      expect(
        find.descendant(of: tag, matching: find.text('1 incomplete')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tag, matching: find.byIcon(FiIcons.warning)),
        findsOneWidget,
      );
    });

    testWidgets('a collection never edited shows no edit time', (tester) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'fresh');
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('fresh'));
      expect(find.text('0 records · 0 fields'), findsOneWidget);
      expect(find.byKey(const Key('collection-edited-c1')), findsNothing);
      expect(find.textContaining('Edited'), findsNothing);
    });

    testWidgets('a phone row is 64px tall with one subtitle line', (
      tester,
    ) async {
      await withClock(Clock.fixed(now), () async {
        _size(tester, const Size(390, 844));
        final bridge = _ready();
        _addCollection(
          bridge,
          'c1',
          'test',
          fields: 3,
          records: 6,
          editedMs: twoHoursAgo,
        );
        _addCollection(bridge, 'c2', 'tst', fields: 1, records: 1, invalid: 1);
        await tester.pumpWidget(app(bridge));
        await pumpUntilFound(tester, find.text('test'));
        expect(find.text('6 records · edited 2 h ago'), findsOneWidget);
        expect(find.text('1 record · 1 incomplete'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('c1'))).height,
          greaterThanOrEqualTo(64),
        );
      });
    });
  });

  group('sort', () {
    testWidgets('Last edited is the default and Name sorts A–Z', (
      tester,
    ) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'beta', editedMs: 3000);
      _addCollection(bridge, 'c2', 'Alpha', editedMs: 1000);
      _addCollection(bridge, 'c3', 'gamma', editedMs: 2000);
      _addCollection(bridge, 'c4', 'delta');
      final prefs = MemoryUiPrefsStore();
      await tester.pumpWidget(app(bridge, uiPrefs: prefs));
      await pumpUntilFound(tester, find.text('beta'));
      const names = ['beta', 'Alpha', 'gamma', 'delta'];
      expect(find.byKey(const Key('collections-sort-label')), findsOneWidget);
      expect(find.text('Last edited'), findsOneWidget);
      expect(_rowOrder(tester, names), ['beta', 'gamma', 'Alpha', 'delta']);

      await tester.tap(find.byKey(const Key('collections-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name').last);
      await tester.pumpAndSettle();
      expect(_rowOrder(tester, names), ['Alpha', 'beta', 'delta', 'gamma']);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('collections-sort-label')))
            .data,
        'Name',
      );
      expect(prefs.prefs.collectionSort, CollectionSort.name);
    });

    testWidgets('the chosen sort survives a restart', (tester) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'beta', editedMs: 3000);
      _addCollection(bridge, 'c2', 'Alpha', editedMs: 1000);
      final prefs = MemoryUiPrefsStore(
        const UiPrefs(collectionSort: CollectionSort.name),
      );
      await tester.pumpWidget(app(bridge, uiPrefs: prefs));
      await pumpUntilFound(tester, find.text('beta'));
      await tester.pump();
      expect(_rowOrder(tester, ['beta', 'Alpha']), ['Alpha', 'beta']);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('collections-sort-label')))
            .data,
        'Name',
      );
    });

    test('the controller restores the stored sort', () async {
      final prefs = MemoryUiPrefsStore();
      final first = CollectionsController(
        FakeCollectionBridge(),
        uiPrefs: prefs,
      );
      await first.start();
      first.setCollectionSort(CollectionSort.name);
      first.dispose();
      final second = CollectionsController(
        FakeCollectionBridge(),
        uiPrefs: prefs,
      );
      await second.start();
      await Future<void>.delayed(Duration.zero);
      expect(second.collectionSort, CollectionSort.name);
      second.dispose();
    });

    test('the prefs file round-trips and a corrupt file falls back', () async {
      final directory = await Directory.systemTemp.createTemp('fi-prefs');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileUiPrefsStore(() async => directory.path);
      expect((await store.load()).collectionSort, CollectionSort.lastEdited);
      await store.save(const UiPrefs(collectionSort: CollectionSort.name));
      expect(
        (await FileUiPrefsStore(
          () async => directory.path,
        ).load()).collectionSort,
        CollectionSort.name,
      );
      await File(
        '${directory.path}/${FileUiPrefsStore.fileName}',
      ).writeAsString('{not json');
      expect((await store.load()).collectionSort, CollectionSort.lastEdited);
      await File(
        '${directory.path}/${FileUiPrefsStore.fileName}',
      ).writeAsString('{"collection_sort": "sideways"}');
      expect((await store.load()).collectionSort, CollectionSort.lastEdited);
    });

    test('ties are broken by id', () {
      CollectionDto item(String id, String name, int? edited) => CollectionDto(
        id: id,
        name: name,
        description: '',
        recordCount: 0,
        fieldCount: 0,
        incompleteCount: 0,
        lastEditedMs: edited,
      );
      final items = [item('b', 'Same', 5), item('a', 'same', 5)];
      expect(sortCollections(items, CollectionSort.name).map((i) => i.id), [
        'a',
        'b',
      ]);
      expect(
        sortCollections(items, CollectionSort.lastEdited).map((i) => i.id),
        ['a', 'b'],
      );
    });
  });

  group('transfer menu', () {
    testWidgets('whole-dataset import and export stay beside the sort', (
      tester,
    ) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'Headaches');
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('Headaches'));
      final sort = tester.getCenter(find.byKey(const Key('collections-sort')));
      final transfer = tester.getCenter(
        find.byKey(const Key('collections-transfer-menu')),
      );
      expect((sort.dy - transfer.dy).abs(), lessThan(4));
      expect(transfer.dx, greaterThan(sort.dx));
      await tester.tap(find.byKey(const Key('collections-transfer-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Import JSON'), findsOneWidget);
      expect(find.text('Export all'), findsOneWidget);
      expect(find.text('Export selected'), findsOneWidget);
    });
  });

  group('row menu', () {
    testWidgets('the desktop menu is grouped, with F2 beside Rename', (
      tester,
    ) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'Headaches');
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('Headaches'));
      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      const labels = [
        'Rename',
        'Duplicate',
        'DATA',
        'Import CSV…',
        'Export CSV',
        'Export JSON',
        'Delete…',
      ];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('F2'), findsOneWidget);
      final tops = [
        for (final label in labels) tester.getTopLeft(find.text(label)).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(find.byType(PopupMenuDivider), findsNWidgets(2));
    });

    testWidgets('F2 on a focused row starts renaming it', (tester) async {
      _size(tester, const Size(1240, 800));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'Headaches');
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('Headaches'));
      Focus.of(tester.element(find.text('Headaches'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('Rename collection'), findsOneWidget);
    });

    testWidgets('a phone opens an action sheet headed by the collection', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      final bridge = _ready();
      _addCollection(bridge, 'c1', 'Headaches', fields: 3, records: 6);
      await tester.pumpWidget(app(bridge));
      await pumpUntilFound(tester, find.text('Headaches'));
      await tester.tap(find.byTooltip('Collection actions'));
      await tester.pumpAndSettle();
      expect(find.text('Headaches'), findsNWidgets(2));
      expect(find.text('6 records · 3 fields'), findsOneWidget);
      for (final label in [
        'Rename',
        'Duplicate',
        'DATA',
        'Import CSV…',
        'Export CSV',
        'Export JSON',
        'Delete…',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename collection'), findsOneWidget);
    });
  });
}
