import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

const _collection = 'c1';

/// A filter the fake reads as "the record number is even" (or odd).
ViewBodyDto _parity(String parity) => ViewBodyDto(
  filter: ExpressionDto(
    root: 0,
    nodes: [
      ExpressionNodeDto(
        kind: ExpressionKindDto.constant,
        value: TypedValueDto(
          valueType: const ValueTypeDto(kind: ValueTypeKindDto.text),
          textValue: parity,
        ),
      ),
    ],
  ),
  sorting: FakeCollectionBridge.allViewBody.sorting,
);

FakeCollectionBridge _seed({int count = 10}) {
  final bridge = FakeCollectionBridge();
  for (final id in [_collection, 'c2']) {
    bridge.collections.add(
      CollectionDto(
        id: id,
        name: id,
        description: '',
        recordCount: 0,
        fieldCount: 0,
        incompleteCount: 0,
      ),
    );
    bridge.schemas[id] = CollectionSchemaDto(
      id: id,
      name: id,
      description: '',
      fields: const [],
    );
  }
  bridge.records[_collection] = [
    for (var i = 0; i < count; i++)
      RecordDto(
        id: 'r$i',
        collectionId: _collection,
        values: const [],
        valid: true,
        diagnostics: const [],
        createdAtMs: i + 1,
      ),
  ];
  bridge.viewFilter = (record, filter) {
    final number = int.tryParse(record.id.substring(1));
    if (number == null) return false;
    final parity = filter.nodes[filter.root].value?.textValue;
    return parity == 'even' ? number.isEven : number.isOdd;
  };
  return bridge;
}

Future<CollectionsController> _open(
  FakeCollectionBridge bridge, {
  UiPrefsStore? store,
}) async {
  final controller = CollectionsController(bridge, uiPrefs: store);
  await controller.start();
  await controller.selectCollection(_collection);
  return controller;
}

List<String> _ids(CollectionsController controller) => [
  for (final record in controller.records) record.id,
];

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 250));

