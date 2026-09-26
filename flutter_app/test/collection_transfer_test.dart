import 'package:fi/controllers.dart';
import 'package:fi/file_dialogs.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show seeded;
import 'fake_bridge.dart';
import 'widget_test.dart';

const _collection = 'collection-1';

const _csvAbort = ImportOutcomeDto(
  imported: false,
  recordCount: 0,
  collectionIds: [],
  row: 12,
  column: 'Onset',
  reason: '"yesterday" is not a date (YYYY-MM-DD)',
  message: 'row 12, column Onset: "yesterday" is not a date (YYYY-MM-DD)',
);

/// Two collections: the seeded "Headaches" with [records] records, and an empty "Sleep".
FakeCollectionBridge _bridge([int records = 2]) {
  final bridge = seeded(records);
  bridge.collections.add(
    const CollectionDto(id: 'collection-2', name: 'Sleep', description: ''),
  );
  bridge.schemas['collection-2'] = const CollectionSchemaDto(
    id: 'collection-2',
    name: 'Sleep',
    description: '',
    fields: [],
  );
  bridge.records['collection-2'] = [];
  return bridge;
}

Future<CollectionsController> _controller(
  FakeCollectionBridge bridge,
  FakeFileDialogs dialogs,
) async {
  final controller = CollectionsController(bridge, fileDialogs: dialogs);
  await controller.start();
  return controller;
}

Future<void> _showList(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  FakeFileDialogs dialogs,
) async {
  await tester.pumpWidget(app(bridge, fileDialogs: dialogs));
  await pumpUntilFound(tester, find.text('Headaches'));
}

