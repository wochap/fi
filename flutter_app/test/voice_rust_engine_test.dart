import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:fi/src/rust/api/voice.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/rust_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_fixtures.dart';

final class FakeCapture implements AudioCapture {
  FakeCapture({this.failure});

  final VoiceFailureKind? failure;
  final chunks = StreamController<Uint8List>();
  final interruptionEvents = StreamController<void>.broadcast();
  var opened = 0;
  var closed = 0;

  @override
  Stream<void> get interruptions => interruptionEvents.stream;

  @override
  Future<Stream<Uint8List>> open() async {
    opened++;
    if (failure case final kind?) throw VoiceFailure(kind);
    return chunks.stream;
  }

  @override
  Future<void> close() async => closed++;

  /// Sends [samples] of one constant amplitude.
  void speak(int samples, {int amplitude = 8000}) {
    final pcm = Int16List(samples)..fillRange(0, samples, amplitude);
    chunks.add(pcm.buffer.asUint8List());
  }
}

final class FakeNative implements VoiceNative {
  FakeNative({this.available = true, List<VoiceTurnEventDto>? events})
    : events =
          events ??
          [
            const VoiceTurnEventDto(transcript: 'Lunch twelve fifty'),
            VoiceTurnEventDto(
              patch: [
                VoicePatchEntryDto(
                  fieldId: 'amount',
                  value: decimal(1250),
                  evidence: 'twelve fifty',
                ),
              ],
            ),
          ];

  @override
  final bool available;
  final List<VoiceTurnEventDto> events;
  Int16List? pcm;
  VoiceFillRequestDto? request;
  var prepares = 0;
  var cancels = 0;
  var releases = 0;
  StreamController<VoiceTurnEventDto>? running;

  @override
  void prepare(String modelsDir) => prepares++;

  /// The language of the last dictation turn.
  String? dictationLanguage;

  @override
  Stream<VoiceTurnEventDto> dictateTurn(
    String modelsDir,
    Int16List pcm,
    String language,
  ) {
    dictationLanguage = language;
    return fillTurn(modelsDir, pcm, null);
  }

  @override
  Stream<VoiceTurnEventDto> fillTurn(
    String modelsDir,
    Int16List pcm,
    VoiceFillRequestDto? request,
  ) {
    this.pcm = pcm;
    this.request = request;
    final controller = running = StreamController<VoiceTurnEventDto>();
    // No events: the turn runs until cancelled.
    if (events.isEmpty) return controller.stream;
    scheduleMicrotask(() async {
      for (final event in events) {
        await Future<void>.delayed(Duration.zero);
        if (controller.isClosed) return;
        controller.add(event);
      }
      await controller.close();
    });
    return controller.stream;
  }

  @override
  void cancel() => cancels++;

  var skips = 0;

  @override
  void skipCleanup() => skips++;

  @override
  void release() => releases++;
}

/// A capture whose close takes a few event-loop turns, like the platform recorder, and which
/// fails to open while a close is still running (the recorder it opened would be released).
final class SlowClosingCapture extends FakeCapture {
  final log = <String>[];
  var _closing = false;

  @override
  Future<Stream<Uint8List>> open() async {
    log.add('open');
    if (_closing) throw StateError('recorder released while opening');
    return super.open();
  }

  @override
  Future<void> close() async {
    log.add('close start');
    _closing = true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _closing = false;
    log.add('close end');
    await super.close();
  }
}

const request = VoiceFillRequest(
  fields: expenseFields,
  draft: {},
  language: 'en',
);

