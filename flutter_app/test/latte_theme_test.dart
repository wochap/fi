import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'batch_records_test.dart' show seeded;
import 'fake_bridge.dart';
import 'widget_test.dart' show app, pumpUntilFound;

const _mocha = NocturneColors.mocha;
const _latte = NocturneColors.latte;

/// Presents the platform as set to [brightness].
void platformBrightness(WidgetTester tester, Brightness brightness) {
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

/// Pumps [child] under the theme built from [colors].
Future<void> pumpThemed(
  WidgetTester tester,
  Widget child,
  NocturneColors colors,
) => tester.pumpWidget(
  MaterialApp(
    theme: nocturneTheme(colors),
    home: Scaffold(body: child),
  ),
);

FakeCollectionBridge _ready() => FakeCollectionBridge()
  ..bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// The active theme's color set, read below the app's theme.
NocturneColors _active(WidgetTester tester) =>
    tester.element(find.byType(Navigator).first).nocturne;

/// Colors Mocha has and Latte doesn't.
final Set<Color> _mochaOnly = {
  for (final c in [
    _mocha.bg,
    _mocha.surface,
    _mocha.text,
    _mocha.accent,
    _mocha.danger,
    _mocha.success,
    _mocha.warning,
    _mocha.section,
    _mocha.sectionGlow,
    _mocha.sectionGhost,
    _mocha.neutral100,
    _mocha.neutral200,
    _mocha.neutral300,
    _mocha.neutral400,
    _mocha.neutral500,
    _mocha.neutral600,
    _mocha.neutral700,
    _mocha.neutral800,
    _mocha.neutral900,
    _mocha.accent100,
    _mocha.accent200,
    _mocha.accent300,
    _mocha.accent400,
    _mocha.accent500,
    _mocha.accent600,
    _mocha.accent700,
    _mocha.accent800,
    _mocha.accent900,
  ])
    c,
}..removeWhere(_latteColors.contains);

final Set<Color> _latteColors = {
  _latte.bg,
  _latte.surface,
  _latte.text,
  _latte.accent,
  _latte.neutral100,
  _latte.neutral200,
  _latte.neutral300,
  _latte.neutral400,
  _latte.neutral500,
  _latte.neutral600,
  _latte.neutral700,
  _latte.neutral800,
  _latte.neutral900,
  _latte.accent100,
  _latte.accent200,
  _latte.accent300,
  _latte.accent400,
  _latte.accent500,
  _latte.accent600,
  _latte.accent700,
  _latte.accent800,
  _latte.accent900,
};

Iterable<Color?> _boxColors(Decoration? decoration) sync* {
  if (decoration is! BoxDecoration) return;
  yield decoration.color;
  if (decoration.border case final Border border) {
    yield border.top.color;
    yield border.bottom.color;
    yield border.left.color;
    yield border.right.color;
  }
}

/// Fails if any rendered text, icon, material or decoration uses a Mocha-only color.
void expectNoMochaColor(WidgetTester tester) {
  for (final element in tester.allElements) {
    final widget = element.widget;
    final colors = <Color?>[
      if (widget is Text) widget.style?.color,
      if (widget is RichText) widget.text.style?.color,
      if (widget is Icon) widget.color,
      if (widget is Material) widget.color,
      if (widget is DecoratedBox) ..._boxColors(widget.decoration),
      if (widget is Container) ..._boxColors(widget.decoration),
      if (widget is ColoredBox) widget.color,
    ];
    for (final color in colors.nonNulls) {
      expect(
        _mochaOnly.contains(color.withValues(alpha: 1)) && color.a == 1,
        isFalse,
        reason: '${widget.runtimeType} uses Mocha color $color on Latte',
      );
    }
  }
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => Intl.defaultLocale = null);

  group('theme follows the preference', () {
    testWidgets('System default follows a light and a dark platform', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.light);
      await tester.pumpWidget(app(_ready()));
      await pumpUntilFound(tester, find.text('Collections'));
      expect(_active(tester).bg, _latte.bg);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor ??
            Theme.of(
              tester.element(find.byType(Scaffold).first),
            ).scaffoldBackgroundColor,
        _latte.bg,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(_active(tester).bg, _mocha.bg);
    });

    testWidgets('Dark overrides a light platform', (tester) async {
      platformBrightness(tester, Brightness.light);
      await tester.pumpWidget(
        app(
          _ready(),
          uiPrefs: MemoryUiPrefsStore(
            const UiPrefs(appTheme: AppThemeMode.dark),
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Collections'));
      expect(_active(tester).bg, _mocha.bg);
    });

    testWidgets('a stored Light applies on the first frame without a fade', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      await tester.pumpWidget(
        app(
          _ready(),
          uiPrefs: MemoryUiPrefsStore(
            const UiPrefs(appTheme: AppThemeMode.light),
          ),
        ),
      );
      // The store answers in a microtask; the next frame has the choice.
      await tester.pump();
      expect(_active(tester).bg, _latte.bg);
      expect(_active(tester).brightness, Brightness.light);
      MaterialApp material() =>
          tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(material().themeAnimationDuration, Duration.zero);
      // Later switches animate again.
      await tester.pump();
      expect(material().themeAnimationDuration, kThemeAnimationDuration);
    });

    testWidgets('bar icons follow a manual Light on a dark platform', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      await tester.pumpWidget(
        app(
          _ready(),
          uiPrefs: MemoryUiPrefsStore(
            const UiPrefs(appTheme: AppThemeMode.light),
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Collections'));
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
      );
      expect(region.value.statusBarIconBrightness, Brightness.dark);
      expect(region.value.systemNavigationBarIconBrightness, Brightness.dark);
      expect(region.value.statusBarColor, isNull);
      expect(region.value.systemNavigationBarColor, isNull);
    });
  });

  group('Settings › Appearance', () {
    Future<void> openSettings(
      WidgetTester tester, {
      required PlatformCapabilities capabilities,
      required Size size,
      UiPrefsStore? prefs,
      VoiceServices? voice,
    }) async {
      _size(tester, size);
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

    double top(WidgetTester tester, Finder finder) =>
        tester.getTopLeft(finder).dy;

    testWidgets('desktop: order, copy and dropdown entries', (tester) async {
      platformBrightness(tester, Brightness.dark);
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.desktop,
        size: const Size(1240, 1000),
        voice: fakeVoiceServices(),
      );
      final language = top(tester, find.byKey(const Key('settings-language')));
      final appearance = top(
        tester,
        find.byKey(const Key('settings-appearance')),
      );
      final about = top(tester, find.byKey(const Key('settings-about')));
      expect(language, lessThan(appearance));
      expect(appearance, lessThan(about));
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Light or dark. Changes apply right away.'), findsOne);
      expect(find.text('System default (Dark)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-theme-dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('System default (Dark)'), findsWidgets);
      expect(find.text('Light'), findsWidgets);
      expect(find.text('Dark'), findsWidgets);
    });

    testWidgets('Android order with and without voice', (tester) async {
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 2400),
        voice: fakeVoiceServices(),
      );
      final tops = [
        for (final label in [
          'LANGUAGE',
          'APPEARANCE',
          'VOICE INPUT',
          'MICROPHONE',
          'ABOUT',
        ])
          top(tester, find.text(label)),
      ];
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i - 1], lessThan(tops[i]));
      }
    });

    testWidgets('Android without voice: Language, Appearance, About', (
      tester,
    ) async {
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 2400),
      );
      expect(find.text('VOICE INPUT'), findsNothing);
      expect(
        top(tester, find.text('APPEARANCE')),
        lessThan(top(tester, find.text('ABOUT'))),
      );
    });

    testWidgets('Android radio copy on a light phone', (tester) async {
      platformBrightness(tester, Brightness.light);
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 1400),
      );
      final section = find.byKey(const Key('settings-appearance'));
      Finder inSection(String text) =>
          find.descendant(of: section, matching: find.text(text));
      expect(inSection('System default'), findsOneWidget);
      expect(inSection('Light — same as your phone'), findsOneWidget);
      expect(inSection('Light'), findsOneWidget);
      expect(inSection('Dark'), findsOneWidget);
      final group = tester.widget<RadioGroup<AppThemeMode>>(
        find.descendant(
          of: section,
          matching: find.byType(RadioGroup<AppThemeMode>),
        ),
      );
      expect(group.groupValue, AppThemeMode.system);
    });

    testWidgets('Android radio copy in Spanish on a dark phone', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      _size(tester, const Size(390, 1400));
      await tester.pumpWidget(
        app(
          _ready(),
          capabilities: PlatformCapabilities.androidPhone,
          uiPrefs: MemoryUiPrefsStore(
            const UiPrefs(appLanguage: AppLanguage.spanish),
          ),
        ),
      );
      await pumpUntilFound(tester, find.text('Colecciones'));
      await tester.tap(find.text('Ajustes'));
      await tester.pumpAndSettle();
      final section = find.byKey(const Key('settings-appearance'));
      Finder inSection(String text) =>
          find.descendant(of: section, matching: find.text(text));
      expect(find.text('APARIENCIA'), findsOneWidget);
      expect(inSection('Predeterminado del sistema'), findsOneWidget);
      expect(inSection('Oscuro — igual que tu teléfono'), findsOneWidget);
      expect(inSection('Claro'), findsOneWidget);
      expect(inSection('Oscuro'), findsOneWidget);
    });

    testWidgets('picking Light applies at once and survives a restart', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      final prefs = MemoryUiPrefsStore();
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 1400),
        prefs: prefs,
      );
      expect(_active(tester).bg, _mocha.bg);
      await tester.tap(find.byKey(const Key('theme-option-light')));
      await tester.pumpAndSettle();
      expect(_active(tester).bg, _latte.bg);
      expect(find.byKey(const Key('settings-appearance')), findsOneWidget);
      expect(prefs.prefs.appTheme, AppThemeMode.light);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(_ready(), uiPrefs: prefs));
      await pumpUntilFound(tester, find.text('Collections'));
      expect(_active(tester).bg, _latte.bg);
    });

    testWidgets('System default label follows a platform change', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.desktop,
        size: const Size(1240, 1000),
      );
      expect(find.text('System default (Dark)'), findsOneWidget);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(find.text('System default (Light)'), findsOneWidget);
      expect(_active(tester).bg, _latte.bg);
    });

    testWidgets('the Ready tag on Latte: success icon, text label', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.light);
      await openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 1400),
        voice: fakeVoiceServices(
          models: FakeVoiceModels(modelStatusOf(ModelStatusKindDto.ready)),
        ),
      );
      final tag = find.byKey(const Key('settings-model-tag'));
      final label = tester
          .widget<Text>(find.descendant(of: tag, matching: find.text('Ready')))
          .style!
          .color;
      final icon = tester
          .widget<Icon>(find.descendant(of: tag, matching: find.byType(Icon)))
          .color;
      expect(label, _latte.text);
      expect(icon, _latte.success);
    });
  });

  group('screens under both themes', () {
    for (final (name, brightness, colors) in [
      ('Latte', Brightness.light, _latte),
      ('Mocha', Brightness.dark, _mocha),
    ]) {
      testWidgets('$name: collections, records, a record form, Devices and '
          'Settings', (tester) async {
        platformBrightness(tester, brightness);
        _size(tester, const Size(390, 844));
        await tester.pumpWidget(app(seeded(3)));
        await pumpUntilFound(tester, find.text('Headaches'));
        void check() {
          expect(tester.takeException(), isNull);
          expect(
            Theme.of(
              tester.element(find.byType(Scaffold).last),
            ).scaffoldBackgroundColor,
            colors.bg,
          );
          if (colors == _latte) expectNoMochaColor(tester);
        }

        check();
        await tester.tap(find.text('Headaches'));
        await tester.pumpAndSettle();
        check();
        await tester.tap(find.byTooltip('New record').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save record'));
        await tester.pumpAndSettle();
        check();
        for (var i = 0; i < 2; i++) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        await _openTab(tester, 'Devices');
        check();
        await _openTab(tester, 'Settings');
        check();
      });
    }

    testWidgets('typed text in a New record form survives a theme switch', (
      tester,
    ) async {
      platformBrightness(tester, Brightness.dark);
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(app(seeded(1)));
      await pumpUntilFound(tester, find.text('Headaches'));
      await tester.tap(find.text('Headaches'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New record').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).first, 'kept draft');
      await tester.pump();

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(_active(tester).bg, _latte.bg);
      expect(find.text('kept draft'), findsOneWidget);
    });
  });

  testWidgets('pumpThemed gives the subtree the color set', (tester) async {
    late NocturneColors seen;
    await pumpThemed(
      tester,
      Builder(
        builder: (context) {
          seen = context.nocturne;
          return const SizedBox();
        },
      ),
      _latte,
    );
    expect(seen, _latte);
  });
}
