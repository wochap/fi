import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/voice.dart' as rust;
import 'package:fi/src/rust/api/voice.dart'
    show
        VoiceDraftValueDto,
        VoiceErrorKindDto,
        VoiceFieldDto,
        VoiceFillRequestDto,
        VoiceOptionDto,
        VoiceTurnEventDto;
import 'package:fi/voice/engine.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:record/record.dart';

/// 16 kHz mono PCM16.
const voiceSampleRate = 16000;

/// A turn stops capturing after this long and continues as if the user had stopped.
const maxTurnDuration = Duration(seconds: 30);

/// Little-endian PCM16 samples of [bytes]. Platform-channel buffers may start at an odd byte
/// offset, which a typed view cannot, so those are copied first.
Int16List pcm16Samples(Uint8List bytes) {
  final aligned = bytes.offsetInBytes.isEven
      ? bytes
      : Uint8List.fromList(bytes);
  return aligned.buffer.asInt16List(aligned.offsetInBytes, aligned.length ~/ 2);
}

/// The microphone as the engine needs it. Audio stays in memory.
abstract interface class AudioCapture {
  /// Opens the microphone as a stream of little-endian PCM16 16 kHz mono chunks. Throws a
  /// [VoiceFailure] with `permissionDenied` or `micBusy`.
  Future<Stream<Uint8List>> open();

  /// Closes the microphone.
  Future<void> close();

  /// Fires when audio focus is lost for a call while capturing.
  Stream<void> get interruptions;
}

/// Capture through the `record` plugin, with focus loss from `audio_session`.
final class PlatformAudioCapture implements AudioCapture {
  PlatformAudioCapture();

  AudioRecorder? _recorder;
  StreamSubscription<AudioInterruptionEvent>? _focus;
  final _interruptions = StreamController<void>.broadcast();

  @override
  Stream<void> get interruptions => _interruptions.stream;

  @override
  Future<Stream<Uint8List>> open() async {
    await _release();
    final recorder = _recorder = AudioRecorder();
    if (!await recorder.hasPermission(request: false)) {
      await _release();
      throw const VoiceFailure(VoiceFailureKind.permissionDenied);
    }
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientExclusive,
      ),
    );
    await session.setActive(true);
    _focus = session.interruptionEventStream.listen((event) {
      if (event.begin) _interruptions.add(null);
    });
    try {
      return await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: voiceSampleRate,
          numChannels: 1,
          audioInterruption: AudioInterruptionMode.none,
        ),
      );
    } on PlatformException catch (error) {
      debugPrint(
        'voice: recorder failed to start: ${error.code} ${error.message}',
      );
      await _release();
      throw const VoiceFailure(VoiceFailureKind.micBusy);
    }
  }

  Future<void> _release() async {
    await _focus?.cancel();
    _focus = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    try {
      await recorder.cancel();
    } catch (_) {}
    await recorder.dispose();
  }

  @override
  Future<void> close() async {
    await _release();
    try {
      await (await AudioSession.instance).setActive(false);
    } catch (_) {}
  }
}

/// The Rust side of the engine; a seam for tests.
abstract interface class VoiceNative {
  bool get available;
  void prepare(String modelsDir);
  Stream<VoiceTurnEventDto> fillTurn(
    String modelsDir,
    Int16List pcm,
    VoiceFillRequestDto request,
  );
  void cancel();
  void release();
}

final class RustVoiceNative implements VoiceNative {
  const RustVoiceNative();

  @override
  bool get available => rust.voiceNativeAvailable();

  @override
  void prepare(String modelsDir) => rust.voicePrepare(modelsDir: modelsDir);

  @override
  Stream<VoiceTurnEventDto> fillTurn(
    String modelsDir,
    Int16List pcm,
    VoiceFillRequestDto request,
  ) => rust.voiceFillTurn(modelsDir: modelsDir, pcm: pcm, request: request);

  @override
  void cancel() => rust.voiceCancel();

  @override
  void release() => rust.voiceRelease();
}

/// Input level 0..1 from the RMS of PCM16 samples, on a 60 dB scale.
double levelOf(Int16List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final sample in samples) {
    sum += sample * sample;
  }
  final rms = math.sqrt(sum / samples.length) / 32768;
  if (rms <= 0) return 0;
  return ((20 * math.log(rms) / math.ln10 + 60) / 60).clamp(0.0, 1.0);
}

VoiceFailureKind failureOf(VoiceErrorKindDto kind) => switch (kind) {
  VoiceErrorKindDto.noSpeech => VoiceFailureKind.noSpeech,
  VoiceErrorKindDto.nothingMatched => VoiceFailureKind.nothingMatched,
  VoiceErrorKindDto.modelLoadFailed => VoiceFailureKind.modelLoadFailed,
  VoiceErrorKindDto.lowMemory => VoiceFailureKind.lowMemory,
  VoiceErrorKindDto.cancelled => VoiceFailureKind.cancelled,
};

