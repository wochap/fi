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

  group('voice input line', () {
    FakeVoiceModels spanishMissing(FakeVoiceModels models) =>
        models
          ..statusByLanguage['es'] = modelStatusOf(
            ModelStatusKindDto.notDownloaded,
            language: 'es',
            readyFiles: {'qwen2.5-1.5b-instruct-q5_k_m.gguf'},
          );

    Future<void> chooseSpanish(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('language-option-es')));
      await tester.pumpAndSettle();
    }

    testWidgets('says the English models are ready', (tester) async {
      await _openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 2400),
        voice: fakeVoiceServices(),
      );
      expect(
        find.text(
          'Voice input follows the app language · English models ready',
        ),
        findsOneWidget,
      );
    });

    testWidgets('choosing Español offers the Spanish speech model', (
      tester,
    ) async {
      final models = spanishMissing(FakeVoiceModels());
      await _openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 2400),
        voice: fakeVoiceServices(models: models),
      );
      await chooseSpanish(tester);
      expect(find.byKey(const Key('language-voice-offer')), findsOneWidget);
      expect(
        find.text('Descargar modelo de voz en español · 148 MB'),
        findsOneWidget,
      );
      expect(
        find.text(
          'La entrada de voz sigue el idioma de la app. '
          'El modelo de comprensión (1,29 GB) ya está en este teléfono.',
        ),
        findsOneWidget,
      );
      expect(models.calls, contains('language:es'));

      await tester.tap(find.byKey(const Key('language-voice-offer-download')));
      await tester.pumpAndSettle();
      expect(models.calls, contains('start'));
    });

    testWidgets('Ahora no hides the offer', (tester) async {
      final models = spanishMissing(FakeVoiceModels());
      await _openSettings(
        tester,
        capabilities: PlatformCapabilities.androidPhone,
        size: const Size(390, 2400),
        voice: fakeVoiceServices(models: models),
      );
      await chooseSpanish(tester);
      await tester.tap(find.byKey(const Key('language-voice-offer-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('language-voice-offer')), findsNothing);
      expect(
        find.text('La entrada de voz sigue el idioma de la app'),
        findsOneWidget,
      );
      expect(find.text('Ajustes'), findsWidgets);
      expect(models.calls, isNot(contains('start')));
    });

    testWidgets('desktop shows no voice line', (tester) async {
      await _openSettings(
        tester,
        capabilities: PlatformCapabilities.desktop,
        size: const Size(1240, 900),
        voice: fakeVoiceServices(),
      );
      expect(find.byKey(const Key('language-voice-line')), findsNothing);
    });
  });

  testWidgets('deleting another language asks with its name and size', (
    tester,
  ) async {
    const english = ModelFileDto(
      name: 'ggml-base.en.bin',
      label: 'Whisper Base (English)',
      role: ModelRoleDto.speech,
      language: 'en',
      sizeBytes: 147964211,
      storedBytes: 147964211,
      state: ModelFileStateDto.ready,
    );
    final spanishReady = modelStatusOf(
      ModelStatusKindDto.ready,
      language: 'es',
      otherSpeech: const [english],
    );
    final models = FakeVoiceModels(spanishReady)
      ..statusByLanguage['en'] = spanishReady;
    await _openSettings(
      tester,
      capabilities: PlatformCapabilities.androidPhone,
      size: const Size(390, 2400),
      voice: fakeVoiceServices(models: models),
    );
    final delete = find.byKey(const Key('settings-model-delete-speech-en'));
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete this speech model?'), findsOneWidget);
    expect(
      find.text(
        "Frees 148 MB. English voice input won't work until you download it again.",
      ),
      findsOneWidget,
    );
    expect(find.text('Keep model'), findsOneWidget);
  });
}
