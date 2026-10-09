import 'package:fi/l10n/l10n.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/dictation.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  bool multiline = false,
  int order = 0,
  int? scale,
}) => FieldDefinitionDto(
  id: id,
  name: name ?? id,
  fieldType: FieldTypeDto(kind: kind, scale: scale),
  required_: required,
  validation: const ValidationMetadataDto(),
  display: DisplayMetadataDto(multiline: multiline, slider: false),
  order: order,
  deleted: false,
  enumOptions: const [],
);

/// "errands": title*, description, notes (multiline), amount, date.
FakeCollectionBridge _errands({
  List<RecordDto> records = const [],
  Map<String, String> names = const {},
}) {
  final bridge = FakeCollectionBridge()
    ..bootstrap = const BootstrapDto(
      kind: BootstrapKindDto.ready,
      rootId: 'root',
    );
  bridge.collections.add(
    const CollectionDto(
      id: 'errands',
      name: 'errands',
      description: '',
      recordCount: 0,
      fieldCount: 5,
      incompleteCount: 0,
    ),
  );
  bridge.schemas['errands'] = CollectionSchemaDto(
    id: 'errands',
    name: 'errands',
    description: '',
    fields: [
      _field(
        'title',
        FieldTypeKindDto.text,
        name: names['title'],
        required: true,
      ),
      _field(
        'description',
        FieldTypeKindDto.text,
        name: names['description'],
        order: 1,
      ),
      _field(
        'notes',
        FieldTypeKindDto.text,
        name: names['notes'],
        multiline: true,
        order: 2,
      ),
      _field(
        'amount',
        FieldTypeKindDto.fixedDecimal,
        name: names['amount'],
        order: 3,
        scale: 2,
      ),
      _field('date', FieldTypeKindDto.date, name: names['date'], order: 4),
    ],
  );
  bridge.records['errands'] = [...records];
  return bridge;
}

RecordDto _record(Map<String, String> texts) => RecordDto(
  id: 'r1',
  collectionId: 'errands',
  values: [
    for (final MapEntry(:key, :value) in texts.entries)
      RecordValueDto(fieldId: key, value: text(value)),
  ],
  valid: true,
  diagnostics: const [],
  createdAtMs: 0,
);

const _selfCorrection = DictationResult(
  transcript:
      'Pick up oat milk, no wait, almond milk, and eggs, I mean a dozen eggs',
  cleaned: 'Pick up almond milk and a dozen eggs',
  removedWordIndexes: [2, 3, 4, 5, 9, 10, 11],
);

const _lunchSam = DictationResult(
  transcript: "Lunch at Nando's, scratch that, lunch at Wagamama with Sam",
  cleaned: 'Lunch at Wagamama with Sam',
  removedWordIndexes: [0, 1, 2, 3, 4],
);

final class _Harness {
  _Harness({
    List<FakeDictationTurn> dictations = const [
      FakeDictationTurn.result(_selfCorrection),
    ],
    List<FakeVoiceTurn>? script,
    ModelStatusDto? status,
    MicPermission permission = MicPermission.granted,
    List<RecordDto> records = const [],
    Map<String, String> names = const {},
    this.engine = true,
  }) : prefs = MemoryUiPrefsStore(const UiPrefs(voiceTipDismissed: true)),
       models = FakeVoiceModels(status),
       permission = FakeMicrophonePermission(permission),
       bridge = _errands(records: records, names: names) {
    fake = FakeVoiceEngine(
      script: script ?? [FakeVoiceTurn.result(lunchResult)],
      dictations: dictations,
      transcribeDelay: const Duration(milliseconds: 5),
      fillDelay: const Duration(milliseconds: 5),
      levelInterval: const Duration(milliseconds: 50),
    );
    services = fakeVoiceServices(
      engine: engine ? fake : const UnavailableVoiceEngine(),
      models: models,
      permission: this.permission,
      prefs: prefs,
    );
  }

  final bool engine;
  final MemoryUiPrefsStore prefs;
  final FakeVoiceModels models;
  final FakeMicrophonePermission permission;
  final FakeCollectionBridge bridge;
  late final FakeVoiceEngine fake;
  late final VoiceServices services;
}

