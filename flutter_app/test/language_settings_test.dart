import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

FakeCollectionBridge _ready() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );

Future<void> _openSettings(
  WidgetTester tester, {
  required PlatformCapabilities capabilities,
  required Size size,
  UiPrefsStore? prefs,
  VoiceServices? voice,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(_ready(), capabilities: capabilities, uiPrefs: prefs, voice: voice),
  );
  await pumpUntilFound(tester, find.text('Collections'));
  await tester.tap(
    size.width >= 720
        ? find.byKey(const Key('nav-settings'))
        : find.text('Settings'),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => Intl.defaultLocale = null);

  testWidgets('desktop shows the language dropdown above About', (
    tester,
  ) async {
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.desktop,
      size: const Size(1240, 900),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('settings-language'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('settings-about'))).dy),
    );
    expect(find.text('App language'), findsOneWidget);
    expect(find.text('System default (English)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-language-dropdown')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('language-option-system')), findsWidgets);
    expect(find.byKey(const Key('language-option-en')), findsWidgets);
    expect(find.byKey(const Key('language-option-es')), findsWidgets);
    expect(find.text('Español'), findsWidgets);
  });

  testWidgets('Android lists Language first with the phone language', (
    tester,
  ) async {
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.androidPhone,
      size: const Size(390, 2400),
      voice: fakeVoiceServices(),
    );
    final tops = [
      for (final label in ['LANGUAGE', 'VOICE INPUT', 'MICROPHONE', 'ABOUT'])
        tester.getTopLeft(find.text(label)).dy,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i - 1], lessThan(tops[i]));
    }
    expect(find.text('English — same as your phone'), findsOneWidget);
  });

  testWidgets('Android: choosing Español switches at once and is stored', (
    tester,
  ) async {
    final prefs = MemoryUiPrefsStore();
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.androidPhone,
      size: const Size(390, 844),
      prefs: prefs,
    );
    await tester.tap(find.byKey(const Key('language-option-es')));
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsWidgets);
    expect(find.text('IDIOMA'), findsOneWidget);
    expect(find.text('Predeterminado del sistema'), findsOneWidget);
    expect(find.text('English — igual que tu teléfono'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(prefs.prefs.appLanguage, AppLanguage.spanish);
  });

  testWidgets('desktop: choosing Español from the dropdown', (tester) async {
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.desktop,
      size: const Size(1240, 900),
    );
    await tester.tap(find.byKey(const Key('settings-language-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language-option-es')).last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('sidebar')),
        matching: find.text('Ajustes'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-subtitle')),
        matching: find.text('Preferencias para esta computadora.'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
  });
}
