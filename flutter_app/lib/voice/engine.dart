import 'dart:async';
import 'dart:math' as math;

import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// One active field of the collection, as the engine sees it.
@immutable
final class VoiceField {
  const VoiceField({
    required this.id,
    required this.name,
    required this.kind,
    this.required = false,
    this.scale,
    this.options = const [],
    this.minInteger,
    this.maxInteger,
    this.minLength,
    this.maxLength,
  });

  /// The engine's view of a schema field: its type, required flag, live options and bounds.
  factory VoiceField.fromDefinition(FieldDefinitionDto field) => VoiceField(
    id: field.id,
    name: field.name,
    kind: field.fieldType.kind,
    required: field.required_,
    scale: field.fieldType.scale,
    options: [
      for (final option in field.enumOptions)
        if (!option.deleted) (id: option.id, label: option.label),
    ],
    minInteger: field.validation.minInteger,
    maxInteger: field.validation.maxInteger,
    minLength: field.validation.minLength,
    maxLength: field.validation.maxLength,
  );

  final String id;
  final String name;
  final FieldTypeKindDto kind;
  final bool required;

  /// Decimal places of a Decimal field.
  final int? scale;

  /// A Choice field's live options.
  final List<({String id, String label})> options;
  final int? minInteger;
  final int? maxInteger;
  final int? minLength;
  final int? maxLength;
}

/// What one turn is filling: the active fields in form order and the draft's current values.
@immutable
final class VoiceFillRequest {
  const VoiceFillRequest({
    required this.fields,
    required this.draft,
    required this.language,
  });

  final List<VoiceField> fields;
  final Map<String, FieldValueDto> draft;

  /// The voice language code: "en" or "es".
  final String language;
}

/// One patch entry: a field, its typed value, and the transcript words it came from.
@immutable
final class VoicePatchEntry {
  const VoicePatchEntry({
    required this.fieldId,
    required this.value,
    required this.evidence,
  });

  final String fieldId;
  final FieldValueDto value;
  final String evidence;
}

/// A finished turn: what was heard and what the engine proposes.
@immutable
final class VoiceTurnResult {
  const VoiceTurnResult({required this.transcript, required this.patch});

  final String transcript;
  final List<VoicePatchEntry> patch;
}

/// A finished dictation turn: what was heard, the cleaned text, and which of the transcript's
/// whitespace-separated words the cleanup removed.
@immutable
final class DictationResult {
  const DictationResult({
    required this.transcript,
    required this.cleaned,
    this.removedWordIndexes = const [],
  });

  /// A result whose cleanup changed nothing.
  const DictationResult.unchanged(String transcript)
    : this(transcript: transcript, cleaned: transcript);

  final String transcript;
  final String cleaned;
  final List<int> removedWordIndexes;

  /// Whether the cleanup changed nothing.
  bool get identical => cleaned == transcript;
}

/// What a turn produces: a patch for the whole form, or text for one field.
enum VoiceTurnKind { fill, dictation }

/// The ways a turn fails.
enum VoiceFailureKind {
  noSpeech,
  nothingMatched,
  permissionDenied,
  micBusy,
  modelLoadFailed,
  lowMemory,
  interruptedBackground,
  interruptedCall,
  cancelled,
}

/// A typed turn failure; the only exception a [VoiceEngine] throws.
@immutable
final class VoiceFailure implements Exception {
  const VoiceFailure(this.kind);

  final VoiceFailureKind kind;

  @override
  String toString() => 'VoiceFailure(${kind.name})';
}

/// The one boundary to speech-to-text and field filling.
abstract interface class VoiceEngine {
  /// Whether this build can fill by voice at all. When false no voice UI is shown.
  bool get available;

  /// Starts listening for a turn of [kind]; the stream carries input levels 0..1 until [stop],
  /// [stopDictation] or [cancel]. Fails with a [VoiceFailure] (permission, busy microphone,
  /// model load) through the stream.
  Stream<double> start({VoiceTurnKind kind = VoiceTurnKind.fill});

  /// Stops listening and processes the turn. [onTranscript] fires as soon as the transcript
  /// exists, before the fields are filled. Throws a [VoiceFailure].
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  });

  /// Stops listening and processes the turn as dictation into one field, in [language].
  /// [onTranscript] fires as soon as the transcript exists, before cleanup. Throws a
  /// [VoiceFailure]; never `nothingMatched`.
  Future<DictationResult> stopDictation(
    String language, {
    ValueChanged<String>? onTranscript,
  });

  /// Stops the turn and discards its audio and transcript.
  Future<void> cancel();

  /// Ends a dictation turn's cleanup and keeps its transcript: the pending [stopDictation]
  /// completes with [DictationResult.unchanged]. Unlike [cancel] the turn succeeds. A no-op
  /// before the transcript exists, after the result, and for fill turns.
  Future<void> skipCleanup();

  /// Starts loading the instruction model in the background; called when a record form that
  /// offers voice opens with the models ready.
  void prepare();

  /// Frees the instruction model (long in the background, or memory pressure).
  void release();
}