Future<void> _pumpApp(
  WidgetTester tester,
  _Harness harness, {
  Size size = _phone,
  PlatformCapabilities? capabilities,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    app(
      harness.bridge,
      voice: harness.services,
      uiPrefs: harness.prefs,
      capabilities: capabilities,
    ),
  );
  await pumpUntilFound(tester, find.text('errands'));
  await tester.tap(find.text('errands').first);
  await tester.pumpAndSettle();
}

Future<void> _openNew(
  WidgetTester tester,
  _Harness harness, {
  Size size = _phone,
  PlatformCapabilities? capabilities,
  String newRecord = 'New record',
}) async {
  await _pumpApp(tester, harness, size: size, capabilities: capabilities);
  final tip = find.byTooltip(newRecord);
  await tester.tap(
    tip.evaluate().isNotEmpty ? tip.first : find.text(newRecord).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _openEdit(
  WidgetTester tester,
  _Harness harness,
  String recordText,
) async {
  await _pumpApp(tester, harness);
  await tester.tap(find.text(recordText).first);
  await tester.pumpAndSettle();
}

Finder _row(String field) => find.byKey(ValueKey('record-field-$field'));

Finder _inRow(String field, Finder finder) =>
    find.descendant(of: _row(field), matching: finder);

Finder _mic(String field) => find.byKey(Key('dictation-mic-$field'));

DictationMic _micWidget(WidgetTester tester, String field) =>
    tester.widget<DictationMic>(_mic(field));

String _textOf(WidgetTester tester, String field) => tester
    .widget<EditableText>(_inRow(field, find.byType(EditableText)))
    .controller
    .text;

/// Taps [field]'s mic to listen, then again to stop, and lets the fake engine finish.
Future<void> _dictate(WidgetTester tester, String field) async {
  await tester.tap(_mic(field));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(_mic(field));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pumpAndSettle();
}

void main() {
  group('mic availability', () {
    testWidgets('only Text inputs get a mic', (tester) async {
      await _openNew(tester, _Harness());
      for (final field in ['title', 'description', 'notes']) {
        expect(_inRow(field, _mic(field)), findsOneWidget, reason: field);
      }
      expect(find.byType(DictationMic), findsNWidgets(3));
      expect(_mic('amount'), findsNothing);
      expect(_mic('date'), findsNothing);
      final semantics = tester.getSemantics(_mic('description'));
      expect(semantics.label, 'Dictate into description');
      expect(
        tester.getSize(_mic('description')).width,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('an optional field with text shows ✕ before the mic', (
      tester,
    ) async {
      await _openNew(tester, _Harness());
      await tester.enterText(
        _inRow('description', find.byType(EditableText)),
        'Groceries',
      );
      await tester.enterText(
        _inRow('title', find.byType(EditableText)),
        'Buy oat milk',
      );
      await tester.pump();
      final clear = _inRow('description', find.byKey(const Key('input-clear')));
      expect(clear, findsOneWidget);
      expect(
        tester.getCenter(clear).dx,
        lessThan(tester.getCenter(_mic('description')).dx),
      );
      expect(
        _inRow('title', find.byKey(const Key('input-clear'))),
        findsNothing,
      );
      expect(_mic('title'), findsOneWidget);
    });

    testWidgets('Edit record offers the mic and warms the model', (
      tester,
    ) async {
      final harness = _Harness(
        records: [
          _record({'title': 'Coffee', 'notes': 'Beans'}),
        ],
      );
      await _openEdit(tester, harness, 'Coffee');
      expect(find.text('Edit record'), findsOneWidget);
      expect(_mic('notes'), findsOneWidget);
      expect(find.byKey(const Key('voice-mic')), findsNothing);
      expect(harness.fake.prepares, greaterThan(0));
    });

    testWidgets('no mic without an engine', (tester) async {
      await _openNew(tester, _Harness(engine: false));
      expect(find.byType(DictationMic), findsNothing);
    });

    testWidgets('no mic off Android', (tester) async {
      await _openNew(
        tester,
        _Harness(),
        size: _desktop,
        capabilities: PlatformCapabilities.desktop,
      );
      expect(find.byType(DictationMic), findsNothing);
    });

    testWidgets('the mic shows at any width on Android', (tester) async {
      await _openNew(
        tester,
        _Harness(),
        size: _desktop,
        capabilities: PlatformCapabilities.androidPhone,
      );
      expect(find.byType(DictationMic), findsNWidgets(3));
    });
  });

  group('turn', () {
    testWidgets('listening then processing; other fields stay editable', (
      tester,
    ) async {
      final harness = _Harness();
      await _openNew(tester, harness);
      await tester.tap(_mic('description'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(
        _inRow('description', find.byKey(const Key('dictation-listening'))),
        findsOneWidget,
      );
      expect(find.text('Listening… 0:01'), findsOneWidget);
      expect(
        _inRow('description', find.byKey(const Key('dictation-stop'))),
        findsOneWidget,
      );
      expect(tester.getSemantics(_mic('description')).label, 'Stop listening');
      await tester.enterText(
        _inRow('amount', find.byType(EditableText)),
        '12.50',
      );
      expect(_textOf(tester, 'amount'), '12.50');
      await tester.tap(_mic('description'));
      await tester.pump();
      expect(find.text('Cleaning up…'), findsOneWidget);
      expect(harness.fake.kinds, [VoiceTurnKind.dictation]);
      expect(harness.fake.languages, ['en']);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dictation-review')), findsOneWidget);
    });

    testWidgets('a second mic and the footer mic are disabled', (tester) async {
      await _openNew(tester, _Harness());
      await tester.tap(_mic('description'));
      await tester.pump();
      expect(_micWidget(tester, 'notes').disabled, isTrue);
      expect(_micWidget(tester, 'title').disabled, isTrue);
      expect(_micWidget(tester, 'description').disabled, isFalse);
      expect(
        tester.widget<VoiceMicButton>(find.byType(VoiceMicButton)).enabled,
        isFalse,
      );
      await tester.tap(_mic('notes'));
      await tester.pump();
      expect(
        _inRow('notes', find.byKey(const Key('dictation-listening'))),
        findsNothing,
      );
      await tester.tap(_mic('description'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dictation-review-dismiss')));
      await tester.pumpAndSettle();
      expect(_micWidget(tester, 'notes').disabled, isFalse);
      expect(
        tester.widget<VoiceMicButton>(find.byType(VoiceMicButton)).enabled,
        isTrue,
      );
    });
  });

  group('review', () {
    testWidgets('a field with text: Cleaned is selected, Append adds it', (
      tester,
    ) async {
      final harness = _Harness(
        records: [
          _record({'title': 'Errand', 'notes': 'Buy oat milk'}),
        ],
      );
      await _openEdit(tester, harness, 'Errand');
      await _dictate(tester, 'notes');
      expect(find.text('Dictated'), findsOneWidget);
      expect(find.text('into notes'), findsOneWidget);
      expect(find.text('Cleaned'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('As heard'), findsOneWidget);
      expect(find.text('Pick up almond milk and a dozen eggs'), findsOneWidget);
      expect(find.text('In the field now: “Buy oat milk”'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('dictation-version-cleaned'))),
        isSemantics(isSelected: true),
      );
      // The removed words are struck through in "As heard".
      final heard = tester.widget<RichText>(
        find
            .descendant(
              of: find.byKey(const Key('dictation-version-heard')),
              matching: find.byType(RichText),
            )
            .last,
      );
      final struck = <String>[];
      heard.text.visitChildren((span) {
        if (span is TextSpan &&
            span.style?.decoration == TextDecoration.lineThrough) {
          struck.add(span.text!);
        }
        return true;
      });
      expect(struck, ['oat', 'milk,', 'no', 'wait,', 'eggs,', 'I', 'mean']);
      expect(find.byKey(const Key('dictation-append')), findsOneWidget);
      expect(find.byKey(const Key('dictation-replace')), findsOneWidget);
      expect(find.byKey(const Key('dictation-insert')), findsNothing);
      await tester.tap(find.byKey(const Key('dictation-append')));
      await tester.pumpAndSettle();
      expect(
        _textOf(tester, 'notes'),
        'Buy oat milk Pick up almond milk and a dozen eggs',
      );
    });

    testWidgets('Replace with As heard sets the raw transcript', (
      tester,
    ) async {
      final harness = _Harness(
        records: [
          _record({'title': 'Errand', 'notes': 'Buy oat milk'}),
        ],
      );
      await _openEdit(tester, harness, 'Errand');
      await _dictate(tester, 'notes');
      await tester.tap(find.byKey(const Key('dictation-version-heard')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dictation-replace')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'notes'), _selfCorrection.transcript);
    });

    testWidgets('an empty field: Insert sets the cleaned text', (tester) async {
      await _openNew(
        tester,
        _Harness(dictations: const [FakeDictationTurn.result(_lunchSam)]),
      );
      await _dictate(tester, 'description');
      expect(find.text('The field is empty.'), findsOneWidget);
      expect(find.byKey(const Key('dictation-append')), findsNothing);
      await tester.tap(find.byKey(const Key('dictation-insert')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'description'), 'Lunch at Wagamama with Sam');
    });

    testWidgets('identical versions show one and "Nothing to clean up."', (
      tester,
    ) async {
      await _openNew(
        tester,
        _Harness(
          dictations: const [
            FakeDictationTurn.result(
              DictationResult.unchanged('Team lunch at Wagamama'),
            ),
          ],
        ),
      );
      await tester.enterText(
        _inRow('description', find.byType(EditableText)),
        'Lunch',
      );
      await _dictate(tester, 'description');
      expect(find.text('Nothing to clean up.'), findsOneWidget);
      expect(find.byKey(const Key('dictation-version-cleaned')), findsNothing);
      expect(find.byKey(const Key('dictation-version-only')), findsOneWidget);
      expect(find.byKey(const Key('dictation-append')), findsOneWidget);
      expect(find.byKey(const Key('dictation-replace')), findsOneWidget);
    });

    testWidgets('an empty field with nothing to clean skips the sheet', (
      tester,
    ) async {
      final harness = _Harness(
        dictations: const [
          FakeDictationTurn.result(
            DictationResult.unchanged('Team lunch at Wagamama'),
          ),
        ],
      );
      await _openNew(tester, harness);
      await _dictate(tester, 'description');
      expect(find.byKey(const Key('dictation-review')), findsNothing);
      expect(_textOf(tester, 'description'), 'Team lunch at Wagamama');
      expect(harness.bridge.records['errands'], isEmpty);
      expect(find.byKey(const Key('voice-chip-description')), findsNothing);
    });

    testWidgets('dismissing discards the result', (tester) async {
      await _openNew(tester, _Harness());
      await tester.enterText(
        _inRow('description', find.byType(EditableText)),
        'Groceries',
      );
      await _dictate(tester, 'description');
      await tester.tap(find.byKey(const Key('dictation-review-dismiss')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'description'), 'Groceries');
    });

    testWidgets('dictated text is typed: a later fill turn keeps it', (
      tester,
    ) async {
      final harness = _Harness(
        dictations: const [
          FakeDictationTurn.result(
            DictationResult.unchanged('Team lunch at Wagamama'),
          ),
        ],
      );
      await _openNew(tester, harness);
      await _dictate(tester, 'description');
      final footer = find.byKey(const Key('voice-mic'));
      await tester.tap(footer);
      await tester.pump();
      await tester.tap(footer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(harness.fake.kinds, [VoiceTurnKind.dictation, VoiceTurnKind.fill]);
      expect(_textOf(tester, 'description'), 'Team lunch at Wagamama');
      expect(find.byKey(const Key('voice-chip-description')), findsNothing);
    });

    testWidgets('applied dictation asks before closing', (tester) async {
      final harness = _Harness(
        dictations: const [FakeDictationTurn.result(_lunchSam)],
        records: [
          _record({'title': 'Errand'}),
        ],
      );
      await _openEdit(tester, harness, 'Errand');
      await _dictate(tester, 'notes');
      await tester.tap(find.byKey(const Key('dictation-insert')));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'notes'), 'Lunch at Wagamama with Sam');
      await tester.tap(find.byKey(const Key('form-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-discard-dialog')), findsOneWidget);
    });
  });

  group('errors and setup', () {
    testWidgets('nothing heard shows an inline error with Retry', (
      tester,
    ) async {
      final harness = _Harness(
        dictations: const [
          FakeDictationTurn.failure(VoiceFailureKind.noSpeech),
        ],
      );
      await _openNew(tester, harness);
      await tester.enterText(
        _inRow('description', find.byType(EditableText)),
        'Groceries',
      );
      await _dictate(tester, 'description');
      expect(
        find.byKey(const Key('dictation-error-description')),
        findsOneWidget,
      );
      expect(find.text("Didn't hear anything"), findsOneWidget);
      expect(_textOf(tester, 'description'), 'Groceries');
      await tester.tap(find.byKey(const Key('dictation-retry')));
      await tester.pump();
      await tester.pump();
      expect(
        _inRow('description', find.byKey(const Key('dictation-listening'))),
        findsOneWidget,
      );
      expect(harness.fake.dictationTurns, 2);
      expect(
        find.byKey(const Key('dictation-error-description')),
        findsNothing,
      );
    });

    testWidgets('a busy microphone shows its line', (tester) async {
      await _openNew(
        tester,
        _Harness(
          dictations: const [
            FakeDictationTurn.failure(
              VoiceFailureKind.micBusy,
              failAt: FakeFailurePoint.start,
            ),
          ],
        ),
      );
      await tester.tap(_mic('notes'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dictation-error-notes')), findsOneWidget);
      expect(find.text('Microphone is busy'), findsOneWidget);
    });

    testWidgets('missing models open the download offer', (tester) async {
      final harness = _Harness(
        status: modelStatusOf(ModelStatusKindDto.notDownloaded),
      );
      await _openNew(tester, harness);
      await tester.tap(_mic('description'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-offer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-offer-download')));
      await tester.pumpAndSettle();
      expect(harness.models.calls, contains('start'));
      expect(find.byKey(const Key('voice-offer')), findsNothing);
      expect(find.byKey(const Key('dictation-download-ring')), findsWidgets);
    });

    testWidgets('a first tap shows the primer, then listens', (tester) async {
      final harness = _Harness(permission: MicPermission.notGranted);
      await _openNew(tester, harness);
      await tester.tap(_mic('description'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-primer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-primer-continue')));
      await tester.pumpAndSettle(const Duration(milliseconds: 10));
      await tester.pump();
      expect(harness.permission.requests, 1);
      expect(
        _inRow('description', find.byKey(const Key('dictation-listening'))),
        findsOneWidget,
      );
    });

    testWidgets('a denied microphone shows the access-off panel', (
      tester,
    ) async {
      final harness = _Harness(permission: MicPermission.permanentlyDenied);
      await _openNew(tester, harness);
      await tester.tap(_mic('description'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('voice-error-permissionDenied')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('voice-error-open-settings')));
      await tester.pumpAndSettle();
      expect(harness.permission.settingsOpened, 1);
    });
  });

  test('append joins with one space unless the text ends in whitespace', () {
    expect(appendDictation('Buy oat milk', 'eggs'), 'Buy oat milk eggs');
    expect(appendDictation('Buy oat milk ', 'eggs'), 'Buy oat milk eggs');
    expect(appendDictation('Line one\n', 'eggs'), 'Line one\neggs');
    expect(appendDictation('', 'eggs'), 'eggs');
  });

  testWidgets('the Spanish review sheet', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _phone;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: DictationReview(
            fieldName: 'notas',
            current: 'Comprar pan',
            result: DictationResult(
              transcript: 'Comprar leche de avena, digo, leche de almendra',
              cleaned: 'Comprar leche de almendra',
              removedWordIndexes: [1, 2, 3, 4],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in [
      'Dictado',
      'en notas',
      'Limpio',
      'Predeterminado',
      'Tal cual',
      'Ahora en el campo: «Comprar pan»',
      'Añadir',
      'Reemplazar',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });
}
