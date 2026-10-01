import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show openCollection, seeded;

const _sizes = {'phone': Size(390, 844), 'wide': Size(1280, 800)};

void _setSize(WidgetTester tester, Size size) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester) async {
  await tester.longPress(find.text('row 0'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('row 1'));
  await tester.pumpAndSettle();
  expect(find.text('2 selected'), findsOneWidget);
}

final _inCollection = find.text('row 2');
final _collectionTile = find.text('Headaches');

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    group('system back ($name)', () {
      late List<String> platformCalls;

      Future<void> start(WidgetTester tester) async {
        _setSize(tester, size);
        platformCalls = [];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            platformCalls.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await openCollection(tester, seeded(3));
      }

      bool left() => platformCalls.contains('SystemNavigator.pop');

      testWidgets('clears selection mode and stays in the collection', (
        tester,
      ) async {
        await start(tester);
        await _select(tester);
        await _back(tester);
        expect(find.textContaining('selected'), findsNothing);
        expect(_inCollection, findsOneWidget);
        expect(left(), isFalse);
      });

      testWidgets('returns from an open collection to the list', (
        tester,
      ) async {
        await start(tester);
        await _back(tester);
        expect(_inCollection, findsNothing);
        expect(_collectionTile, findsOneWidget);
        expect(left(), isFalse);
      });

      for (final tab in ['Devices', 'Settings']) {
        testWidgets('returns from $tab to Collections', (tester) async {
          await start(tester);
          await _back(tester);
          await tester.tap(find.text(tab).last);
          await tester.pumpAndSettle();
          expect(_collectionTile, findsNothing);
          await _back(tester);
          expect(_collectionTile, findsOneWidget);
          expect(left(), isFalse);
        });
      }

      testWidgets('leaves the app from the collections list', (tester) async {
        await start(tester);
        await _back(tester);
        expect(left(), isFalse);
        await _back(tester);
        expect(left(), isTrue);
      });

      testWidgets('unwinds step by step', (tester) async {
        await start(tester);
        await _select(tester);
        await _back(tester);
        expect(find.textContaining('selected'), findsNothing);
        expect(_inCollection, findsOneWidget);
        await _back(tester);
        expect(_inCollection, findsNothing);
        expect(_collectionTile, findsOneWidget);
        expect(left(), isFalse);
        await _back(tester);
        expect(left(), isTrue);
      });

      testWidgets('closes the record editor before the shell', (tester) async {
        await start(tester);
        await tester.tap(find.text('row 0'));
        await tester.pumpAndSettle();
        expect(find.text('Edit record'), findsOneWidget);
        await _back(tester);
        expect(find.text('Edit record'), findsNothing);
        expect(_inCollection, findsOneWidget);
        expect(left(), isFalse);
      });
    });
  }
}
