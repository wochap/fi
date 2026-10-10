import 'dart:async';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/controller.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/example.dart';
import 'package:fi/voice/fakes.dart';
import 'package:fi/voice/models_card.dart';
import 'package:fi/voice/patch.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'voice_fixtures.dart';

void main() {
  group('fake dictation skip', () {
    const turn = DictationResult(
      transcript: 'Lunch, I mean, dinner',
      cleaned: 'Dinner',
      removedWordIndexes: [0, 1, 2],
    );

    FakeVoiceEngine engine() => FakeVoiceEngine(
      dictations: const [FakeDictationTurn.result(turn)],
      transcribeDelay: const Duration(milliseconds: 5),
      fillDelay: const Duration(seconds: 5),
    );

    test('the transcript is reported before the cleanup delay', () async {
      final fake = FakeVoiceEngine(
        dictations: const [FakeDictationTurn.result(turn)],
        transcribeDelay: Duration.zero,
        fillDelay: const Duration(milliseconds: 5),
      );
      fake.start(kind: VoiceTurnKind.dictation).listen((_) {});
      final log = <String>[];
      final result = await fake.stopDictation(
        'en',
        onTranscript: (_) => log.add('transcript'),
      );
      log.add('result');
      expect(log, ['transcript', 'result']);
      expect(result.cleaned, 'Dinner');
    });

    test('skip after the transcript returns it unchanged', () async {
      final fake = engine();
      fake.start(kind: VoiceTurnKind.dictation).listen((_) {});
      final heard = Completer<void>();
      final result = fake.stopDictation(
        'en',
        onTranscript: (_) => heard.complete(),
      );
      await heard.future;
      await fake.skipCleanup();
      final dictation = await result.timeout(const Duration(seconds: 1));
      expect(dictation.cleaned, 'Lunch, I mean, dinner');
      expect(dictation.removedWordIndexes, isEmpty);
      expect(fake.skips, 1);
    });

    test('skip before the transcript is a no-op', () async {
      final fake = FakeVoiceEngine(
        dictations: const [FakeDictationTurn.result(turn)],
        transcribeDelay: const Duration(milliseconds: 5),
        fillDelay: const Duration(milliseconds: 5),
      );
      fake.start(kind: VoiceTurnKind.dictation).listen((_) {});
      final result = fake.stopDictation('en');
      await fake.skipCleanup();
      expect((await result).cleaned, 'Dinner');
    });
  });

  group('model sizes and status', () {
    test('formatBytes shows GB with up to two decimals and MB rounded', () {
      expect(formatBytes(1433458515), '1.43 GB');
      expect(formatBytes(1285494304), '1.29 GB');
      expect(formatBytes(12400000000), '12.4 GB');
      expect(formatBytes(2000000000), '2 GB');
      expect(formatBytes(147964211), '148 MB');
      Intl.defaultLocale = 'es';
      addTearDown(() => Intl.defaultLocale = null);
      expect(formatBytes(1433458515), '1,43 GB');
      expect(formatBytes(12400000000), '12,4 GB');
    });

    test('the Spanish set swaps in the Spanish speech model', () {
      final status = modelStatusOf(
        ModelStatusKindDto.notDownloaded,
        language: 'es',
      );
      expect(status.totalBytes, 1433445769);
      expect(status.language, 'es');
      expect(
        status.files
            .where((file) => file.role == ModelRoleDto.speech)
            .single
            .label,
        'Whisper Base (Spanish)',
      );
    });

    test('modelDisplayLabel names speech models in the UI language', () {
      final speech = modelStatusOf(
        ModelStatusKindDto.notDownloaded,
        language: 'es',
      ).files.first;
      expect(
        modelDisplayLabel(lookupAppLocalizations(const Locale('es')), speech),
        'Whisper Base (español)',
      );
      expect(
        modelDisplayLabel(lookupAppLocalizations(const Locale('en')), speech),
        'Whisper Base (Spanish)',
      );
    });

    test('formatTimeLeft reads "about"', () {
      final en = lookupAppLocalizations(const Locale('en'));
      expect(formatTimeLeft(en, 180), 'about 3 min left');
      expect(formatTimeLeft(en, 45), 'about 45 s left');
      final es = lookupAppLocalizations(const Locale('es'));
      expect(formatTimeLeft(es, 180), 'faltan unos 3 min');
    });

    List<(ModelFileStateDto, int)> states(ModelStatusDto status) => [
      for (final file in status.files) (file.state, file.storedBytes),
    ];

    test('modelStatusOf spreads done over the files in order', () {
      final idle = modelStatusOf(ModelStatusKindDto.notDownloaded);
      expect(idle.totalBytes, 1433458515);
      expect(idle.remainingBytes, 1433458515);
      expect(idle.speechLanguage, 'en');
      expect(states(idle), [
        (ModelFileStateDto.waiting, 0),
        (ModelFileStateDto.waiting, 0),
      ]);

      final downloading = modelStatusOf(
        ModelStatusKindDto.downloading,
        done: 612000000,
      );
      expect(states(downloading), [
        (ModelFileStateDto.ready, 147964211),
        (ModelFileStateDto.downloading, 464035789),
      ]);
      expect(downloading.remainingBytes, 1285494304);

      expect(
        states(modelStatusOf(ModelStatusKindDto.verifying, done: 612000000)),
        [
          (ModelFileStateDto.ready, 147964211),
          (ModelFileStateDto.checking, 464035789),
        ],
      );
      expect(
        states(
          modelStatusOf(
            ModelStatusKindDto.failed,
            done: 147964211,
            damagedFile: 'qwen2.5-1.5b-instruct-q5_k_m.gguf',
          ),
        ),
        [(ModelFileStateDto.ready, 147964211), (ModelFileStateDto.damaged, 0)],
      );
      expect(states(modelStatusOf(ModelStatusKindDto.ready)), [
        (ModelFileStateDto.ready, 147964211),
        (ModelFileStateDto.ready, 1285494304),
      ]);
    });

    test('in progress covers reconnecting and verifying', () {
      for (final kind in [
        ModelStatusKindDto.downloading,
        ModelStatusKindDto.reconnecting,
        ModelStatusKindDto.verifying,
        ModelStatusKindDto.paused,
      ]) {
        expect(FakeVoiceModels(modelStatusOf(kind)).inProgress, isTrue);
      }
      expect(
        FakeVoiceModels(
          modelStatusOf(ModelStatusKindDto.notDownloaded),
        ).inProgress,
        isFalse,
      );
    });

    test('fake cancel drops everything', () async {
      final models = FakeVoiceModels(
        modelStatusOf(ModelStatusKindDto.downloading, done: 612000000),
      );
      await models.cancel();
      expect(models.calls, ['cancel']);
      expect(models.status.kind, ModelStatusKindDto.notDownloaded);
      expect(models.status.doneBytes, 0);
    });
  });

  group('engine selection', () {
    test('debug builds and FI_VOICE_FAKE get the fake engine', () {
      expect(
        selectVoiceEngine(debug: true, fakeDefine: false),
        isA<FakeVoiceEngine>(),
      );
      expect(
        selectVoiceEngine(debug: false, fakeDefine: true),
        isA<FakeVoiceEngine>(),
      );
    });

    test('a release build without the define is unavailable', () {
      final engine = selectVoiceEngine(debug: false, fakeDefine: false);
      expect(engine, isA<UnavailableVoiceEngine>());
      expect(engine.available, isFalse);
    });

    test('the fake engine emits levels, then the scripted result', () async {
      final engine = FakeVoiceEngine(
        script: [FakeVoiceTurn.result(lunchResult)],
        transcribeDelay: const Duration(milliseconds: 5),
        fillDelay: const Duration(milliseconds: 5),
        levelInterval: const Duration(milliseconds: 1),
      );
      final levels = <double>[];
      final subscription = engine.start().listen(levels.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      String? early;
      final result = await engine.stop(
        request(),
        onTranscript: (text) => early = text,
      );
      await subscription.cancel();
      expect(levels, isNotEmpty);
      expect(levels.every((level) => level >= 0 && level <= 1), isTrue);
      expect(early, lunchResult.transcript);
      expect(result.patch, hasLength(4));
    });

    test('scripted failures surface at start or stop', () async {
      final engine = FakeVoiceEngine(
        script: const [
          FakeVoiceTurn.failure(
            VoiceFailureKind.micBusy,
            failAt: FakeFailurePoint.start,
          ),
          FakeVoiceTurn.failure(VoiceFailureKind.noSpeech),
        ],
        transcribeDelay: Duration.zero,
        fillDelay: Duration.zero,
      );
      await expectLater(
        engine.start(),
        emitsError(
          isA<VoiceFailure>().having(
            (f) => f.kind,
            'kind',
            VoiceFailureKind.micBusy,
          ),
        ),
      );
      engine.start();
      await expectLater(
        engine.stop(request()),
        throwsA(
          isA<VoiceFailure>().having(
            (f) => f.kind,
            'kind',
            VoiceFailureKind.noSpeech,
          ),
        ),
      );
    });
  });

  group('applyPatch', () {
    PatchOutcome apply(
      List<VoicePatchEntry> patch, {
      String transcript = lunchTranscript,
      Map<String, FieldValueDto> draft = const {},
      Map<String, FieldOrigin> origins = const {},
    }) => applyPatch(
      fields: expenseFields,
      draft: draft,
      origins: origins,
      patch: patch,
      transcript: transcript,
      turn: 1,
    );

    test('fills fields and marks them voice with their evidence', () {
      final outcome = apply(lunchResult.patch);
      expect(outcome.applied, ['description', 'amount', 'category', 'date']);
      expect(outcome.draft['amount'], decimal(1250));
      expect(
        outcome.origins['amount'],
        const FieldOrigin.voice(turn: 1, evidence: 'twelve fifty'),
      );
    });

    test('ignores unknown, deleted and computed fields', () {
      final outcome = apply([
        entry('ghost', text('x'), 'Lunch'),
        entry('computed-total', decimal(1), 'Lunch'),
      ]);
      expect(outcome.applied, isEmpty);
      expect(outcome.draft, isEmpty);
    });

    test('ignores values invalid for the field', () {
      final outcome = apply([
        entry('amount', text('12.50'), 'twelve fifty'),
        entry('category', choice('rent'), 'food'),
        entry('description', text('  '), 'Lunch'),
        entry(
          'date',
          const FieldValueDto(kind: FieldValueKindDto.null_),
          'yesterday',
        ),
      ]);
      expect(outcome.applied, isEmpty);
    });

    test('ignores evidence that is not in the transcript', () {
      final outcome = apply([
        entry('amount', decimal(1250), 'twelve fifty'),
      ], transcript: 'Lunch at Nandos, food');
      expect(outcome.applied, isEmpty);
    });

    test('evidence matching folds case and punctuation', () {
      expect(evidenceInTranscript("NANDO'S", "Lunch at Nando's,"), isTrue);
      expect(evidenceInTranscript('fifty', 'twelve fiftyfive'), isFalse);
      expect(evidenceInTranscript('', 'anything'), isFalse);
    });

    test('never overwrites a typed field and reports it kept', () {
      final outcome = apply(
        [
          entry('description', text('Taxi home'), 'Taxi home'),
          entry('date', date(1), 'yesterday'),
        ],
        transcript: 'Taxi home yesterday',
        draft: {'description': text('Taxi home from airport')},
        origins: {'description': FieldOrigin.typed},
      );
      expect(outcome.draft['description'], text('Taxi home from airport'));
      expect(outcome.keptTyped, ['description']);
      expect(outcome.applied, ['date']);
    });

    test('replaces defaulted and earlier voice values', () {
      final outcome = apply(
        [
          entry('category', choice('food'), 'food'),
          entry('amount', decimal(1250), 'twelve fifty'),
        ],
        draft: {'category': choice('transport'), 'amount': decimal(900)},
        origins: {
          'category': FieldOrigin.defaulted,
          'amount': const FieldOrigin.voice(turn: 1, evidence: 'nine'),
        },
      );
      expect(outcome.applied, ['category', 'amount']);
      expect(outcome.draft['category'], choice('food'));
    });
  });

  group('exampleUtterance', () {
    test('an expenses-like schema reads like a spoken record', () {
      expect(
        exampleUtterance(expenseFields),
        'Lunch, 12.50, category food, yesterday',
      );
    });

    test('Spanish fields read like a Spanish record', () {
      expect(
        exampleUtterance(spanishExpenseFields, language: 'es'),
        'Almuerzo, 12,50, categoría comida, ayer',
      );
      expect(
        exampleUtterance(expenseFields, language: 'en'),
        'Lunch, 12.50, category food, yesterday',
      );
    });

    test('covers every kind and stops at four', () {
      const fields = [
        VoiceField(id: 'a', name: 'Sets', kind: FieldTypeKindDto.integer),
        VoiceField(id: 'b', name: 'Done', kind: FieldTypeKindDto.boolean),
        VoiceField(id: 'c', name: 'Rest', kind: FieldTypeKindDto.duration),
        VoiceField(id: 'd', name: 'Note', kind: FieldTypeKindDto.text),
        VoiceField(id: 'e', name: 'Day', kind: FieldTypeKindDto.date),
      ];
      expect(exampleUtterance(fields), '3, done yes, 45 minutes, Lunch');
    });

    test('a Choices field reads as its name and first option', () {
      const fields = [
        VoiceField(
          id: 't',
          name: 'Tags',
          kind: FieldTypeKindDto.enumSet,
          options: [(id: 'w', label: 'Work'), (id: 'u', label: 'Urgent')],
        ),
      ];
      expect(exampleUtterance(fields), 'tags work');
    });
  });

  group('Choices patch values', () {
    const tags = VoiceField(
      id: 't',
      name: 'tags',
      kind: FieldTypeKindDto.enumSet,
      options: [(id: 'w', label: 'work'), (id: 'u', label: 'urgent')],
    );
    FieldValueDto set(List<String> ids) =>
        FieldValueDto(kind: FieldValueKindDto.enumSet, listValue: ids);

    test('a set of distinct active options is valid', () {
      expect(validVoiceValue(tags, set(['w', 'u'])), isTrue);
      expect(validVoiceValue(tags, set(const [])), isFalse);
      expect(validVoiceValue(tags, set(['w', 'w'])), isFalse);
      expect(validVoiceValue(tags, set(['gone'])), isFalse);
    });

    test('applyPatch replaces the set and marks it voice', () {
      final outcome = applyPatch(
        fields: const [tags],
        draft: {
          't': set(['u']),
        },
        origins: const {},
        patch: [
          VoicePatchEntry(
            fieldId: 't',
            value: set(['w', 'u']),
            evidence: 'tags work and urgent',
          ),
        ],
        transcript: 'tags work and urgent',
        turn: 1,
      );
      expect(outcome.applied, ['t']);
      expect(outcome.draft['t']!.listValue, ['w', 'u']);
      expect(outcome.origins['t']!.kind, FieldOriginKind.voice);
    });
  });

  group('VoiceFillController', () {
    late Map<String, FieldValueDto> draft;
    late FakeVoiceModels models;
    late FakeMicrophonePermission permission;
    late FakeSpeechOutput speech;
    late MemoryUiPrefsStore prefs;

    VoiceFillController make(List<FakeVoiceTurn> script) {
      draft = {};
      models = FakeVoiceModels();
      permission = FakeMicrophonePermission();
      speech = FakeSpeechOutput(instant: true);
      prefs = MemoryUiPrefsStore();
      return VoiceFillController(
        services: fakeVoiceServices(
          engine: quickEngine(script),
          models: models,
          permission: permission,
          speech: speech,
          prefs: prefs,
        ),
        fields: expenseFields,
        readDraft: () => draft,
        writeDraft: (next) => draft = {...next},
      );
    }

    Future<void> turn(WidgetTester tester, VoiceFillController c) async {
      await c.micTapped();
      expect(c.phase, VoicePhase.listening);
      expect(models.turnActive, isTrue);
      final done = c.micTapped();
      expect(c.phase, VoicePhase.processing);
      await tester.pump(const Duration(milliseconds: 20));
      await done;
    }

    testWidgets('opening with models ready prepares the engine', (
      tester,
    ) async {
      final engine = FakeVoiceEngine();
      final ready = VoiceFillController(
        services: fakeVoiceServices(engine: engine),
        fields: expenseFields,
        readDraft: () => {},
        writeDraft: (_) {},
      );
      addTearDown(ready.dispose);
      expect(engine.prepares, 1);
      final waiting = FakeVoiceEngine();
      final models = FakeVoiceModels(
        modelStatusOf(ModelStatusKindDto.notDownloaded),
      );
      final pending = VoiceFillController(
        services: fakeVoiceServices(engine: waiting, models: models),
        fields: expenseFields,
        readDraft: () => {},
        writeDraft: (_) {},
      );
      addTearDown(pending.dispose);
      expect(waiting.prepares, 0);
    });

    testWidgets('a full turn fills the form', (tester) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.phase, VoicePhase.filled);
      expect(c.lastApplied, hasLength(4));
      expect(c.heard, [lunchTranscript]);
      expect(draft['amount'], decimal(1250));
      expect(models.turnActive, isFalse);
    });

    testWidgets('missing required fields ask, answer, then follow up', (
      tester,
    ) async {
      final c = make([
        FakeVoiceTurn.result(taxiResult),
        FakeVoiceTurn.result(answerResult),
      ]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.phase, VoicePhase.need);
      expect(c.round, 1);
      expect(c.micState, MicState.ready);
      expect(c.stillNeedLine, 'Still need: amount, category');
      expect(c.isNeeded('amount'), isTrue);
      await turn(tester, c);
      expect(c.phase, VoicePhase.followup);
      expect(c.namesOf(c.lastApplied), 'amount, category');
      expect(draft['description'], text('Taxi home'));
      expect(c.heard, hasLength(2));
      expect(c.isNeeded('amount'), isFalse);
    });

    testWidgets('stops asking after two rounds', (tester) async {
      final c = make([
        FakeVoiceTurn.result(taxiResult),
        FakeVoiceTurn.result(categoryOnlyResult),
        FakeVoiceTurn.result(categoryOnlyResult),
      ]);
      addTearDown(c.dispose);
      await turn(tester, c);
      await turn(tester, c);
      expect(c.phase, VoicePhase.need);
      expect(c.round, 2);
      await turn(tester, c);
      expect(c.phase, VoicePhase.exhausted);
      expect(c.micState, MicState.idle);
      expect(c.isNeeded('amount'), isTrue);
    });

    testWidgets('a typed field is kept and reported', (tester) async {
      final c = make([FakeVoiceTurn.result(taxiResult)]);
      addTearDown(c.dispose);
      draft['description'] = text('Taxi home from airport');
      c.fieldEdited('description');
      await turn(tester, c);
      expect(draft['description'], text('Taxi home from airport'));
      expect(c.lastKeptTyped, ['description']);
    });

    for (final kind in VoiceFailureKind.values.where(
      (kind) => kind != VoiceFailureKind.cancelled,
    )) {
      testWidgets('failure ${kind.name} shows its error and keeps the form', (
        tester,
      ) async {
        final c = make([FakeVoiceTurn.failure(kind)]);
        addTearDown(c.dispose);
        draft['description'] = text('kept');
        await turn(tester, c);
        expect(c.phase, VoicePhase.error);
        expect(c.failure, kind);
        expect(draft['description'], text('kept'));
        expect(c.heard, isEmpty);
      });
    }

    testWidgets('a patch that applies nothing is "nothing matched"', (
      tester,
    ) async {
      final c = make([
        const FakeVoiceTurn.result(
          VoiceTurnResult(transcript: 'hello', patch: []),
        ),
      ]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.failure, VoiceFailureKind.nothingMatched);
    });

    testWidgets('nothing matched keeps the transcript of an empty patch', (
      tester,
    ) async {
      final c = make([
        const FakeVoiceTurn.result(
          VoiceTurnResult(transcript: 'hello', patch: []),
        ),
      ]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.failedTranscript, 'hello');
      expect(c.pendingTranscript, isNull);
      c.dismissError();
      expect(c.failedTranscript, isNull);
    });

    testWidgets('nothing matched from the engine keeps its transcript', (
      tester,
    ) async {
      final c = make([
        const FakeVoiceTurn.nothingMatched('a mount twelve fifty'),
        FakeVoiceTurn.result(lunchResult),
      ]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.failure, VoiceFailureKind.nothingMatched);
      expect(c.failedTranscript, 'a mount twelve fifty');
      unawaited(c.retry());
      await tester.pump();
      expect(c.phase, VoicePhase.listening);
      expect(c.failedTranscript, isNull);
      await c.cancel();
    });

    testWidgets('closing the sheet forgets the failed transcript', (
      tester,
    ) async {
      final c = make([const FakeVoiceTurn.nothingMatched('hello')]);
      addTearDown(c.dispose);
      await turn(tester, c);
      expect(c.failedTranscript, 'hello');
      await c.discard();
      expect(c.failedTranscript, isNull);
    });

    testWidgets('no transcript is kept without one, blank, or other failures', (
      tester,
    ) async {
      for (final script in [
        [const FakeVoiceTurn.failure(VoiceFailureKind.nothingMatched)],
        [const FakeVoiceTurn.nothingMatched('   ')],
        [
          const FakeVoiceTurn.result(
            VoiceTurnResult(transcript: '', patch: []),
          ),
        ],
        [const FakeVoiceTurn.failure(VoiceFailureKind.noSpeech)],
      ]) {
        final c = make(script);
        await turn(tester, c);
        expect(c.phase, VoicePhase.error);
        expect(c.failedTranscript, isNull);
        c.dispose();
      }
    });

    testWidgets('cancel while processing leaves the form unchanged', (
      tester,
    ) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      await c.micTapped();
      final done = c.micTapped();
      await c.cancel();
      await tester.pump(const Duration(milliseconds: 20));
      await done;
      expect(c.phase, VoicePhase.idle);
      expect(draft, isEmpty);
      expect(c.heard, isEmpty);
      expect(c.busy, isFalse);
    });

    testWidgets('going to the background while listening stops the turn', (
      tester,
    ) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      await c.micTapped();
      c.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(c.phase, VoicePhase.error);
      expect(c.failure, VoiceFailureKind.interruptedBackground);
      expect(c.busy, isFalse);
    });

    testWidgets('setup: primer, permission, then the download offer', (
      tester,
    ) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      permission.state = MicPermission.notGranted;
      models.status = modelStatusOf(ModelStatusKindDto.notDownloaded);
      await c.micTapped();
      expect(c.phase, VoicePhase.primer);
      c.primerNotNow();
      expect(c.phase, VoicePhase.idle);
      expect(permission.requests, 0);
      await c.micTapped();
      await c.primerContinue();
      expect(permission.requests, 1);
      expect(c.phase, VoicePhase.offer);
      await c.offerDownload();
      expect(c.phase, VoicePhase.downloading);
      expect(c.micState, MicState.downloading);
      models.status = modelStatusOf(ModelStatusKindDto.ready);
      expect(c.phase, VoicePhase.idle);
    });

    testWidgets('a permanently denied permission shows the error panel', (
      tester,
    ) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      permission.state = MicPermission.permanentlyDenied;
      await c.micTapped();
      expect(c.failure, VoiceFailureKind.permissionDenied);
      await c.openPermissionSettings();
      expect(permission.settingsOpened, 1);
    });

    testWidgets('hands-free speaks the confirmation', (tester) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      await c.services.prefs.setHandsFree(true);
      await turn(tester, c);
      expect(speech.spoken, ['4 fields filled. Tap Save record when ready.']);
      expect(c.phase, VoicePhase.filled);
    });

    testWidgets('discard forgets transcripts', (tester) async {
      final c = make([FakeVoiceTurn.result(lunchResult)]);
      addTearDown(c.dispose);
      await turn(tester, c);
      await c.discard();
      expect(c.heard, isEmpty);
    });
  });
}