/// Chooses [label] from the menu of the first collection card.
Future<void> _collectionAction(WidgetTester tester, String label) async {
  await tester.tap(find.byIcon(Icons.more_vert).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Chooses [label] from the collections list's import/export menu.
Future<void> _listAction(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('collections-transfer-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  group('controller', () {
    test('exports pass Rust text to the save dialog', () async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = 'Headaches.csv';
      final controller = await _controller(bridge, dialogs);
      final headaches = controller.collections.first;

      expect(await controller.exportCsv(headaches), 'Headaches.csv');
      await controller.exportJson(controller.collections);
      await controller.exportAll();
      expect(bridge.exports, [
        'csv $_collection',
        'json $_collection,collection-2',
        'json all',
      ]);
      expect(dialogs.written, [
        ('Headaches.csv', 'csv of $_collection'),
        ('collections.json', 'json of $_collection,collection-2'),
        ('collections.json', 'json of all'),
      ]);
      controller.dispose();
    });

    test('a dismissed save dialog writes nothing', () async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = null;
      final controller = await _controller(bridge, dialogs);
      expect(await controller.exportCsv(controller.collections.first), isNull);
      expect(await controller.exportAll(), isNull);
      expect(dialogs.written, isEmpty);
      controller.dispose();
    });

    test('a dismissed open dialog sends no import', () async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs();
      final controller = await _controller(bridge, dialogs);
      expect(await controller.importCsv(_collection), isNull);
      expect(await controller.importJson(), isNull);
      expect(dialogs.opened, [FileKind.csv, FileKind.json]);
      expect(bridge.imports, isEmpty);
      controller.dispose();
    });

    test('an import passes the file text through and refreshes', () async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..openResult = 'Title\na\nb\nc\n';
      final controller = await _controller(bridge, dialogs);
      await controller.selectCollection(_collection);
      final outcome = await controller.importCsv(_collection);
      expect(outcome!.imported, isTrue);
      expect(outcome.recordCount, 3);
      expect(bridge.imports, [(_collection, 'Title\na\nb\nc\n')]);
      expect(controller.records, hasLength(5));

      dialogs.openResult = 'Imported\n';
      final json = await controller.importJson();
      expect(json!.collectionIds, hasLength(1));
      expect(
        controller.collections.map((item) => item.name),
        contains('Imported'),
      );
      controller.dispose();
    });

    test(
      'an abort outcome propagates unchanged and nothing refreshes',
      () async {
        final bridge = _bridge();
        final dialogs = FakeFileDialogs()..openResult = 'Onset\nyesterday\n';
        final controller = await _controller(bridge, dialogs);
        bridge.nextImportOutcome = _csvAbort;
        final outcome = await controller.importCsv(_collection);
        expect(outcome, _csvAbort);
        expect(bridge.records[_collection], hasLength(2));
        expect(
          importOutcomeMessage(outcome!, csv: true),
          'Import stopped. Row 12, column Onset: '
          '"yesterday" is not a date (YYYY-MM-DD)',
        );
        controller.dispose();
      },
    );

    test('outcome messages name counts and JSON abort locations', () {
      expect(
        importOutcomeMessage(
          const ImportOutcomeDto(
            imported: true,
            recordCount: 120,
            collectionIds: [],
            message: '',
          ),
          csv: true,
        ),
        '120 records imported',
      );
      expect(
        importOutcomeMessage(
          const ImportOutcomeDto(
            imported: true,
            recordCount: 9,
            collectionIds: ['a', 'b'],
            message: '',
          ),
          csv: false,
        ),
        '2 collections imported',
      );
      expect(
        importOutcomeMessage(
          const ImportOutcomeDto(
            imported: false,
            recordCount: 0,
            collectionIds: [],
            collectionIndex: 2,
            item: 'record 1',
            reason: 'Required',
            message: '',
          ),
          csv: false,
        ),
        'Import stopped. Collection 3, record 1: Required',
      );
      expect(
        importOutcomeMessage(
          const ImportOutcomeDto(
            imported: false,
            recordCount: 0,
            collectionIds: [],
            row: 0,
            column: 'Mood',
            reason: 'no active field has this name',
            message: '',
          ),
          csv: true,
        ),
        'Import stopped. Header, column Mood: no active field has this name',
      );
    });

    test('file stems drop characters file systems reject', () {
      expect(exportFileStem('Money / Moves: 2024?'), 'Money - Moves- 2024-');
      expect(exportFileStem('   '), 'collection');
    });
  });

  group('collections list', () {
    testWidgets('Export CSV writes the file and names it', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = 'Headaches.csv';
      await _showList(tester, bridge, dialogs);
      await _collectionAction(tester, 'Export CSV');
      expect(dialogs.written, [('Headaches.csv', 'csv of $_collection')]);
      expect(find.text('Exported to Headaches.csv'), findsOneWidget);
    });

    testWidgets('Export JSON exports that one collection', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = 'Headaches.json';
      await _showList(tester, bridge, dialogs);
      await _collectionAction(tester, 'Export JSON');
      expect(bridge.exports, ['json $_collection']);
      expect(find.text('Exported to Headaches.json'), findsOneWidget);
    });

    testWidgets('cancelling the save dialog shows nothing', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = null;
      await _showList(tester, bridge, dialogs);
      await _collectionAction(tester, 'Export CSV');
      expect(dialogs.written, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a failed export shows the Rust reason', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs();
      await _showList(tester, bridge, dialogs);
      bridge.nextError = const BridgeError(
        kind: BridgeErrorKind.validation,
        issues: [],
        message: 'two columns are named "Notes"; rename one to export',
        resetResolvable: false,
      );
      await _collectionAction(tester, 'Export CSV');
      expect(dialogs.written, isEmpty);
      expect(
        find.text('two columns are named "Notes"; rename one to export'),
        findsOneWidget,
      );
    });

    testWidgets('Import CSV reports the imported count', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..openResult = 'Title\na\nb\n';
      await _showList(tester, bridge, dialogs);
      await _collectionAction(tester, 'Import CSV');
      expect(bridge.imports, [(_collection, 'Title\na\nb\n')]);
      expect(bridge.records[_collection], hasLength(4));
      expect(find.text('2 records imported'), findsOneWidget);
    });

    testWidgets('a CSV abort states row, column and reason', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..openResult = 'Onset\nyesterday\n';
      bridge.nextImportOutcome = _csvAbort;
      await _showList(tester, bridge, dialogs);
      await _collectionAction(tester, 'Import CSV');
      expect(
        find.text(
          'Import stopped. Row 12, column Onset: '
          '"yesterday" is not a date (YYYY-MM-DD)',
        ),
        findsOneWidget,
      );
      expect(bridge.records[_collection], hasLength(2));
    });

    testWidgets('Export all exports every collection', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = 'collections.json';
      await _showList(tester, bridge, dialogs);
      await _listAction(tester, 'Export all');
      expect(bridge.exports, ['json all']);
      expect(find.text('Exported to collections.json'), findsOneWidget);
    });

    testWidgets('Export selected exports only the picked collections', (
      tester,
    ) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..saveResult = 'collections.json';
      await _showList(tester, bridge, dialogs);
      await _listAction(tester, 'Export selected');
      final confirm = find.byKey(const Key('confirm-export-selected'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const Key('export-pick-collection-2')));
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(bridge.exports, ['json collection-2']);
      expect(find.text('Exported to collections.json'), findsOneWidget);
    });

    testWidgets('Import JSON adds collections and leaves others alone', (
      tester,
    ) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs()..openResult = 'Mood\nSteps\n';
      await _showList(tester, bridge, dialogs);
      await _listAction(tester, 'Import JSON');
      expect(find.text('2 collections imported'), findsOneWidget);
      await pumpUntilFound(tester, find.text('Steps'));
      expect(find.text('Mood'), findsOneWidget);
      expect(find.text('Headaches'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
    });

    testWidgets('cancelling the open dialog imports nothing', (tester) async {
      final bridge = _bridge();
      final dialogs = FakeFileDialogs();
      await _showList(tester, bridge, dialogs);
      await _listAction(tester, 'Import JSON');
      expect(bridge.imports, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