/// Releases the engine's model after [backgroundDelay] in the background, or at once on memory
/// pressure.
final class VoiceEngineLifecycle with WidgetsBindingObserver {
  VoiceEngineLifecycle(
    this.engine, {
    this.backgroundDelay = const Duration(minutes: 5),
  });

  final VoiceEngine engine;
  final Duration backgroundDelay;
  Timer? _timer;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _timer ??= Timer(backgroundDelay, () {
        _timer = null;
        engine.release();
      });
    } else if (state == AppLifecycleState.resumed) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didHaveMemoryPressure() => engine.release();
}

/// The engine of builds without speech support: voice fill is not offered.
final class UnavailableVoiceEngine implements VoiceEngine {
  const UnavailableVoiceEngine();

  @override
  bool get available => false;

  @override
  Stream<double> start({VoiceTurnKind kind = VoiceTurnKind.fill}) =>
      Stream.error(const VoiceFailure(VoiceFailureKind.modelLoadFailed));

  @override
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  }) => Future.error(const VoiceFailure(VoiceFailureKind.modelLoadFailed));

  @override
  Future<DictationResult> stopDictation(
    String language, {
    ValueChanged<String>? onTranscript,
  }) => Future.error(const VoiceFailure(VoiceFailureKind.modelLoadFailed));

  @override
  Future<void> cancel() async {}

  @override
  Future<void> skipCleanup() async {}

  @override
  void prepare() {}

  @override
  void release() {}
}

/// One scripted turn of a [FakeVoiceEngine]: a result, or a failure raised at [failAt].
@immutable
final class FakeVoiceTurn {
  const FakeVoiceTurn.result(VoiceTurnResult this.result)
    : respond = null,
      failure = null,
      failAt = FakeFailurePoint.stop,
      transcript = null;

  /// A result computed from the turn's request.
  const FakeVoiceTurn.respond(
    VoiceTurnResult Function(VoiceFillRequest request) this.respond,
  ) : result = null,
      failure = null,
      failAt = FakeFailurePoint.stop,
      transcript = null;

  /// Fails before any transcript exists.
  const FakeVoiceTurn.failure(
    VoiceFailureKind this.failure, {
    this.failAt = FakeFailurePoint.stop,
  }) : result = null,
       respond = null,
       transcript = null;

  /// Reports [transcript], then fails as nothing matched.
  const FakeVoiceTurn.nothingMatched(String this.transcript)
    : result = null,
      respond = null,
      failure = VoiceFailureKind.nothingMatched,
      failAt = FakeFailurePoint.stop;

  final VoiceTurnResult? result;
  final VoiceTurnResult Function(VoiceFillRequest request)? respond;
  final VoiceFailureKind? failure;
  final FakeFailurePoint failAt;

  /// The transcript reported before [failure], if any.
  final String? transcript;
}

/// One scripted dictation turn of a [FakeVoiceEngine]: a result, or a failure raised at
/// [failAt].
@immutable
final class FakeDictationTurn {
  const FakeDictationTurn.result(DictationResult this.result)
    : failure = null,
      failAt = FakeFailurePoint.stop;

  const FakeDictationTurn.failure(
    VoiceFailureKind this.failure, {
    this.failAt = FakeFailurePoint.stop,
  }) : result = null;

  final DictationResult? result;
  final VoiceFailureKind? failure;
  final FakeFailurePoint failAt;
}

/// Where a scripted failure surfaces: as soon as listening starts, or when it stops.
enum FakeFailurePoint { start, stop }

/// A scripted engine for debug builds and tests. Each turn takes the next script entry;
/// past the end, the last entry repeats. Levels are synthetic.
final class FakeVoiceEngine implements VoiceEngine {
  FakeVoiceEngine({
    List<FakeVoiceTurn>? script,
    this.transcribeDelay = const Duration(milliseconds: 900),
    this.fillDelay = const Duration(milliseconds: 1600),
    this.levelInterval = const Duration(milliseconds: 80),
    List<FakeDictationTurn>? dictations,
  }) : script = script == null || script.isEmpty ? demoScript : script,
       dictations = dictations == null || dictations.isEmpty
           ? demoDictations
           : dictations;

  /// A demo for debug builds: every dictation hears a self-correction and cleans it.
  static const demoDictations = [
    FakeDictationTurn.result(
      DictationResult(
        transcript: 'Buy oat milk, no wait, almond milk',
        cleaned: 'Buy almond milk',
        removedWordIndexes: [1, 2, 3, 4],
      ),
    ),
  ];

  /// A demo for debug builds: every turn hears "Lunch" and fills the first text field.
  static final demoScript = [
    FakeVoiceTurn.respond(
      (request) => VoiceTurnResult(
        transcript: 'Lunch',
        patch: [
          for (final field
              in request.fields
                  .where((field) => field.kind == FieldTypeKindDto.text)
                  .take(1))
            VoicePatchEntry(
              fieldId: field.id,
              value: const FieldValueDto(
                kind: FieldValueKindDto.text,
                textValue: 'Lunch',
              ),
              evidence: 'Lunch',
            ),
        ],
      ),
    ),
  ];

  final List<FakeVoiceTurn> script;