/// A draft value as the prompt shows it.
String draftText(VoiceField field, FieldValueDto value) {
  final integer = value.integerValue;
  return switch (value.kind) {
    FieldValueKindDto.null_ => '',
    FieldValueKindDto.text => value.textValue ?? '',
    FieldValueKindDto.boolean => value.booleanValue == true ? 'yes' : 'no',
    FieldValueKindDto.enum_ =>
      field.options
              .where((option) => option.id == value.textValue)
              .firstOrNull
              ?.label ??
          '',
    FieldValueKindDto.fixedDecimal when integer != null => _decimal(
      integer,
      field.scale ?? 0,
    ),
    FieldValueKindDto.date when integer != null => DateTime.utc(
      1970,
    ).add(Duration(days: integer)).toIso8601String().substring(0, 10),
    FieldValueKindDto.dateTime when integer != null =>
      DateTime.fromMillisecondsSinceEpoch(
        integer,
      ).toIso8601String().substring(0, 16),
    FieldValueKindDto.duration when integer != null =>
      '${(integer / 60000).round()} minutes',
    _ => integer?.toString() ?? '',
  };
}

String _decimal(int scaled, int scale) {
  if (scale == 0) return '$scaled';
  final negative = scaled < 0;
  final digits = scaled.abs().toString().padLeft(scale + 1, '0');
  final split = digits.length - scale;
  return '${negative ? '-' : ''}${digits.substring(0, split)}.${digits.substring(split)}';
}

/// The request as the bridge takes it, with the device's local date, minute and offset.
/// The grammar cache is keyed by the schema itself, so no collection id is needed.
VoiceFillRequestDto requestDto(
  VoiceFillRequest request, {
  required DateTime now,
}) => VoiceFillRequestDto(
  collectionId: '',
  fields: [
    for (final field in request.fields)
      VoiceFieldDto(
        id: field.id,
        name: field.name,
        kind: field.kind,
        scale: field.scale,
        required_: field.required,
        options: [
          for (final option in field.options)
            VoiceOptionDto(id: option.id, label: option.label),
        ],
        maxLength: field.maxLength,
      ),
  ],
  draft: [
    for (final field in request.fields)
      if (request.draft[field.id] case final value?)
        if (draftText(field, value) case final text when text.isNotEmpty)
          VoiceDraftValueDto(fieldId: field.id, text: text),
  ],
  year: now.year,
  month: now.month,
  day: now.day,
  minuteOfDay: now.hour * 60 + now.minute,
  utcOffsetMinutes: now.timeZoneOffset.inMinutes,
);

/// The on-device engine: captures PCM in Dart, transcribes and fills in Rust.
final class RustVoiceEngine implements VoiceEngine {
  RustVoiceEngine({
    required this.modelsDir,
    AudioCapture? capture,
    this.native = const RustVoiceNative(),
    this.levelInterval = const Duration(milliseconds: 80),
    this.maxDuration = maxTurnDuration,
    DateTime Function()? clock,
  }) : capture = capture ?? PlatformAudioCapture(),
       _clock = clock ?? DateTime.now;

  final String modelsDir;
  final AudioCapture capture;
  final VoiceNative native;

  /// How often levels are reported while listening.
  final Duration levelInterval;
  final Duration maxDuration;
  final DateTime Function() _clock;

  late final bool _available = native.available;

  BytesBuilder? _audio;
  StreamController<double>? _levels;
  StreamSubscription<Uint8List>? _chunks;
  StreamSubscription<void>? _interruptions;
  Timer? _levelTimer;
  Completer<VoiceTurnResult>? _pending;
  StreamSubscription<VoiceTurnEventDto>? _events;

  /// The latest ~100 ms of samples, for the level meter.
  Int16List _recent = Int16List(0);

  int get _maxBytes => maxDuration.inMilliseconds * voiceSampleRate * 2 ~/ 1000;

  @override
  bool get available => _available;

  @override
  void prepare() => native.prepare(modelsDir);

  @override
  void release() => native.release();

  @override
  Stream<double> start() {
    // The previous capture must be fully closed before the next one opens: closing releases
    // the platform recorder, and an unawaited close would release the new one instead.
    final discarded = _discardCapture();
    final levels = _levels = StreamController<double>();
    final audio = _audio = BytesBuilder(copy: false);
    _recent = Int16List(0);
    unawaited(_open(levels, audio, after: discarded));
    return levels.stream;
  }

