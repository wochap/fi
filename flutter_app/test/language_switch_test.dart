import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

FakeCollectionBridge _readyBridge() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearLocalesTestValue();
    Intl.defaultLocale = null;
  });

  testWidgets('a stored Spanish preference shows the app in Spanish', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        _readyBridge(),
        uiPrefs: MemoryUiPrefsStore(
          const UiPrefs(appLanguage: AppLanguage.spanish),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Colecciones'));
    expect(find.text('Dispositivos'), findsOneWidget);
    expect(find.text('Ajustes'), findsOneWidget);
  });

  testWidgets('an unsupported system language falls back to English', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.localesTestValue = const [Locale('fr')];
    await tester.pumpWidget(app(_readyBridge()));
    await pumpUntilFound(tester, find.text('Collections'));
  });
}
