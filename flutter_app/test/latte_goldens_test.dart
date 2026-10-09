// Latte golden files, a review aid for role choices that only show on the
// light theme. Compare each with its mock in `design/project/Fi Redesign.dc.html`
// toggled to `data-theme="light"`. Regenerate on the Linux test host with
// `flutter test --update-goldens test/latte_goldens_test.dart`.
import 'dart:convert';

import 'package:fi/platform_capabilities.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/services.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_records_test.dart' show seeded;
import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

/// Loads every font in the manifest (Inter, JetBrains Mono, the icon fonts),
/// so goldens render text as the app does.
Future<void> _loadFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font in (family['fonts']! as List).cast<Map>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

const _sizes = {'desktop': Size(1280, 800), 'phone': Size(390, 844)};

Future<void> _pumpLatte(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  Size size, {
  VoiceServices? voice,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(
      bridge,
      capabilities: size.width >= 720
          ? PlatformCapabilities.desktop
          : PlatformCapabilities.androidPhone,
      uiPrefs: MemoryUiPrefsStore(const UiPrefs(appTheme: AppThemeMode.light)),
      voice: voice,
    ),
  );
}

Future<void> _openTab(WidgetTester tester, String label, Size size) async {
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _openHeadaches(WidgetTester tester, Size size) async {
  await _pumpLatte(tester, seeded(3), size);
  await pumpUntilFound(tester, find.text('Headaches'));
  await tester.tap(find.text('Headaches'));
  await tester.pumpAndSettle();
}

Future<void> _settingsWithVoice(
  WidgetTester tester,
  Size size,
  ModelStatusKindDto kind,
) async {
  // Voice sections show on Android only, so both sizes use phone capabilities.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(
      seeded(0),
      capabilities: PlatformCapabilities.androidPhone,
      uiPrefs: MemoryUiPrefsStore(const UiPrefs(appTheme: AppThemeMode.light)),
      voice: fakeVoiceServices(models: FakeVoiceModels(modelStatusOf(kind))),
    ),
  );
  await pumpUntilFound(tester, find.text('Collections'));
  await _openTab(tester, 'Settings', size);
}

/// Each mock id with how to reach its screen.
final Map<String, Future<void> Function(WidgetTester, Size)> _screens = {
  'onboarding-first-run': (tester, size) async {
    await _pumpLatte(tester, FakeCollectionBridge(), size);
    await pumpUntilFound(tester, find.text('Create a new dataset'));
    await tester.pumpAndSettle();
  },
  'collections': (tester, size) async {
    await _pumpLatte(tester, seeded(3), size);
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.pumpAndSettle();
  },
  'collection-records': (tester, size) async {
    await _pumpLatte(tester, seeded(3), size);
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.tap(find.text('Headaches'));
    await tester.pumpAndSettle();
  },
  'record-form-empty': (tester, size) async {
    await _pumpLatte(tester, seeded(3), size);
    await pumpUntilFound(tester, find.text('Headaches'));
    await tester.tap(find.text('Headaches'));
    await tester.pumpAndSettle();
    final tip = find.byTooltip('New record');
    await tester.tap(
      tip.evaluate().isNotEmpty ? tip.first : find.text('New record').first,
    );
    await tester.pumpAndSettle();
  },
  'collection-selection': (tester, size) async {
    await _openHeadaches(tester, size);
    await tester.longPress(find.text('row 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row 1'));
    await tester.pumpAndSettle();
  },
  'record-form-edit': (tester, size) async {
    await _openHeadaches(tester, size);
    await tester.tap(find.text('row 0'));
    await tester.pumpAndSettle();
  },
  'schema-sheet': (tester, size) async {
    await _openHeadaches(tester, size);
    final schema = find.byTooltip('Schema');
    await tester.tap(
      schema.evaluate().isNotEmpty ? schema.first : find.text('Schema').first,
    );
    await tester.pumpAndSettle();
  },
  'settings-language': (tester, size) async {
    await _pumpLatte(tester, seeded(0), size);
    await pumpUntilFound(tester, find.text('Collections'));
    await _openTab(tester, 'Settings', size);
    // The phone shows a radio list; the desktop dropdown opens.
    final dropdown = find.byKey(const Key('settings-language-dropdown'));
    if (dropdown.evaluate().isNotEmpty) {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
    }
  },
  'settings-model-states': (tester, size) =>
      _settingsWithVoice(tester, size, ModelStatusKindDto.ready),
  'settings-microphone': (tester, size) async {
    await _settingsWithVoice(tester, size, ModelStatusKindDto.ready);
    await tester.scrollUntilVisible(
      find.text('MICROPHONE'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
  },
  'devices': (tester, size) async {
    await _pumpLatte(tester, seeded(0), size);
    await pumpUntilFound(tester, find.text('Collections'));
    await _openTab(tester, 'Devices', size);
  },
  'settings': (tester, size) async {
    await _pumpLatte(tester, seeded(0), size);
    await pumpUntilFound(tester, find.text('Collections'));
    await _openTab(tester, 'Settings', size);
  },
};

void main() {
  setUpAll(_loadFonts);

  for (final MapEntry(key: id, value: open) in _screens.entries) {
    for (final MapEntry(key: sizeName, value: size) in _sizes.entries) {
      testWidgets('Latte $id at $sizeName', (tester) async {
        await open(tester, size);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/latte/$id-$sizeName.png'),
        );
      });
    }
  }
}
