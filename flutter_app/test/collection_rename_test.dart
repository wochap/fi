import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show openCollection, seeded;
import 'fake_bridge.dart';
import 'widget_test.dart';

final _title = find.byKey(const Key('collection-title'));
final _input = find.byKey(const Key('collection-title-input'));

Future<void> _useSize(WidgetTester tester, Size size) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

/// Opens the seeded "Headaches" collection and double taps its title.
Future<FakeCollectionBridge> _startEditing(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  await _useSize(tester, size);
  final bridge = seeded(1);
  await openCollection(tester, bridge);
  await tester.tap(_title);
  await tester.pump(kDoubleTapMinTime);
  await tester.tap(_title);
  await tester.pumpAndSettle();
  return bridge;
}

String _titleText(WidgetTester tester) => tester.widget<Text>(_title).data!;

Future<void> _blur(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void main() {
  for (final (label, size) in [
    ('wide', const Size(1280, 800)),
    ('narrow', const Size(390, 844)),
  ]) {
    testWidgets('double tap edits the title with the name selected ($label)', (
      tester,
    ) async {
      await _startEditing(tester, size: size);
      expect(_input, findsOneWidget);
      expect(_title, findsNothing);
      final field = tester.widget<EditableText>(
        find.descendant(of: _input, matching: find.byType(EditableText)),
      );
      expect(field.controller.text, 'Headaches');
      expect(
        field.controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 9),
      );
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('Enter saves the trimmed name ($label)', (tester) async {
      final bridge = await _startEditing(tester, size: size);
      await tester.enterText(_input, '  Migraines ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(bridge.renames, ['Migraines']);
      expect(_input, findsNothing);
      expect(_titleText(tester), 'Migraines');
    });
  }

  testWidgets('losing focus saves', (tester) async {
    final bridge = await _startEditing(tester);
    await tester.enterText(_input, 'Migraines');
    await _blur(tester);
    expect(bridge.renames, ['Migraines']);
    expect(_input, findsNothing);
    expect(_titleText(tester), 'Migraines');
  });

  testWidgets('Escape cancels without renaming', (tester) async {
    final bridge = await _startEditing(tester);
    await tester.enterText(_input, 'Migraines');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(bridge.renames, isEmpty);
    expect(_input, findsNothing);
    expect(_titleText(tester), 'Headaches');
  });

  for (final text in ['', '   ']) {
    testWidgets('empty name "$text" cancels silently on Enter and blur', (
      tester,
    ) async {
      final bridge = await _startEditing(tester);
      await tester.enterText(_input, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_input, findsNothing);

      await tester.tap(_title);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(_title);
      await tester.pumpAndSettle();
      await tester.enterText(_input, text);
      await _blur(tester);

      expect(bridge.renames, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(_titleText(tester), 'Headaches');
    });
  }

  testWidgets('unchanged name cancels silently', (tester) async {
    final bridge = await _startEditing(tester);
    await tester.enterText(_input, ' Headaches  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(bridge.renames, isEmpty);
    expect(_input, findsNothing);
    expect(_titleText(tester), 'Headaches');
  });

  testWidgets('rejected rename restores the title and shows a snackbar', (
    tester,
  ) async {
    final bridge = await _startEditing(tester);
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      issues: [],
      message: 'Collection name is invalid.',
      resetResolvable: false,
    );
    await tester.enterText(_input, 'Migraines');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(bridge.renames, isEmpty);
    expect(_input, findsNothing);
    expect(_titleText(tester), 'Headaches');
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Collection name is invalid.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('list menu Rename still opens the Rename dialog', (tester) async {
    final bridge = seeded(1);
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename collection'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('collection-name')), 'Gym');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(bridge.renames, ['Gym']);
    expect(find.text('Gym'), findsWidgets);
  });
}
