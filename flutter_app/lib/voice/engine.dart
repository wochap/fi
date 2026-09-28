import 'dart:async';
import 'dart:math' as math;

import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/foundation.dart';

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
  const VoiceFillRequest({required this.fields, required this.draft});

  final List<VoiceField> fields;
  final Map<String, FieldValueDto> draft;
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

  /// Starts listening; the stream carries input levels 0..1 until [stop] or [cancel].
  /// Fails with a [VoiceFailure] (permission, busy microphone, model load) through the stream.
  Stream<double> start();

  /// Stops listening and processes the turn. [onTranscript] fires as soon as the transcript
  /// exists, before the fields are filled. Throws a [VoiceFailure].
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  });

  /// Stops the turn and discards its audio and transcript.
  Future<void> cancel();
}

/// The engine of builds without speech support: voice fill is not offered.
final class UnavailableVoiceEngine implements VoiceEngine {
  const UnavailableVoiceEngine();

  @override
  bool get available => false;

  @override
  Stream<double> start() =>
      Stream.error(const VoiceFailure(VoiceFailureKind.modelLoadFailed));

  @override
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  }) => Future.error(const VoiceFailure(VoiceFailureKind.modelLoadFailed));

  @override
  Future<void> cancel() async {}
}

/// One scripted turn of a [FakeVoiceEngine]: a result, or a failure raised at [failAt].
@immutable
final class FakeVoiceTurn {
  const FakeVoiceTurn.result(VoiceTurnResult this.result)
    : respond = null,
      failure = null,
      failAt = FakeFailurePoint.stop;

  /// A result computed from the turn's request.
  const FakeVoiceTurn.respond(
    VoiceTurnResult Function(VoiceFillRequest request) this.respond,
  ) : result = null,
      failure = null,
      failAt = FakeFailurePoint.stop;

  const FakeVoiceTurn.failure(
    VoiceFailureKind this.failure, {
    this.failAt = FakeFailurePoint.stop,
  }) : result = null,
       respond = null;

  final VoiceTurnResult? result;
  final VoiceTurnResult Function(VoiceFillRequest request)? respond;
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
  }) : script = script == null || script.isEmpty ? demoScript : script;

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
  final Duration transcribeDelay;
  final Duration fillDelay;
  final Duration levelInterval;

  var _turn = 0;
  StreamController<double>? _levels;
  Timer? _ticker;
  Completer<void>? _cancelled;

  /// Turns started so far.
  int get turns => _turn;

  FakeVoiceTurn get _current => script[math.min(_turn, script.length) - 1];

  @override
  bool get available => true;

  @override
  Stream<double> start() {
    _turn++;
    _stopLevels();
    final levels = _levels = StreamController<double>();
    _cancelled = Completer<void>();
    final turn = _current;
    if (turn.failAt == FakeFailurePoint.start && turn.failure != null) {
      levels.addError(VoiceFailure(turn.failure!));
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
    _stopLevels();
    final turn = _current;
    await _wait(transcribeDelay);
    if (turn.failure case final failure?) throw VoiceFailure(failure);
    final result = turn.result ?? turn.respond!(request);
    onTranscript?.call(result.transcript);
    await _wait(fillDelay);
    return result;
  }

  @override
  Future<void> cancel() async {
    _stopLevels();
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
  }
}

/// Whether the build defines `FI_VOICE_FAKE=true`.
const voiceFakeDefine = bool.fromEnvironment('FI_VOICE_FAKE');

/// The engine for this build: the fake one in debug builds or with `FI_VOICE_FAKE`, otherwise
/// unavailable until a real engine exists.
VoiceEngine selectVoiceEngine({
  bool debug = kDebugMode,
  bool fakeDefine = voiceFakeDefine,
}) => debug || fakeDefine ? FakeVoiceEngine() : const UnavailableVoiceEngine();