  Future<void> _open(
    StreamController<double> levels,
    BytesBuilder audio, {
    required Future<void> after,
  }) async {
    await after;
    if (!identical(levels, _levels)) return;
    Stream<Uint8List> chunks;
    try {
      chunks = await capture.open();
    } on VoiceFailure catch (failure) {
      _failCapture(levels, failure.kind);
      return;
    } catch (error) {
      debugPrint('voice: microphone failed to open: $error');
      _failCapture(levels, VoiceFailureKind.micBusy);
      return;
    }
    if (!identical(levels, _levels)) {
      await capture.close();
      return;
    }
    _interruptions = capture.interruptions.listen((_) {
      if (identical(levels, _levels)) {
        _failCapture(levels, VoiceFailureKind.interruptedCall);
      }
    });
    _levelTimer = Timer.periodic(levelInterval, (_) {
      if (!levels.isClosed) levels.add(levelOf(_recent));
    });
    _chunks = chunks.listen((chunk) {
      if (!identical(audio, _audio)) return;
      final room = _maxBytes - audio.length;
      final take = chunk.length.clamp(0, room) & ~1;
      if (take > 0) {
        final bytes = Uint8List.sublistView(chunk, 0, take);
        audio.add(bytes);
        final samples = Int16List.fromList(pcm16Samples(bytes));
        final joined = Int16List.fromList([..._recent, ...samples]);
        final keep = math.min(joined.length, voiceSampleRate ~/ 10);
        _recent = Int16List.sublistView(joined, joined.length - keep);
      }
      if (audio.length >= _maxBytes) {
        // The cap: stop capturing and let the controller stop the turn.
        unawaited(_stopCapture());
        if (!levels.isClosed) unawaited(levels.close());
      }
    });
  }

  /// Ends capture with a failure; the audio is discarded.
  void _failCapture(StreamController<double> levels, VoiceFailureKind kind) {
    _audio = null;
    unawaited(_stopCapture());
    if (!levels.isClosed) {
      levels.addError(VoiceFailure(kind));
      unawaited(levels.close());
    }
  }

  Future<void> _stopCapture() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    await _interruptions?.cancel();
    _interruptions = null;
    final chunks = _chunks;
    _chunks = null;
    await chunks?.cancel();
    await capture.close();
  }

  Future<void> _discardCapture() async {
    _audio = null;
    _recent = Int16List(0);
    final levels = _levels;
    _levels = null;
    if (levels != null && !levels.isClosed) unawaited(levels.close());
    await _stopCapture();
  }

  @override
  Future<VoiceTurnResult> stop(
    VoiceFillRequest request, {
    ValueChanged<String>? onTranscript,
  }) async {
    final audio = _audio;
    _audio = null;
    final levels = _levels;
    _levels = null;
    await _stopCapture();
    if (levels != null && !levels.isClosed) unawaited(levels.close());
    final bytes = audio?.takeBytes() ?? Uint8List(0);
    final pcm = pcm16Samples(bytes);
    final pending = _pending = Completer<VoiceTurnResult>();
    String? transcript;
    _events = native
        .fillTurn(modelsDir, pcm, requestDto(request, now: _clock()))
        .listen(
          (event) {
            if (pending.isCompleted) return;
            if (event.transcript case final text?) {
              transcript = text;
              onTranscript?.call(text);
            }
            if (event.error case final error?) {
              pending.completeError(VoiceFailure(failureOf(error)));
            } else if (event.patch case final patch?) {
              pending.complete(
                VoiceTurnResult(
                  transcript: transcript ?? '',
                  patch: [
                    for (final entry in patch)
                      VoicePatchEntry(
                        fieldId: entry.fieldId,
                        value: entry.value,
                        evidence: entry.evidence,
                      ),
                  ],
                ),
              );
            }
          },
          onError: (Object _) {
            if (!pending.isCompleted) {
              pending.completeError(
                const VoiceFailure(VoiceFailureKind.modelLoadFailed),
              );
            }
          },
          onDone: () {
            if (!pending.isCompleted) {
              pending.completeError(
                const VoiceFailure(VoiceFailureKind.modelLoadFailed),
              );
            }
          },
        );
    try {
      return await pending.future;
    } finally {
      unawaited(_events?.cancel());
      _events = null;
      if (identical(_pending, pending)) _pending = null;
    }
  }

  @override
  Future<void> cancel() async {
    await _discardCapture();
    final pending = _pending;
    if (pending != null) {
      native.cancel();
      if (!pending.isCompleted) {
        pending.completeError(const VoiceFailure(VoiceFailureKind.cancelled));
      }
    }
  }
}