  /// Scripted dictation turns; each dictation takes the next, the last repeats.
  final List<FakeDictationTurn> dictations;
  final Duration transcribeDelay;
  final Duration fillDelay;
  final Duration levelInterval;

  var _turn = 0;
  StreamController<double>? _levels;
  Timer? _ticker;
  Completer<void>? _cancelled;
  Completer<void>? _skipped;

  /// Turns started so far, of both kinds.
  int get turns => _turn;

  /// Dictation turns started so far.
  int get dictationTurns => _dictation;

  /// The language of each request passed to [stop] or [stopDictation].
  final languages = <String>[];

  /// The kind of each processed turn, in order.
  final kinds = <VoiceTurnKind>[];

  var _dictation = 0;

  /// [skipCleanup] calls so far, whether or not they took effect.
  int skips = 0;

  /// [prepare] and [release] calls so far.
  int prepares = 0;
  int releases = 0;

  @override
  void prepare() => prepares++;

  @override
  void release() => releases++;

  FakeVoiceTurn get _current =>
      script[math.max(1, math.min(_turn - _dictation, script.length)) - 1];

  FakeDictationTurn get _currentDictation =>
      dictations[math.max(1, math.min(_dictation, dictations.length)) - 1];

  @override
  bool get available => true;

  @override
  Stream<double> start({VoiceTurnKind kind = VoiceTurnKind.fill}) {
    _turn++;
    final dictation = kind == VoiceTurnKind.dictation;
    if (dictation) _dictation++;
    _stopLevels();
    final levels = _levels = StreamController<double>();
    _cancelled = Completer<void>();
    final failure = dictation
        ? (_currentDictation.failAt == FakeFailurePoint.start
              ? _currentDictation.failure
              : null)
        : (_current.failAt == FakeFailurePoint.start ? _current.failure : null);
    if (failure != null) {
      levels.addError(VoiceFailure(failure));
      unawaited(levels.close());
      return levels.stream;
    }
    var tick = 0;
    _ticker = Timer.periodic(levelInterval, (_) {
      tick++;
      levels.add((0.35 + 0.3 * math.sin(tick / 2)).clamp(0.0, 1.0));
    });
    return levels.stream;
  }

  void _stopLevels() {
    _ticker?.cancel();
    _ticker = null;
    final levels = _levels;
    _levels = null;
    if (levels != null && !levels.isClosed) unawaited(levels.close());
  }

  /// Waits [delay], or throws `cancelled` when [cancel] comes first.
  Future<void> _wait(Duration delay) async {
    final cancelled = _cancelled;
    await Future.any([
      Future<void>.delayed(delay),
      if (cancelled != null) cancelled.future,
    ]);
    if (cancelled == null || cancelled.isCompleted) {
      throw const VoiceFailure(VoiceFailureKind.cancelled);
    }
  }

  @override
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  }) async {
    languages.add(request.language);
    kinds.add(VoiceTurnKind.fill);
    _stopLevels();
    final turn = _current;
    await _wait(transcribeDelay);
    if (turn.failure case final failure?) {
      if (turn.transcript case final transcript?) {
        onTranscript?.call(transcript);
        await _wait(fillDelay);
      }
      throw VoiceFailure(failure);
    }
    final result = turn.result ?? turn.respond!(request);
    onTranscript?.call(result.transcript);
    await _wait(fillDelay);
    return result;
  }

  @override
  Future<DictationResult> stopDictation(
    String language, {
    ValueChanged<String>? onTranscript,
  }) async {
    languages.add(language);
    kinds.add(VoiceTurnKind.dictation);
    _stopLevels();
    final turn = _currentDictation;
    await _wait(transcribeDelay);
    if (turn.failure case final failure?) throw VoiceFailure(failure);
    final result = turn.result!;
    onTranscript?.call(result.transcript);
    final skipped = _skipped = Completer<void>();
    try {
      await Future.any([_wait(fillDelay), skipped.future]);
    } finally {
      _skipped = null;
    }
    if (skipped.isCompleted) {
      return DictationResult.unchanged(result.transcript);
    }
    return result;
  }

  @override
  Future<void> cancel() async {
    _stopLevels();
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
  }

  @override
  Future<void> skipCleanup() async {
    skips++;
    final skipped = _skipped;
    if (skipped != null && !skipped.isCompleted) skipped.complete();
  }
}

/// Whether the build defines `FI_VOICE_FAKE=true`.
const voiceFakeDefine = bool.fromEnvironment('FI_VOICE_FAKE');

/// The engine for this build: the fake one with `FI_VOICE_FAKE`, else the native engine when the
/// build has it ([nativeAvailable]), else the fake one in debug builds and none in release.
VoiceEngine selectVoiceEngine({
  bool debug = kDebugMode,
  bool fakeDefine = voiceFakeDefine,
  bool nativeAvailable = false,
  VoiceEngine Function()? native,
}) {
  if (fakeDefine) return FakeVoiceEngine();
  if (nativeAvailable && native != null) return native();
  return debug ? FakeVoiceEngine() : const UnavailableVoiceEngine();
}
