import 'package:fi/crash_reporting.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

FakeCollectionBridge _ready() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(kind: BootstrapKindDto.ready, rootId: 'root')
  ..buildIdentity = const BuildInfoDto(
    version: '0.1.21',
    gitHash: 'a1b2c3d',
    dirty: false,
  );

Future<void> _openSettings(
  WidgetTester tester, {
  required UiPrefsStore store,
  Size size = const Size(1200, 2000),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    app(_ready(), uiPrefs: store, capabilities: PlatformCapabilities.desktop),
  );
  await pumpUntilFound(tester, find.text('Collections'));

  await tester.tap(find.byKey(const Key('nav-settings')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Diagnostics section renders with default enabled and placeholder status',
    (tester) async {
      final store = MemoryUiPrefsStore(const UiPrefs());
      await _openSettings(tester, store: store);

      expect(find.byKey(const Key('settings-diagnostics')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-diagnostics-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-diagnostics-switch')),
        findsOneWidget,
      );

      final switchWidget = tester.widget<FiSwitch>(
        find.byKey(const Key('settings-diagnostics-switch')),
      );
      expect(switchWidget.value, isTrue);

      expect(find.text('Placeholder / Standby'), findsOneWidget);
      expect(
        find.text(CrashReportingConfig.defaultPlaceholderDsn),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Toggling crash reporting off disables reporting and updates status',
    (tester) async {
      final store = MemoryUiPrefsStore(const UiPrefs());
      await _openSettings(tester, store: store);

      // Tap toggle switch
      await tester.tap(find.byKey(const Key('settings-diagnostics-switch')));
      await tester.pumpAndSettle();

      expect(find.text('Disabled'), findsOneWidget);
      final savedPrefs = await store.load();
      expect(savedPrefs.crashReportingEnabled, isFalse);
      expect(CrashReportingService.isEnabled, isFalse);
    },
  );

  testWidgets(
    'Saving custom DSN updates status to Connected and persists override',
    (tester) async {
      final store = MemoryUiPrefsStore(const UiPrefs());
      await _openSettings(tester, store: store);

      const customDsn = 'https://mytoken@bugsink.corp.internal:8000/1';
      final inputFinder = find.byKey(
        const Key('settings-diagnostics-dsn-input'),
      );
      await tester.enterText(
        find.descendant(of: inputFinder, matching: find.byType(TextField)),
        customDsn,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-diagnostics-dsn-save')));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
      final endpointText = tester.widget<Text>(
        find.byKey(const Key('settings-diagnostics-endpoint-text')),
      );
      expect(endpointText.data, customDsn);

      final savedPrefs = await store.load();
      expect(savedPrefs.customSentryDsn, customDsn);

      // Reset button should now be present
      expect(
        find.byKey(const Key('settings-diagnostics-dsn-reset')),
        findsOneWidget,
      );

      // Tap Reset
      await tester.tap(find.byKey(const Key('settings-diagnostics-dsn-reset')));
      await tester.pumpAndSettle();

      expect(find.text('Placeholder / Standby'), findsOneWidget);
      expect(
        find.text(CrashReportingConfig.defaultPlaceholderDsn),
        findsOneWidget,
      );
      final resetPrefs = await store.load();
      expect(resetPrefs.customSentryDsn, isNull);
    },
  );
}
