import 'package:fi/app.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Widget app(FakeFinanceBridge bridge) => FinanceApp(
  bridge: bridge,
  initializeRust: () async {},
  dataDirProvider: () async => '/test',
  setPlatformForeground: (_) async {},
);

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

void main() {
  testWidgets('onboarding gates finance entry and explains joining', (
    tester,
  ) async {
    final bridge = FakeFinanceBridge();
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('Create new dataset'));
    expect(find.text('Create new dataset'), findsOneWidget);
    expect(find.text('Transactions'), findsNothing);
    final join = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Join an existing dataset'),
    );
    expect(join.onPressed, isNull);
    expect(find.textContaining('secure device pairing'), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-dataset')));
    await pumpUntilFound(tester, find.text('Transactions'));
    expect(find.text('Transactions'), findsWidgets);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('Rust validation remains visible in the category form', (
    tester,
  ) async {
    final bridge = FakeFinanceBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      )
      ..failNextCategory = true;
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('Transactions'));
    await tester.tap(find.text('Categories').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('category-name')), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Name is required.'), findsOneWidget);
    expect(bridge.categories, isEmpty);
  });
}