void main() {
  test(
    'records follow the selected view; allRecords keeps every record',
    () async {
      final bridge = _seed();
      final controller = await _open(bridge);
      expect(controller.activeViewId, allViewId);
      expect(_ids(controller).first, 'r9');
      await controller.saveAsNewView('Even', body: _parity('even'));
      expect(controller.activeView?.name, 'Even');
      expect(_ids(controller), ['r8', 'r6', 'r4', 'r2', 'r0']);
      expect(controller.allRecords, hasLength(10));
      expect(controller.views.map((view) => view.count), [10, 5]);
      controller.dispose();
    },
  );

  test('selection and draft survive a store reload', () async {
    final bridge = _seed();
    final store = MemoryUiPrefsStore();
    final first = await _open(bridge, store: store);
    final id = await first.saveAsNewView('Even', body: _parity('even'));
    await first.flipPrimarySort();
    expect(first.isModified, isTrue);
    first.dispose();

    final second = await _open(bridge, store: store);
    expect(second.activeViewId, id);
    expect(second.isModified, isTrue);
    expect(_ids(second), ['r0', 'r2', 'r4', 'r6', 'r8']);
    second.dispose();
  });

  test('a remembered view deleted remotely selects All', () async {
    final bridge = _seed();
    final store = MemoryUiPrefsStore();
    final first = await _open(bridge, store: store);
    final id = await first.saveAsNewView('Even', body: _parity('even'));
    first.dispose();
    await bridge.removeView(_collection, id);

    final second = await _open(bridge, store: store);
    expect(second.activeViewId, allViewId);
    expect(second.records, hasLength(10));
    await _settle();
    expect(store.prefs.views[_collection], isNull);
    second.dispose();
  });

  test(
    'a draft using a remotely deleted field is discarded with a notice',
    () async {
      final bridge = _seed();
      final controller = await _open(bridge);
      await controller.saveAsNewView('Even', body: _parity('even'));
      await controller.setDraft(_parity('odd'));
      expect(_ids(controller), ['r9', 'r7', 'r5', 'r3', 'r1']);
      bridge.isBrokenBody = (body) =>
          body.filter?.nodes.first.value?.textValue == 'odd';
      await controller.refresh();
      expect(controller.draftDiscarded, isTrue);
      expect(controller.viewDraft, isNull);
      expect(controller.isModified, isFalse);
      expect(_ids(controller), ['r8', 'r6', 'r4', 'r2', 'r0']);
      controller.dismissDraftDiscarded();
      expect(controller.draftDiscarded, isFalse);
      controller.dispose();
    },
  );

  test('⇅ makes the view modified and flipping back clears it', () async {
    final controller = await _open(_seed());
    await controller.saveAsNewView('Even', body: _parity('even'));
    await controller.flipPrimarySort();
    expect(controller.isModified, isTrue);
    expect(_ids(controller).first, 'r0');
    await controller.flipPrimarySort();
    expect(controller.isModified, isFalse);
    expect(controller.viewDraft, isNull);
    controller.dispose();
  });

  test('Save, Save as new view and Reset', () async {
    final bridge = _seed();
    final controller = await _open(bridge);
    final id = await controller.saveAsNewView('Even', body: _parity('even'));
    await controller.flipPrimarySort();
    expect(controller.canSaveView, isTrue);
    await controller.saveView();
    expect(controller.isModified, isFalse);
    expect(
      bridge.views[_collection]!.single.body!.sorting.single.direction,
      SortDirectionDto.ascending,
    );

    await controller.flipPrimarySort();
    await controller.resetView();
    expect(controller.isModified, isFalse);
    expect(_ids(controller).first, 'r0');

    await controller.flipPrimarySort();
    final copy = await controller.saveAsNewView('Even newest');
    expect(controller.activeViewId, copy);
    expect(controller.isModified, isFalse);
    expect(_ids(controller).first, 'r8');
    expect(bridge.views[_collection]!.map((view) => view.id), [id, copy]);
    controller.dispose();
  });

  test('All has no Save', () async {
    final controller = await _open(_seed());
    await controller.flipPrimarySort();
    expect(controller.isModified, isTrue);
    expect(controller.canSaveView, isFalse);
    expect(_ids(controller).first, 'r0');
    controller.dispose();
  });

  test('select all selects exactly what the view shows', () async {
    final controller = await _open(_seed());
    await controller.saveAsNewView('Even', body: _parity('even'));
    controller.selectAllShown();
    expect(controller.selectedRecordIds, hasLength(controller.viewCount));
    expect(controller.viewCount, 5);
    // A view change drops records it hides from the selection.
    await controller.selectView(allViewId);
    controller.toggleSelected('r1');
    await controller.selectView(controller.views.last.id);
    expect(controller.selectedRecordIds, isNot(contains('r1')));
    controller.dispose();
  });

  test('a broken view shows All\'s records and sets brokenView', () async {
    final bridge = _seed();
    final controller = await _open(bridge);
    final id = await controller.saveAsNewView('Even', body: _parity('even'));
    bridge.brokenViews[id] = 'field deleted';
    await controller.refresh();
    expect(controller.activeViewId, id);
    expect(controller.brokenView, isNotNull);
    expect(controller.records, hasLength(10));
    expect(_ids(controller).first, 'r9');
    controller.dispose();
  });

  test(
    'a burst of 20 data changes runs one listing and one execution',
    () async {
      final bridge = _seed();
      final controller = await _open(bridge);
      final listings = bridge.viewListings;
      final executions = bridge.viewExecutions;
      for (var i = 0; i < 20; i++) {
        bridge.changed(_collection);
      }
      await _settle();
      expect(bridge.viewListings, listings + 1);
      expect(bridge.viewExecutions, executions + 1);
      controller.dispose();
    },
  );

  test('view prefs of a deleted collection are pruned', () async {
    final bridge = _seed();
    final store = MemoryUiPrefsStore(
      const UiPrefs(views: {'gone': ViewPrefs(selected: 'v')}),
    );
    final controller = await _open(bridge, store: store);
    await controller.saveAsNewView('Even', body: _parity('even'));
    await _settle();
    expect(store.prefs.views.keys, [_collection]);
    controller.dispose();
  });

  test('a clone badge survives a view that hides the clone', () async {
    final controller = await _open(_seed());
    await controller.saveAsNewView('Even', body: _parity('even'));
    final created = await controller.cloneRecord('r2');
    expect(
      controller.records.map((r) => r.id),
      isNot(contains(created.single)),
    );
    expect(controller.isRecentClone(created.single), isTrue);
    expect(controller.allRecords.map((r) => r.id), contains(created.single));
    controller.dispose();
  });

  test('view name policy', () {
    const views = [
      ViewDto(id: allViewId, name: 'All', order: 0, effectiveSort: []),
      ViewDto(id: 'v1', name: 'Headaches', order: 1, effectiveSort: []),
    ];
    ViewNameProblem? check(String name, String all, {String? except}) =>
        viewNameProblem(name, allName: all, views: views, exceptViewId: except);
    expect(check('  ', 'All'), ViewNameProblem.empty);
    expect(check(' all ', 'All'), ViewNameProblem.reserved);
    expect(check('todos', 'Todos'), ViewNameProblem.reserved);
    expect(check('headaches', 'All'), ViewNameProblem.duplicate);
    expect(check('Headaches', 'All', except: 'v1'), isNull);
    expect(viewNameBlocksSave(ViewNameProblem.duplicate), isFalse);
    expect(viewNameBlocksSave(ViewNameProblem.reserved), isTrue);
  });

  test('ViewPrefs JSON is read tolerantly', () {
    final prefs = UiPrefs.fromJson({
      'views': {
        'a': {
          'selected': 'v1',
          'draft': {'sorting': []},
        },
        'b': 'junk',
        'c': {'selected': 3},
      },
    });
    expect(prefs.views.keys, ['a']);
    expect(UiPrefs.fromJson(prefs.toJson()).views['a']?.selected, 'v1');
  });
}
