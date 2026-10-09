import 'dart:convert';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/controller.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'fake_bridge.dart';
import 'voice_fixtures.dart';
import 'widget_test.dart';

const _phone = Size(390, 844);
const _desktop = Size(1240, 900);

FieldDefinitionDto _field(
  String id,
  FieldTypeKindDto kind, {
  String? name,
  bool required = false,
  int order = 0,
  int? scale,
  List<EnumOptionDto> options = const [],
}) => FieldDefinitionDto(
  id: id,
  name: name ?? id,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(multiline: false, slider: false),
  order: order,
  deleted: false,
  enumOptions: options,
);

FakeCollectionBridge _expenses({List<RecordDto> records = const []}) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: 'expenses',
      name: 'expenses',
      description: '',
      recordCount: 0,
      fieldCount: 4,
      incompleteCount: 0,
    ),
  );
  bridge.schemas['expenses'] = CollectionSchemaDto(
    id: 'expenses',
    name: 'expenses',
    description: '',
    fields: [
      _field('description', FieldTypeKindDto.text),
      _field(
        'amount',
        FieldTypeKindDto.fixedDecimal,
        required: true,
        order: 1,
        scale: 2,
      ),
      _field(
        'category',
        FieldTypeKindDto.enum_,
        required: true,
        order: 2,
        options: const [
          EnumOptionDto(id: 'food', label: 'Food', order: 0, deleted: false),
          EnumOptionDto(
            id: 'transport',
            label: 'Transport',
            order: 1,
            deleted: false,
          ),
        ],
      ),
      _field('date', FieldTypeKindDto.date, order: 3),
    ],
  );
  bridge.records['expenses'] = [...records];
  return bridge;
}

/// The expenses collection named in Spanish ("gastos").
FakeCollectionBridge _gastos() {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: 'gastos',
      name: 'gastos',
      description: '',
      recordCount: 0,
      fieldCount: 4,
      incompleteCount: 0,
    ),
  );
  EnumOptionDto option(String label, int order) =>
      EnumOptionDto(id: label, label: label, order: order, deleted: false);
  bridge.schemas['gastos'] = CollectionSchemaDto(
    id: 'gastos',
    name: 'gastos',
    description: '',
    fields: [
      _field('description', FieldTypeKindDto.text, name: 'descripción'),
      _field(
        'amount',
        FieldTypeKindDto.fixedDecimal,
        name: 'importe',
        required: true,
        order: 1,
        scale: 2,
      ),
      _field(
        'category',
        FieldTypeKindDto.enum_,
        name: 'categoría',
        required: true,
        order: 2,
        options: [
          option('comida', 0),
          option('transporte', 1),
          option('hogar', 2),
          option('otro', 3),
        ],
      ),
      _field('date', FieldTypeKindDto.date, name: 'fecha', order: 3),
    ],
  );
  bridge.records['gastos'] = [];
  return bridge;
}