RustVoiceEngine engineWith(FakeCapture capture, FakeNative native) =>
    RustVoiceEngine(
      modelsDir: '/models',
      capture: capture,
      native: native,
      clock: () => DateTime(2026, 9, 28, 14, 7),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PCM chunks at an odd byte offset are read, not dropped', () {
    // Platform-channel buffers can start at any byte; a typed Int16 view cannot.
    final backing = Uint8List(9);
    final chunk = Uint8List.sublistView(backing, 1, 9)
      ..setAll(0, [0x40, 0x1f, 0xc0, 0xe0, 0x00, 0x00, 0x01, 0x00]);
    expect(pcm16Samples(chunk), [8000, -8000, 0, 1]);
  });

  test('levels are RMS on a 60 dB scale', () {
    expect(levelOf(Int16List(100)), 0);
    expect(levelOf(Int16List(100)..fillRange(0, 100, 32767)), closeTo(1, 0.01));
    final quiet = levelOf(Int16List(100)..fillRange(0, 100, 33));
    final loud = levelOf(Int16List(100)..fillRange(0, 100, 8000));
    expect(quiet, lessThan(0.05));
    expect(loud, greaterThan(0.6));
  });

  Future<void> settle() => pumpEventQueue();

  test('a turn captures PCM, reports levels and returns the patch', () async {
    final capture = FakeCapture();
    final native = FakeNative();
    final engine = engineWith(capture, native);
    final levels = <double>[];
    engine.start().listen(levels.add);
    await settle();
    capture.speak(1600);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(levels.length, greaterThanOrEqualTo(10));
    expect(levels.last, greaterThan(0.5));
    String? heard;
    final result = await engine.stop(
      request,
      onTranscript: (text) => heard = text,
    );
    expect(heard, 'Lunch twelve fifty');
    expect(result.transcript, 'Lunch twelve fifty');
    expect(result.patch.single.fieldId, 'amount');
    expect(native.pcm!.length, 1600);
    expect(native.request!.year, 2026);
    expect(native.request!.minuteOfDay, 14 * 60 + 7);
    expect(native.request!.fields.map((field) => field.name), [
      'description',
      'amount',
      'category',
      'date',
    ]);
    expect(capture.closed, greaterThan(0));
  });

  test('a dictation turn returns the cleaned text and removed words', () async {
    final capture = FakeCapture();
    final native = FakeNative(
      events: [
        const VoiceTurnEventDto(
          transcript: 'Buy oat milk, no wait, almond milk',
        ),
        VoiceTurnEventDto(
          dictation: VoiceDictationDto(
            cleaned: 'Buy almond milk',
            removed: Uint32List.fromList([1, 2, 3, 4]),
          ),
        ),
      ],
    );
    final engine = engineWith(capture, native);
    engine.start(kind: VoiceTurnKind.dictation).listen((_) {});
    await settle();
    capture.speak(1600);
    await settle();
    String? heard;
    final result = await engine.stopDictation(
      'es',
      onTranscript: (text) => heard = text,
    );
    expect(heard, 'Buy oat milk, no wait, almond milk');
    expect(result.transcript, 'Buy oat milk, no wait, almond milk');
    expect(result.cleaned, 'Buy almond milk');
    expect(result.removedWordIndexes, [1, 2, 3, 4]);
    expect(native.dictationLanguage, 'es');
    expect(native.pcm!.length, 1600);
  });

  group('skip cleanup', () {
    const heardText = 'Pick up oat milk, no wait, almond milk';

    /// A dictation turn whose Rust events the test sends through `native.running`.
    Future<(RustVoiceEngine, FakeNative, Future<DictationResult>, List<String>)>
    started() async {
      final capture = FakeCapture();
      final native = FakeNative(events: []);
      final engine = engineWith(capture, native);
      engine.start(kind: VoiceTurnKind.dictation).listen((_) {});
      await settle();
      final log = <String>[];
      final result = engine
          .stopDictation('en', onTranscript: (text) => log.add('transcript'))
          .then((result) {
            log.add('result');
            return result;
          });
      await settle();
      return (engine, native, result, log);
    }

    test('the transcript is reported before the result', () async {
      final (_, native, result, log) = await started();
      native.running!.add(const VoiceTurnEventDto(transcript: heardText));
      await settle();
      expect(log, ['transcript']);
      native.running!.add(
        VoiceTurnEventDto(
          dictation: VoiceDictationDto(
            cleaned: 'Pick up almond milk',
            removed: Uint32List.fromList([2, 3, 4, 5]),
          ),
        ),
      );
      expect((await result).cleaned, 'Pick up almond milk');
      expect(log, ['transcript', 'result']);
    });

    test('before the transcript it is a no-op', () async {
      final (engine, native, result, log) = await started();
      await engine.skipCleanup();
      expect(native.skips, 0);
      native.running!.add(const VoiceTurnEventDto(transcript: heardText));
      native.running!.add(
        VoiceTurnEventDto(
          dictation: VoiceDictationDto(
            cleaned: 'Pick up almond milk',
            removed: Uint32List.fromList([2, 3, 4, 5]),
          ),
        ),
      );
      expect((await result).cleaned, 'Pick up almond milk');
    });

    test('during cleanup it returns the transcript unchanged', () async {
      final (engine, native, result, _) = await started();
      native.running!.add(const VoiceTurnEventDto(transcript: heardText));
      await settle();
      await engine.skipCleanup();
      final dictation = await result;
      expect(dictation.cleaned, heardText);
      expect(dictation.transcript, heardText);
      expect(dictation.removedWordIndexes, isEmpty);
      expect(native.skips, 1);
      expect(native.cancels, 0);
    });

    test('racing a cleaned result completes exactly once', () async {
      final (engine, native, result, log) = await started();
      native.running!.add(const VoiceTurnEventDto(transcript: heardText));
      await settle();
      await engine.skipCleanup();
      native.running!.add(
        VoiceTurnEventDto(
          dictation: VoiceDictationDto(
            cleaned: 'Pick up almond milk',
            removed: Uint32List.fromList([2, 3, 4, 5]),
          ),
        ),
      );
      await settle();
      expect((await result).cleaned, heardText);
      expect(log, ['transcript', 'result']);
      await engine.skipCleanup();
      expect(native.skips, 1);
    });
  });

  test('a dictation failure from Rust becomes a VoiceFailure', () async {
    final engine = engineWith(
      FakeCapture(),
      FakeNative(
        events: [const VoiceTurnEventDto(error: VoiceErrorKindDto.noSpeech)],
      ),
    );
    engine.start(kind: VoiceTurnKind.dictation).listen((_) {});
    await settle();
    await expectLater(
      engine.stopDictation('en'),
      throwsA(
        isA<VoiceFailure>().having(
          (failure) => failure.kind,
          'kind',
          VoiceFailureKind.noSpeech,
        ),
      ),
    );
  });

  test('capture stops at the time cap and ends the level stream', () async {
    final capture = FakeCapture();
    final native = FakeNative();
    final engine = RustVoiceEngine(
      modelsDir: '/models',
      capture: capture,
      native: native,
      maxDuration: const Duration(milliseconds: 500),
    );
    final done = Completer<void>();
    engine.start().listen((_) {}, onDone: done.complete);
    await settle();
    capture.speak(16000);
    await done.future;
    await engine.stop(request);
    expect(native.pcm!.length, 8000);
  });

  test(
    'the previous capture is fully closed before the microphone opens',
    () async {
      final capture = SlowClosingCapture();
      final engine = engineWith(capture, FakeNative());
      final levels = engine.start();
      final subscription = levels.listen(
        (_) {},
        onError: (Object error) {
          fail('start failed: $error');
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(capture.log, ['close start', 'close end', 'open']);
      await subscription.cancel();
      await engine.cancel();
    },
  );

  test('open failures surface through the level stream', () async {
    for (final kind in [
      VoiceFailureKind.micBusy,
      VoiceFailureKind.permissionDenied,
    ]) {
      final engine = engineWith(FakeCapture(failure: kind), FakeNative());
      await expectLater(
        engine.start(),
        emitsError(isA<VoiceFailure>().having((f) => f.kind, 'kind', kind)),
      );
    }
  });

  test(
    'a call while listening is interruptedCall and drops the audio',
    () async {
      final capture = FakeCapture();
      final engine = engineWith(capture, FakeNative());
      final levels = engine.start();
      final failed = expectLater(
        levels,
        emitsThrough(
          emitsError(
            isA<VoiceFailure>().having(
              (f) => f.kind,
              'kind',
              VoiceFailureKind.interruptedCall,
            ),
          ),
        ),
      );
      await settle();
      capture.speak(1600);
      capture.interruptionEvents.add(null);
      await failed;
      expect(capture.closed, greaterThan(0));
    },
  );

  test('typed failures from Rust become VoiceFailures', () async {
    final native = FakeNative(
      events: [const VoiceTurnEventDto(error: VoiceErrorKindDto.noSpeech)],
    );
    final engine = engineWith(FakeCapture(), native);
    engine.start();
    await settle();
    await expectLater(
      engine.stop(request),
      throwsA(
        isA<VoiceFailure>().having(
          (f) => f.kind,
          'kind',
          VoiceFailureKind.noSpeech,
        ),
      ),
    );
  });

  test(
    'cancel during processing stops Rust and fails with cancelled',
    () async {
      final native = FakeNative(events: []);
      final engine = engineWith(FakeCapture(), native);
      engine.start();
      await settle();
      final stopped = expectLater(
        engine.stop(request),
        throwsA(
          isA<VoiceFailure>().having(
            (f) => f.kind,
            'kind',
            VoiceFailureKind.cancelled,
          ),
        ),
      );
      while (native.running == null) {
        await settle();
      }
      await engine.cancel();
      await stopped;
      expect(native.cancels, 1);
    },
  );

  test('draft values are sent as display text', () {
    final dto = requestDto(
      VoiceFillRequest(
        fields: expenseFields,
        draft: {
          'amount': decimal(-305),
          'category': choice('food'),
          'date': date(20723),
          'description': text(''),
        },
        language: 'en',
      ),
      now: DateTime(2026, 9, 28),
    );
    expect(
      {for (final value in dto.draft) value.fieldId: value.text},
      {'amount': '-3.05', 'category': 'Food', 'date': '2026-09-27'},
    );
  });

  test('the voice language is sent', () {
    const spanish = VoiceFillRequest(
      fields: expenseFields,
      draft: {},
      language: 'es',
    );
    expect(requestDto(spanish, now: DateTime(2026, 9, 28)).language, 'es');
    expect(requestDto(request, now: DateTime(2026, 9, 28)).language, 'en');
  });

  group('selection and lifecycle', () {
    test('the native engine wins unless FI_VOICE_FAKE is set', () {
      final native = FakeNative();
      VoiceEngine build() => engineWith(FakeCapture(), native);
      expect(
        selectVoiceEngine(debug: false, nativeAvailable: true, native: build),
        isA<RustVoiceEngine>(),
      );
      expect(
        selectVoiceEngine(debug: true, nativeAvailable: true, native: build),
        isA<RustVoiceEngine>(),
      );
      expect(
        selectVoiceEngine(
          debug: false,
          fakeDefine: true,
          nativeAvailable: true,
          native: build,
        ),
        isA<FakeVoiceEngine>(),
      );
      expect(
        selectVoiceEngine(debug: false, nativeAvailable: false, native: build),
        isA<UnavailableVoiceEngine>(),
      );
    });

    test('prepare and release reach Rust', () {
      final native = FakeNative();
      final engine = engineWith(FakeCapture(), native);
      expect(engine.available, isTrue);
      engine.prepare();
      engine.release();
      expect((native.prepares, native.releases), (1, 1));
    });

    test('the model is released after 5 minutes in the background', () {
      fakeAsync((async) {
        final engine = FakeVoiceEngine();
        final lifecycle = VoiceEngineLifecycle(engine);
        lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 4));
        lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
        async.elapse(const Duration(minutes: 5));
        expect(engine.releases, 0);
        lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 5));
        expect(engine.releases, 1);
        lifecycle.didHaveMemoryPressure();
        expect(engine.releases, 2);
      });
    });
  });
}
