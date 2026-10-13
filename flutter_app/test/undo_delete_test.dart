import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show openCollection, seeded;

void _size(WidgetTester tester, double width, [double height = 900]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _toast() => find.byKey(const Key('undo-delete-toast'));

Future<void> _deleteCard(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('card-delete-$id')));
  await tester.pumpAndSettle();
}

Future<void> _deleteRow(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('record-row-menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('record-row-delete')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deletes accumulate in the same toast and Undo restores both', (
    tester,
  ) async {
    _size(tester, 390);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await _deleteCard(tester, 'record-0');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Deleted 1 record'), findsOneWidget);
    expect(find.text('row 0'), findsNothing);
    final toast = tester.element(_toast());

    await _deleteCard(tester, 'record-1');
    expect(find.text('Deleted 2 records'), findsOneWidget);
    expect(tester.element(_toast()), same(toast), reason: 'not re-shown');
    expect(
      find.descendant(
        of: find.byKey(const Key('undo-delete')),
        matching: find.byIcon(FiIcons.undo),
      ),
      findsOneWidget,
    );
    expect(find.text('Ctrl Z'), findsNothing, reason: 'no hint on a phone');

    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pump();
    // Restored cards enter over 200ms; the tint lasts longer.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 1'), findsOneWidget);
    expect(find.byKey(const Key('restored-tint-record-0')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_toast(), findsNothing);
    expect(find.byKey(const Key('restored-tint-record-0')), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(bridge.batchDeleteCalls, isEmpty);
  });

  testWidgets('a card collapses over 200ms, at once under reduced motion', (
    tester,
  ) async {
    _size(tester, 390);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await tester.tap(find.byKey(const Key('card-delete-record-0')));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget, reason: 'still leaving');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('row 0'), findsNothing);

    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pumpAndSettle();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byKey(const Key('card-delete-record-0')));
    await tester.pump();
    expect(find.text('row 0'), findsNothing);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pump();
    expect(find.text('row 0'), findsOneWidget);
    expect(
      find.byKey(const Key('restored-tint-record-0')),
      findsOneWidget,
      reason: 'the tint still shows',
    );
    await tester.pumpAndSettle();
  });

  testWidgets('the timer commits one batch and dismisses the toast', (
    tester,
  ) async {
    _size(tester, 390);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await _deleteCard(tester, 'record-0');
    await _deleteCard(tester, 'record-1');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(bridge.batchDeleteCalls, [
      ['record-0', 'record-1'],
    ]);
    expect(_toast(), findsNothing);
  });

  testWidgets('hovering the toast holds the commit', (tester) async {
    _size(tester, 1240);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await _deleteRow(tester, 'record-0');
    expect(find.text('Ctrl Z'), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Deleted 1 record')));
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.batchDeleteCalls, isEmpty);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 4900));
    expect(bridge.batchDeleteCalls, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(bridge.batchDeleteCalls, hasLength(1));
  });

  testWidgets('backgrounding commits at once', (tester) async {
    _size(tester, 390);
    final bridge = seeded(2);
    await openCollection(tester, bridge);
    await _deleteCard(tester, 'record-0');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(bridge.batchDeleteCalls, isEmpty, reason: 'inactive is ignored');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(bridge.batchDeleteCalls, [
      ['record-0'],
    ]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  testWidgets('Ctrl Z restores rows; it is ignored with nothing pending', (
    tester,
  ) async {
    _size(tester, 1240);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await _deleteRow(tester, 'record-0');
    expect(find.text('row 0'), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);
    expect(_toast(), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(bridge.batchDeleteCalls, isEmpty);
  });

  testWidgets('Ctrl Z in a focused text field leaves the delete pending', (
    tester,
  ) async {
    _size(tester, 1240);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await _deleteRow(tester, 'record-0');
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextFormField, 'row 1'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Deleted 1 record'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsNothing);
  });

  testWidgets('batch delete of 12 of 18 on desktop', (tester) async {
    _size(tester, 1240, 1600);
    final bridge = seeded(18);
    await openCollection(tester, bridge);
    expect(find.textContaining('18 records'), findsWidgets);
    await tester.tap(find.byKey(const Key('select-records')));
    await tester.pumpAndSettle();
    for (var index = 0; index < 12; index++) {
      await tester.tap(find.text('row $index'));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
    expect(find.text('12 selected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('batch-delete')));
    await tester.pumpAndSettle();
    expect(find.text('12 selected'), findsNothing);
    expect(find.textContaining('6 records'), findsWidgets);
    expect(find.text('Deleted 12 records'), findsOneWidget);
    expect(find.text('Ctrl Z'), findsOneWidget);
    expect(find.text('row 0'), findsNothing);
  });

  testWidgets('a rejected commit shows the count and the typed message', (
    tester,
  ) async {
    _size(tester, 390);
    final bridge = seeded(3);
    await openCollection(tester, bridge);
    await _deleteCard(tester, 'record-0');
    await _deleteCard(tester, 'record-1');
    bridge.nextBatchError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [],
      message: 'record locked',
      resetResolvable: false,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text("Couldn't delete 2 records"), findsOneWidget);
    expect(find.text('record locked'), findsOneWidget);
    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row 1'), findsOneWidget);
    expect(find.byKey(const Key('restored-tint-record-0')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_toast(), findsNothing);
  });
}