/// Opens Nuevo registro in "gastos" with the app in Spanish.
Future<void> _openSpanishNewRecord(
  WidgetTester tester,
  _Harness harness,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _phone;
  addTearDown(tester.view.reset);
  await harness.prefs.update(
    (prefs) => prefs.copyWith(appLanguage: AppLanguage.spanish),
  );
  await tester.pumpWidget(
    app(_gastos(), voice: harness.services, uiPrefs: harness.prefs),
  );
  await pumpUntilFound(tester, find.text('gastos'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('gastos').first);
  await tester.pumpAndSettle();
  final tip = find.byTooltip('Nuevo registro');
  await tester.tap(
    tip.evaluate().isNotEmpty ? tip.first : find.text('Nuevo registro').first,
  );
  await tester.pumpAndSettle();
}

final class _Harness {
  _Harness({
    List<FakeVoiceTurn>? script,
    VoiceEngine? engine,
    ModelStatusDto? status,
    MicPermission permission = MicPermission.granted,
    NetworkKind network = NetworkKind.wifi,
    bool tipDismissed = true,
    bool handsFree = false,
    FakeSpeechOutput? speech,
  }) : prefs = MemoryUiPrefsStore(
         UiPrefs(voiceTipDismissed: tipDismissed, handsFree: handsFree),
       ),
       models = FakeVoiceModels(status),
       permission = FakeMicrophonePermission(permission),
       speech = speech ?? FakeSpeechOutput(instant: true) {
    services = fakeVoiceServices(
      engine:
          engine ?? quickEngine(script ?? [FakeVoiceTurn.result(lunchResult)]),
      models: models,
      permission: this.permission,
      network: FakeNetworkInfo(network),
      speech: this.speech,
      prefs: prefs,
    );
  }

  final MemoryUiPrefsStore prefs;
  final FakeVoiceModels models;
  final FakeMicrophonePermission permission;
  final FakeSpeechOutput speech;
  late final VoiceServices services;
  final bridge = _expenses();
}

Future<void> _openNewRecord(
  WidgetTester tester,
  _Harness harness, {
  Size size = _phone,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(harness.bridge, voice: harness.services, uiPrefs: harness.prefs),
  );
  await pumpUntilFound(tester, find.text('expenses'));
  await tester.tap(find.text('expenses').first);
  await tester.pumpAndSettle();
  final tip = find.byTooltip('New record');
  await tester.tap(
    tip.evaluate().isNotEmpty ? tip.first : find.text('New record').first,
  );
  await tester.pumpAndSettle();
}

Finder _mic() => find.byKey(const Key('voice-mic'));

String? _micLabel(WidgetTester tester) => tester
    .widget<VoiceMicButton>(find.byType(VoiceMicButton))
    .labelOf(lookupAppLocalizations(const Locale('en')));

FilledButton _save(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(
    of: find.text('Save record'),
    matching: find.byType(FilledButton),
  ),
);

/// Taps the mic twice: listen, then stop and process, letting the fake engine finish.
Future<void> _speak(WidgetTester tester) async {
  await tester.tap(_mic());
  await tester.pump();
  await tester.tap(_mic());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _inRow(String field, Finder finder) => find.descendant(
  of: find.byKey(ValueKey('record-field-$field')),
  matching: finder,
);

void main() {
  group('mic button', () {
    for (final (state, label) in [
      (MicState.idle, 'Fill by voice'),
      (MicState.ready, 'Answer by voice'),
      (MicState.listening, 'Stop listening'),
      (MicState.processing, 'Processing speech'),
      (MicState.downloading, 'Voice model downloading, 38 percent'),
    ]) {
      testWidgets('${state.name} reads "$label"', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoiceMicButton(state: state, percent: 38, onTap: () {}),
            ),
          ),
        );
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(
          tester.getSize(find.byType(VoiceMicButton)),
          const Size.square(56),
        );
      });
    }

    testWidgets('sits beside Save record in a phone New record sheet', (
      tester,
    ) async {
      await _openNewRecord(tester, _Harness());
      expect(_mic(), findsOneWidget);
      expect(_micLabel(tester), 'Fill by voice');
      expect(
        tester.getCenter(_mic()).dy,
        moreOrLessEquals(
          tester.getCenter(find.text('Save record')).dy,
          epsilon: 1,
        ),
      );
      expect(
        tester.getTopLeft(_mic()).dx,
        lessThan(tester.getTopLeft(find.text('Save record')).dx),
      );
    });

    testWidgets('is absent on desktop', (tester) async {
      await _openNewRecord(tester, _Harness(), size: _desktop);
      expect(_mic(), findsNothing);
      expect(find.byKey(const Key('voice-panel')), findsNothing);
    });

    testWidgets('is absent without an engine', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(engine: const UnavailableVoiceEngine(), tipDismissed: false),
      );
      expect(_mic(), findsNothing);
      expect(find.byKey(const Key('voice-tip')), findsNothing);
    });

    testWidgets('is absent in Edit record', (tester) async {
      final harness = _Harness();
      harness.bridge.records['expenses'] = [
        RecordDto(
          id: 'r1',
          collectionId: 'expenses',
          values: [
            RecordValueDto(fieldId: 'description', value: text('Coffee')),
          ],
          valid: true,
          diagnostics: const [],
          createdAtMs: 0,
        ),
      ];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = _phone;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(harness.bridge, voice: harness.services, uiPrefs: harness.prefs),
      );
      await pumpUntilFound(tester, find.text('expenses'));
      await tester.tap(find.text('expenses').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coffee').first);
      await tester.pumpAndSettle();
      expect(find.text('Edit record'), findsOneWidget);
      expect(_mic(), findsNothing);
    });
  });

  group('first use', () {
    testWidgets('the tip shows once and stays dismissed', (tester) async {
      final harness = _Harness(tipDismissed: false);
      await _openNewRecord(tester, harness);
      expect(find.text('Fill by voice'), findsOneWidget);
      expect(
        find.text(
          'Tap the mic below and say the details. You review before saving.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-tip-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-tip')), findsNothing);
      expect(harness.prefs.prefs.voiceTipDismissed, isTrue);
    });

    testWidgets('primer then permission request; Not now asks nothing', (
      tester,
    ) async {
      final harness = _Harness(permission: MicPermission.notGranted);
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      expect(find.text('Speak to fill records'), findsOneWidget);
      expect(
        find.text('Audio is processed on this device and never saved.'),
        findsOneWidget,
      );
      expect(
        find.text('Next, Android will ask for microphone access.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-primer-not-now')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-primer')), findsNothing);
      expect(harness.permission.requests, 0);
      expect(_micLabel(tester), 'Fill by voice');

      await tester.tap(_mic());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-primer-continue')));
      await tester.pump();
      expect(harness.permission.requests, 1);
      expect(find.byKey(const Key('voice-listening')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('the download offer shows size, network and storage', (
      tester,
    ) async {
      final harness = _Harness(
        status: modelStatusOf(ModelStatusKindDto.notDownloaded),
        network: NetworkKind.mobile,
      )..models.freeBytes = 12400000000;
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      expect(find.text('Download voice models'), findsOneWidget);
      expect(
        find.text(
          'English · 1.43 GB total, one time. Everything runs on this phone.',
        ),
        findsOneWidget,
      );
      for (final (name, texts) in [
        (
          'ggml-base.en.bin',
          ['Speech recognition', 'Whisper Base (English)', '148 MB'],
        ),
        (
          'qwen2.5-1.5b-instruct-q5_k_m.gguf',
          ['Understanding', 'Qwen2.5 1.5B Instruct', '1.29 GB'],
        ),
      ]) {
        for (final text in texts) {
          expect(
            find.descendant(
              of: find.byKey(Key('voice-offer-model-$name')),
              matching: find.text(text),
            ),
            findsOneWidget,
          );
        }
      }
      expect(find.text('Download 1.43 GB'), findsOneWidget);
      expect(find.text("You're on mobile data"), findsOneWidget);
      expect(find.text('Wi-Fi recommended'), findsOneWidget);
      expect(find.text('12.4 GB free'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-offer-later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-offer')), findsNothing);
      expect(harness.models.calls, isEmpty);
    });

    testWidgets('downloading keeps the form editable and rings the mic', (
      tester,
    ) async {
      final harness = _Harness(
        status: modelStatusOf(ModelStatusKindDto.notDownloaded),
      );
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pump();
      expect(harness.models.calls, ['start']);
      harness.models.status = modelStatusOf(
        ModelStatusKindDto.downloading,
        done: 612000000,
        secondsLeft: 240,
      );
      await tester.pump();
      expect(find.text('Downloading voice models'), findsOneWidget);
      expect(find.text('612 MB of 1.43 GB · 42%'), findsOneWidget);
      expect(find.text('about 4 min left'), findsOneWidget);
      expect(
        find.text("Keep filling by hand. The mic turns on when it's ready."),
        findsOneWidget,
      );
      expect(_micLabel(tester), 'Voice model downloading, 42 percent');
      await tester.enterText(
        _inRow('description', find.byType(TextField)),
        'Lunch',
      );
      await tester.pump();
      expect(find.text('Lunch'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-download-pause')));
      await tester.pump();
      expect(harness.models.calls.last, 'pause');
      await tester.tap(find.byKey(const Key('voice-download-hide')));
      await tester.pump();
      expect(find.byKey(const Key('voice-downloading')), findsNothing);

      harness.models.status = modelStatusOf(ModelStatusKindDto.ready);
      await tester.pump();
      expect(_micLabel(tester), 'Fill by voice');
    });

    testWidgets('reconnecting keeps the card and the mic ring', (tester) async {
      final harness = _Harness(
        status: modelStatusOf(ModelStatusKindDto.notDownloaded),
      );
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pump();
      harness.models.status = modelStatusOf(
        ModelStatusKindDto.reconnecting,
        done: 612000000,
      );
      await tester.pump();
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(
        find.text('Connection lost — the download resumes where it stopped.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('voice-download-pause')), findsOneWidget);
      expect(_micLabel(tester), 'Voice model downloading, 42 percent');
    });

    Future<_Harness> openDownload(WidgetTester tester) async {
      final harness = _Harness(
        status: modelStatusOf(ModelStatusKindDto.notDownloaded),
      );
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pump();
      return harness;
    }

    testWidgets('paused shows what is kept and a Resume button', (
      tester,
    ) async {
      final harness = await openDownload(tester);
      harness.models.status = modelStatusOf(
        ModelStatusKindDto.paused,
        done: 612000000,
        secondsLeft: 240,
      );
      await tester.pump();
      expect(find.text('Download paused'), findsOneWidget);
      expect(find.text('612 MB of 1.43 GB kept'), findsOneWidget);
      expect(find.text('about 4 min left'), findsNothing);
      expect(find.byKey(const Key('voice-download-pause')), findsNothing);
      harness.models.calls.clear();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Resume'));
      await tester.pump();
      expect(harness.models.calls, ['start']);
    });

    testWidgets('failed shows the reason and Retry resumes', (tester) async {
      final harness = await openDownload(tester);
      harness.models.status = modelStatusOf(
        ModelStatusKindDto.failed,
        done: 612000000,
        error: const ModelErrorDto(
          kind: ModelErrorKindDto.network,
          message: 'network error',
        ),
      );
      await tester.pump();
      expect(find.text('Download failed'), findsOneWidget);
      expect(
        find.text(
          "Couldn't reach the download server. Check your Wi-Fi, then retry. "
          'Downloaded data is kept.',
        ),
        findsOneWidget,
      );
      expect(find.text('612 MB of 1.43 GB kept'), findsOneWidget);
      harness.models.calls.clear();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      expect(harness.models.calls, ['start']);
      expect(harness.models.status.doneBytes, 612000000);
    });
  });

  group('turn panels', () {
    testWidgets('listening then processing; Save waits', (tester) async {
      final engine = FakeVoiceEngine(
        script: [FakeVoiceTurn.result(lunchResult)],
        transcribeDelay: const Duration(milliseconds: 400),
        fillDelay: const Duration(milliseconds: 800),
        levelInterval: const Duration(milliseconds: 50),
      );
      await _openNewRecord(tester, _Harness(engine: engine));
      await tester.tap(_mic());
      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('Listening'), findsOneWidget);
      expect(find.byKey(const Key('voice-timer')), findsOneWidget);
      expect(find.text('Stops on its own after 30 seconds.'), findsOneWidget);
      expect(find.text('0:01'), findsOneWidget);
      expect(
        find.textContaining('Lunch, 12.50, category food, yesterday'),
        findsOneWidget,
      );
      expect(
        find.text('Tap stop when done, or hold the mic to talk'),
        findsOneWidget,
      );
      expect(_micLabel(tester), 'Stop listening');
      expect(_save(tester).onPressed, isNull);

      await tester.tap(_mic());
      await tester.pump();
      expect(find.text('Transcribing…'), findsOneWidget);
      expect(_micLabel(tester), 'Processing speech');
      expect(_save(tester).onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('Transcribed'), findsOneWidget);
      expect(find.text('Filling fields…'), findsOneWidget);
      expect(find.text('“$lunchTranscript”'), findsOneWidget);
      expect(find.text('Usually 4–8 seconds'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('Filled 4 fields'), findsOneWidget);
      expect(_save(tester).onPressed, isNotNull);
    });

    testWidgets('Cancel mid-processing leaves the form as it was', (
      tester,
    ) async {
      final engine = FakeVoiceEngine(
        script: [FakeVoiceTurn.result(lunchResult)],
        transcribeDelay: const Duration(milliseconds: 100),
        fillDelay: const Duration(milliseconds: 800),
      );
      final harness = _Harness(engine: engine);
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pump();
      await tester.tap(_mic());
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('voice-cancel')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('voice-processing')), findsNothing);
      expect(find.byKey(const Key('voice-chip-amount')), findsNothing);
      expect(_save(tester).onPressed, isNotNull);
      expect(harness.models.turnActive, isFalse);
    });

    testWidgets('filled: Voice chips, tint, Heard and the evidence popover', (
      tester,
    ) async {
      await _openNewRecord(
        tester,
        _Harness(script: [FakeVoiceTurn.result(lunchResult)]),
      );
      await _speak(tester);
      expect(find.text('Filled 4 fields'), findsOneWidget);
      expect(find.text('Check the fields, then save.'), findsOneWidget);
      expect(find.byKey(const Key('voice-speak-again')), findsOneWidget);
      for (final field in ['description', 'amount', 'category', 'date']) {
        expect(find.byKey(Key('voice-chip-$field')), findsOneWidget);
        expect(find.byKey(Key('voice-mark-$field')), findsOneWidget);
      }
      expect(find.text('12.50'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-heard')));
      await tester.pump();
      expect(find.textContaining(lunchTranscript), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-chip-amount')));
      await tester.pump();
      expect(find.byKey(const Key('voice-evidence-amount')), findsOneWidget);
      final evidence = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('voice-evidence-text')),
          matching: find.byType(RichText),
        ),
      );
      final spans = (evidence.text as TextSpan).children!.first as TextSpan;
      final highlighted = spans.children!.whereType<TextSpan>().firstWhere(
        (span) => span.style?.backgroundColor != null,
      );
      expect(highlighted.text, 'twelve fifty');
      expect(find.text('Clear field'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-evidence-clear')));
      await tester.pump();
      expect(find.byKey(const Key('voice-chip-amount')), findsNothing);
      expect(find.text('12.50'), findsNothing);
    });

    testWidgets('typing removes the Voice marker', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(script: [FakeVoiceTurn.result(lunchResult)]),
      );
      await _speak(tester);
      await tester.enterText(
        _inRow('description', find.byType(TextField)),
        'Dinner',
      );
      await tester.pump();
      expect(find.byKey(const Key('voice-chip-description')), findsNothing);
      expect(find.byKey(const Key('voice-mark-description')), findsNothing);
    });

    testWidgets('need, answer, follow-up with the kept edit', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [
            FakeVoiceTurn.result(taxiResult),
            FakeVoiceTurn.result(
              VoiceTurnResult(
                transcript: 'Twenty two forty, transport, Taxi home',
                patch: [
                  ...answerResult.patch,
                  entry('description', text('Taxi home'), 'Taxi home'),
                ],
              ),
            ),
          ],
        ),
      );
      await _speak(tester);
      expect(find.text('Still need: amount, category'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      expect(
        find.text(
          'Filled 2 fields. Say the rest, or type into the marked fields.',
        ),
        findsOneWidget,
      );
      expect(find.text('Answer by voice'), findsOneWidget);
      expect(_micLabel(tester), 'Answer by voice');
      expect(find.byKey(const Key('needed-marker-amount')), findsOneWidget);
      expect(find.byKey(const Key('voice-mark-category')), findsOneWidget);

      await tester.enterText(
        _inRow('description', find.byType(TextField)),
        'Taxi home from airport',
      );
      await tester.pump();
      await _speak(tester);
      expect(find.text('Updated amount, category'), findsOneWidget);
      expect(find.text('Your edit to description was kept.'), findsOneWidget);
      expect(find.text('Taxi home from airport'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-heard')));
      await tester.pump();
      expect(find.textContaining('1ST'), findsOneWidget);
      expect(find.textContaining('2ND'), findsOneWidget);
      expect(find.byKey(const Key('needed-marker-amount')), findsNothing);
    });

    testWidgets('after two rounds the panel stops asking', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [
            FakeVoiceTurn.result(taxiResult),
            FakeVoiceTurn.result(categoryOnlyResult),
            FakeVoiceTurn.result(categoryOnlyResult),
          ],
        ),
      );
      await _speak(tester);
      await _speak(tester);
      expect(find.text('2 of 2'), findsOneWidget);
      await _speak(tester);
      expect(find.text("Couldn't get the amount"), findsOneWidget);
      expect(
        find.text(
          'Type it in the marked field, then save. The mic still works if you want to try again.',
        ),
        findsOneWidget,
      );
      expect(_micLabel(tester), 'Fill by voice');
      expect(find.byKey(const Key('needed-marker-amount')), findsOneWidget);
    });

    testWidgets('never saves by itself', (tester) async {
      final harness = _Harness(script: [FakeVoiceTurn.result(lunchResult)]);
      await _openNewRecord(tester, harness);
      await _speak(tester);
      expect(harness.bridge.records['expenses'], isEmpty);
      await tester.tap(find.text('Save record'));
      await tester.pumpAndSettle();
      expect(harness.bridge.records['expenses'], hasLength(1));
    });
  });

  group('closing', () {
    Future<void> startProcessing(WidgetTester tester, _Harness harness) async {
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pump();
      await tester.tap(_mic());
      await tester.pump(const Duration(milliseconds: 50));
    }

    _Harness slow() => _Harness(
      engine: FakeVoiceEngine(
        script: [FakeVoiceTurn.result(lunchResult)],
        transcribeDelay: const Duration(milliseconds: 300),
        fillDelay: const Duration(seconds: 2),
      ),
    );

    testWidgets('Keep editing returns to the running turn', (tester) async {
      await startProcessing(tester, slow());
      await tester.tap(find.byKey(const Key('form-close')));
      await tester.pump();
      expect(find.text('Discard this record?'), findsOneWidget);
      expect(
        find.text(
          'Voice processing will stop and the fields you changed will be lost.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-keep-editing')));
      await tester.pump();
      expect(find.byKey(const Key('voice-processing')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Filled 4 fields'), findsOneWidget);
    });

    testWidgets('Discard stops the turn and closes', (tester) async {
      final harness = slow();
      await startProcessing(tester, harness);
      await tester.tap(find.byKey(const Key('form-close')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-discard')));
      await tester.pumpAndSettle();
      expect(find.text('New record'), findsNothing);
      expect(harness.models.turnActive, isFalse);
    });

    testWidgets('an untouched sheet closes without asking', (tester) async {
      await _openNewRecord(tester, _Harness());
      await tester.tap(find.byKey(const Key('form-close')));
      await tester.pumpAndSettle();
      expect(find.text('Discard this record?'), findsNothing);
      expect(find.byKey(const Key('voice-mic')), findsNothing);
    });
  });

  group('error panels', () {
    for (final (kind, title, action) in [
      (VoiceFailureKind.noSpeech, "Didn't hear anything", 'Try again'),
      (VoiceFailureKind.micBusy, 'Microphone is busy', 'Try again'),
      (VoiceFailureKind.modelLoadFailed, "Voice model couldn't load", 'Retry'),
      (VoiceFailureKind.lowMemory, 'Not enough memory', 'Try again'),
      (VoiceFailureKind.interruptedCall, 'Stopped for a call', 'Speak again'),
    ]) {
      testWidgets('${kind.name} shows "$title" and keeps the form', (
        tester,
      ) async {
        await _openNewRecord(
          tester,
          _Harness(script: [FakeVoiceTurn.failure(kind)]),
        );
        await tester.enterText(
          _inRow('description', find.byType(TextField)),
          'Kept',
        );
        await tester.pump();
        await _speak(tester);
        expect(find.byKey(Key('voice-error-${kind.name}')), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        expect(find.text(action), findsOneWidget);
        expect(find.text('Kept'), findsOneWidget);
        final semantics = tester.getSemantics(find.text(title));
        expect(
          semantics.flagsCollection.isLiveRegion ||
              tester
                  .getSemantics(
                    find
                        .ancestor(
                          of: find.text(title),
                          matching: find.byType(Semantics),
                        )
                        .first,
                  )
                  .flagsCollection
                  .isLiveRegion,
          isTrue,
        );
      });
    }

    testWidgets('nothing matched offers Try again', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [
            const FakeVoiceTurn.result(
              VoiceTurnResult(transcript: 'hello there', patch: []),
            ),
          ],
        ),
      );
      await _speak(tester);
      expect(find.text('Nothing matched'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byKey(const Key('voice-error-heard')), findsOneWidget);
      expect(find.text('“hello there”'), findsOneWidget);
    });

    testWidgets('nothing matched shows what was heard and keeps the form', (
      tester,
    ) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [const FakeVoiceTurn.nothingMatched('a mount twelve fifty')],
        ),
      );
      await tester.enterText(
        _inRow('description', find.byType(TextField)),
        'Kept',
      );
      await tester.pump();
      await _speak(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Nothing matched'), findsOneWidget);
      expect(find.text('HEARD'), findsOneWidget);
      expect(find.text('“a mount twelve fifty”'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Kept'), findsOneWidget);
    });

    testWidgets('nothing matched without a transcript has no Heard block', (
      tester,
    ) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [
            const FakeVoiceTurn.failure(VoiceFailureKind.nothingMatched),
          ],
        ),
      );
      await _speak(tester);
      expect(find.text('Nothing matched'), findsOneWidget);
      expect(find.byKey(const Key('voice-error-heard')), findsNothing);
    });

    testWidgets('Try again listens again', (tester) async {
      await _openNewRecord(
        tester,
        _Harness(
          script: [
            const FakeVoiceTurn.failure(VoiceFailureKind.noSpeech),
            FakeVoiceTurn.result(lunchResult),
          ],
        ),
      );
      await _speak(tester);
      await tester.tap(find.byKey(const Key('voice-error-retry')));
      await tester.pump();
      expect(find.text('Listening'), findsOneWidget);
      await tester.tap(_mic());
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Filled 4 fields'), findsOneWidget);
    });

    testWidgets('permission off opens the app settings page', (tester) async {
      final harness = _Harness(permission: MicPermission.permanentlyDenied);
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      expect(find.text('Microphone access is off'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-error-open-settings')));
      await tester.pump();
      expect(harness.permission.settingsOpened, 1);
    });

    testWidgets('going to the background stops recording', (tester) async {
      final harness = _Harness(script: [FakeVoiceTurn.result(lunchResult)]);
      await _openNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Recording stopped'), findsOneWidget);
      expect(
        find.text(
          'Fi went to the background, so recording stopped. Nothing was kept.',
        ),
        findsOneWidget,
      );
      expect(find.text('Speak again'), findsOneWidget);
      expect(harness.models.turnActive, isFalse);
    });
  });

  group('hands-free', () {
    testWidgets('speaks the confirmation; mute turns the switch off', (
      tester,
    ) async {
      final speech = FakeSpeechOutput();
      final harness = _Harness(
        script: [FakeVoiceTurn.result(lunchResult)],
        handsFree: true,
        speech: speech,
      );
      await _openNewRecord(tester, harness);
      await _speak(tester);
      expect(speech.spoken, ['4 fields filled. Tap Save record when ready.']);
      expect(find.text('Speaking'), findsOneWidget);
      expect(
        find.text('4 fields filled. Tap Save record when ready.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-mute')));
      await tester.pump();
      expect(speech.stops, 1);
      expect(harness.prefs.prefs.handsFree, isFalse);
      expect(find.text('Filled 4 fields'), findsOneWidget);
    });

    testWidgets('speaks the still-need question', (tester) async {
      final speech = FakeSpeechOutput(instant: true);
      await _openNewRecord(
        tester,
        _Harness(
          script: [FakeVoiceTurn.result(taxiResult)],
          handsFree: true,
          speech: speech,
        ),
      );
      await _speak(tester);
      expect(speech.spoken, ['Still need: amount, category.']);
      expect(find.text('Still need: amount, category'), findsOneWidget);
    });
  });

  group('Spanish', () {
    tearDown(() => Intl.defaultLocale = null);

    testWidgets('the offer downloads only the Spanish speech model', (
      tester,
    ) async {
      final harness = _Harness(
        status: modelStatusOf(
          ModelStatusKindDto.notDownloaded,
          language: 'es',
          readyFiles: {'qwen2.5-1.5b-instruct-q5_k_m.gguf'},
        ),
      );
      await _openSpanishNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Español · 148 MB por descargar, una sola vez. '
          'Todo se procesa en este teléfono.',
        ),
        findsOneWidget,
      );
      expect(find.text('Whisper Base (español)'), findsOneWidget);
      expect(find.text('En este teléfono'), findsOneWidget);
      expect(find.text('Descargar 148 MB'), findsOneWidget);
      expect(harness.models.calls, contains('language:es'));
    });

    testWidgets('listening shows a Spanish example', (tester) async {
      final harness = _Harness();
      await _openSpanishNewRecord(tester, harness);
      await tester.tap(_mic());
      await tester.pump();
      expect(
        find.text(
          'Prueba: «Almuerzo, 12,50, categoría comida, ayer»',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Se detiene solo tras 30 segundos.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('nothing matched shows the transcript in Spanish quotes', (
      tester,
    ) async {
      final harness = _Harness(
        script: [const FakeVoiceTurn.nothingMatched('un monte doce cincuenta')],
      );
      await _openSpanishNewRecord(tester, harness);
      await _speak(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('ESCUCHADO'), findsOneWidget);
      expect(find.text('«un monte doce cincuenta»'), findsOneWidget);
    });

    testWidgets('a Spanish turn asks for the rest in Spanish', (tester) async {
      final speech = FakeSpeechOutput(instant: true);
      final engine = quickEngine([
        FakeVoiceTurn.result(
          VoiceTurnResult(
            transcript: 'Taxi a casa ayer',
            patch: [
              entry('description', text('Taxi a casa'), 'Taxi a casa'),
              entry('date', date(20000), 'ayer'),
            ],
          ),
        ),
      ]);
      final harness = _Harness(engine: engine, handsFree: true, speech: speech);
      await _openSpanishNewRecord(tester, harness);
      await _speak(tester);
      expect(find.text('Todavía falta: importe, categoría'), findsOneWidget);
      expect(speech.spoken, ['Todavía falta: importe, categoría.']);
      expect(speech.languages, contains('es'));
      expect(engine.languages, ['es']);
    });
  });

  testWidgets('no transcript reaches prefs, logs or diagnostics', (
    tester,
  ) async {
    final printed = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    final harness = _Harness(script: [FakeVoiceTurn.result(taxiResult)]);
    await _openNewRecord(tester, harness);
    await _speak(tester);
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('form-close')), warnIfMissed: false);
    await tester.pumpAndSettle();
    debugPrint = original;
    const transcript = 'Taxi home yesterday';
    expect(jsonEncode(harness.prefs.prefs.toJson()), isNot(contains('Taxi')));
    expect(printed.join('\n'), isNot(contains(transcript)));
    final logs = await harness.bridge.recentLocalLogs(100);
    expect(
      logs.map((event) => event.message).join('\n'),
      isNot(contains(transcript)),
    );
    expect(
      await harness.bridge.diagnosticBlock('local'),
      isNot(contains(transcript)),
    );
    for (final draft in harness.bridge.draftValidations) {
      for (final value in draft) {
        expect(value.value.textValue, isNot(transcript));
      }
    }
  });
}
