import 'package:fi/app.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Widget app(FakeCollectionBridge bridge) => CollectionApp(
  bridge: bridge,
  initializeRust: () async {},
  dataDirProvider: () async => '/test',
  setPlatformForeground: (_) async {},
);
Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

void main() {
  testWidgets('onboarding gates collection entry', (tester) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('Create new dataset'));
    expect(find.text('Collections'), findsNothing);
    await tester.tap(find.byKey(const Key('create-dataset')));
    await pumpUntilFound(tester, find.text('Collections'));
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('collection and schema-driven record CRUD renders', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      );
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('New collection'));
    await tester.tap(find.text('New collection'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('collection-name')),
      'Headaches',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Headaches'), findsOneWidget);
    await tester.tap(find.text('Headaches'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Schema'), findsOneWidget);
    expect(find.byTooltip('New record'), findsOneWidget);
    await tester.tap(find.byTooltip('Schema'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add field'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-name')), 'Title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Title'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New record'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'After lunch');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('After lunch'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete record'));
    await tester.pumpAndSettle();
    expect(find.text('No records yet.'), findsOneWidget);
  });

  testWidgets('collection dialog displays typed Rust validation errors', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      );
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.text('New collection'));
    await tester.tap(find.text('New collection'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('collection-name')), 'Invalid');
    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.validation,
      field: 'name',
      message: 'Name is required.',
      resetResolvable: false,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Name is required.'), findsOneWidget);
  });

  testWidgets('navigation switches between compact and wide layouts', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    await tester.pumpWidget(app(bridge));
    await pumpUntilFound(tester, find.byType(NavigationBar));
    expect(find.byType(NavigationRail), findsNothing);
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
