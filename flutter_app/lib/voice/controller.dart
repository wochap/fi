import 'dart:async';

import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/patch.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/widgets.dart';

/// What the voice panel at the top of the New record sheet shows.
enum VoicePhase {
  idle,
  primer,
  offer,
  downloading,
  listening,
  processing,
  filled,
  need,
  exhausted,
  followup,
  speaking,
  error,
}

/// The processing panel's two steps.
enum ProcessingStage { transcribing, filling }

/// What the mic button shows.
enum MicState { idle, ready, listening, processing, downloading }

/// Rounds of "Still need" before the panel stops asking.
const maxAskingRounds = 2;

/// Owns the voice flow of one New record sheet: setup, turns, the asking rounds and each
/// field's origin. Transcripts live only here, in memory, and die with the sheet.
class VoiceFillController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceFillController({
    required this.services,
    required this.fields,
    required this.readDraft,
    required this.writeDraft,
    Map<String, FieldOrigin>? origins,
  }) : draftState = VoiceDraftState(origins) {
    WidgetsBinding.instance.addObserver(this);
    services.models.addListener(_modelsChanged);
    if (services.available && services.models.ready) services.engine.prepare();
  }

  final VoiceServices services;

  /// The collection's active fields in form order.
  final List<VoiceField> fields;
  final Map<String, FieldValueDto> Function() readDraft;

  /// Replaces the form's values with a patched draft.
  final ValueChanged<Map<String, FieldValueDto>> writeDraft;
  final VoiceDraftState draftState;

  VoicePhase _phase = VoicePhase.idle;
  VoicePhase get phase => _phase;

  /// The panel to return to after a cancelled turn or a dismissed error.
  VoicePhase _resting = VoicePhase.idle;

  VoiceFailureKind? _failure;
  VoiceFailureKind? get failure => _failure;

  ProcessingStage stage = ProcessingStage.transcribing;

  /// The running turn's transcript, once it exists.
  String? pendingTranscript;

  /// Each applied turn's transcript, in order; shown in "Heard".
  final List<String> heard = [];

  /// Field ids the last turn changed.
  List<String> lastApplied = const [];

  /// Field ids the last turn named but that kept the user's value.
  List<String> lastKeptTyped = const [];

  /// Asking rounds so far (0..[maxAskingRounds]).
  int round = 0;

  /// The line being spoken in the speaking panel.
  String? spokenLine;

  /// The field whose evidence popover is open.
  String? evidenceFieldId;

  /// The latest input levels, oldest first.
  final List<double> levels = [];
  Duration elapsed = Duration.zero;

  Timer? _elapsedTimer;
  StreamSubscription<double>? _levelSubscription;
  var _turnToken = 0;
  var _disposed = false;

  bool get listening => _phase == VoicePhase.listening;
  bool get processing => _phase == VoicePhase.processing;

  /// Listening or processing: Save record is disabled and closing asks first.
  bool get busy => listening || processing;

  MicState get micState {
    if (listening) return MicState.listening;
    if (processing) return MicState.processing;
    if (services.models.status.transferring) return MicState.downloading;
    if (_phase == VoicePhase.need) return MicState.ready;
    return MicState.idle;
  }

  /// Required fields that are still empty, in form order.
  List<VoiceField> get missingRequired {
    final draft = readDraft();
    return [
      for (final field in fields)
        if (field.required && isEmptyValue(draft[field.id])) field,
    ];
  }

  /// Needed marks show once a turn has asked for fields, until they have values.
  bool isNeeded(String fieldId) =>
      round > 0 && missingRequired.any((field) => field.id == fieldId);

  String nameOf(String fieldId) =>
      fields.firstWhere((field) => field.id == fieldId).name;

  void _set(VoicePhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  void _modelsChanged() {
    if (_phase == VoicePhase.downloading && services.models.ready) {
      _phase = VoicePhase.idle;
      services.engine.prepare();
    }
    if (!_disposed) notifyListeners();
  }

  // Mic and setup.

  /// Tap on the mic.
  Future<void> micTapped() async {
    switch (_phase) {
      case VoicePhase.listening:
        await stopListening();
      case VoicePhase.processing:
        return;
      default:
        await begin();
    }
  }

  /// Press-and-hold starts listening; release stops.
  Future<void> holdStarted() async {
    if (!busy) await begin();
  }

  Future<void> holdEnded() async {
    if (listening) await stopListening();
  }

  /// Runs setup steps still unsatisfied, then listens.
  Future<void> begin() async {
    if (busy) return;
    if (_phase == VoicePhase.speaking) await muteSpeech(turnOff: false);
    if (!_isOutcome(_phase) && _phase != VoicePhase.error) {
      _resting = VoicePhase.idle;
    }
    final permission = await services.permission.status();
    if (permission == MicPermission.permanentlyDenied) {
      _fail(VoiceFailureKind.permissionDenied);
      return;
    }
    if (permission == MicPermission.notGranted) {
      _set(VoicePhase.primer);
      return;
    }
    await _afterPermission();
  }

  Future<void> _afterPermission() async {
    final models = services.models;
    if (models.ready) {
      await startListening();
    } else if (models.status.transferring) {
      _set(VoicePhase.downloading);
    } else {
      _set(VoicePhase.offer);
    }
  }

  void primerNotNow() => _set(VoicePhase.idle);

  Future<void> primerContinue() async {
    final permission = await services.permission.request();
    if (permission != MicPermission.granted) {
      _fail(VoiceFailureKind.permissionDenied);
      return;
    }
    await _afterPermission();
  }

  void offerLater() => _set(VoicePhase.idle);

  /// Starts the model download from the offer. A refusal (storage) is left in the model status.
  Future<void> offerDownload() async {
    _set(VoicePhase.downloading);
    try {
      await services.models.start();
    } catch (error) {
      _downloadError = error is ModelErrorDto ? error : null;
      notifyListeners();
    }
  }

  ModelErrorDto? _downloadError;

  /// Why the last download couldn't start, such as not enough storage.
  ModelErrorDto? get downloadError =>
      _downloadError ?? services.models.status.error;

  /// Hides the downloading card; the mic keeps its progress ring.
  void hideDownload() => _set(VoicePhase.idle);

  Future<void> pauseDownload() => services.models.pause();

  Future<void> resumeDownload() async {
    _downloadError = null;
    try {
      await services.models.start();
    } catch (error) {
      _downloadError = error is ModelErrorDto ? error : null;
    }
    if (!_disposed) notifyListeners();
  }

  // A turn.

  Future<void> startListening() async {
    if (busy) return;
    final token = ++_turnToken;
    levels.clear();
    elapsed = Duration.zero;
    pendingTranscript = null;
    services.models.setVoiceTurnActive(true);
    _set(VoicePhase.listening);
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed += const Duration(seconds: 1);
      notifyListeners();
    });
    _levelSubscription = services.engine.start().listen(
      (level) {
        levels.add(level);
        if (levels.length > 24) levels.removeAt(0);
        notifyListeners();
      },
      onError: (Object error) {
        if (token != _turnToken) return;
        _endTurn();
        _fail(
          error is VoiceFailure ? error.kind : VoiceFailureKind.modelLoadFailed,
        );
      },
      // The engine ends the level stream itself at the turn's time cap.
      onDone: () {
        if (token == _turnToken && listening) unawaited(stopListening());
      },
    );
  }

  void _stopCapture() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    unawaited(_levelSubscription?.cancel());
    _levelSubscription = null;
  }

  void _endTurn() {
    _stopCapture();
    pendingTranscript = null;
    if (!_disposed) services.models.setVoiceTurnActive(false);
  }

  VoiceFillRequest _request() => VoiceFillRequest(
    fields: fields,
    draft: Map.unmodifiable(readDraft()),
    language: services.language,
  );

  /// Copy for spoken and status lines, in the voice language.
  AppLocalizations get _l => lookupAppLocalizations(Locale(services.language));

  Future<void> stopListening() async {
    if (!listening) return;
    final token = _turnToken;
    _stopCapture();
    stage = ProcessingStage.transcribing;
    _set(VoicePhase.processing);
    VoiceTurnResult result;
    try {
      result = await services.engine.stop(
        _request(),
        onTranscript: (transcript) {
          if (token != _turnToken || _disposed) return;
          pendingTranscript = transcript;
          stage = ProcessingStage.filling;
          notifyListeners();
        },
      );
    } on VoiceFailure catch (failure) {
      if (token != _turnToken) return;
      _endTurn();
      if (failure.kind == VoiceFailureKind.cancelled) {
        _set(_resting);
      } else {
        _fail(failure.kind);
      }
      return;
    }
    if (token != _turnToken || _disposed) return;
    _endTurn();
    await _apply(result);
  }

  /// Stops the turn, discarding its audio and transcript; the form stays as it was.
  Future<void> cancel() async {
    if (!busy) return;
    _turnToken++;
    _endTurn();
    await services.engine.cancel();
    _set(_resting);
  }

  Future<void> _apply(VoiceTurnResult result) async {
    final outcome = applyPatch(
      fields: fields,
      draft: readDraft(),
      origins: draftState.origins,
      patch: result.patch,
      transcript: result.transcript,
      turn: heard.length + 1,
    );
    if (outcome.applied.isEmpty) {
      _fail(VoiceFailureKind.nothingMatched);
      return;
    }
    heard.add(result.transcript);
    draftState.replaceAll(outcome.origins);
    writeDraft(outcome.draft);
    lastApplied = outcome.applied;
    lastKeptTyped = outcome.keptTyped;
    final missing = missingRequired;
    final VoicePhase next;
    if (missing.isNotEmpty) {
      if (round < maxAskingRounds) {
        round++;
        next = VoicePhase.need;
      } else {
        next = VoicePhase.exhausted;
      }
    } else {
      next = heard.length > 1 ? VoicePhase.followup : VoicePhase.filled;
    }
    _resting = next;
    _set(next);
    if (services.prefs.handsFree) await _speakOutcome(next);
  }

  bool _isOutcome(VoicePhase phase) => const {
    VoicePhase.filled,
    VoicePhase.need,
    VoicePhase.exhausted,
    VoicePhase.followup,
  }.contains(phase);

  /// "amount, category".
  String namesOf(Iterable<String> ids) => ids.map(nameOf).join(', ');

  String get stillNeedLine =>
      _l.voiceStillNeed(missingRequired.map((field) => field.name).join(', '));

  Future<void> _speakOutcome(VoicePhase outcome) async {
    final line = switch (outcome) {
      VoicePhase.need => '$stillNeedLine.',
      VoicePhase.filled ||
      VoicePhase.followup => _l.voiceSpokenFilled(lastApplied.length),
      _ => null,
    };
    if (line == null) return;
    spokenLine = line;
    _set(VoicePhase.speaking);
    await services.speech.speak(line);
    if (_phase == VoicePhase.speaking) _set(_resting);
  }

  /// Stops speech; [turnOff] also turns hands-free off (the mute action).
  Future<void> muteSpeech({bool turnOff = true}) async {
    await services.speech.stop();
    if (turnOff) await services.prefs.setHandsFree(false);
    if (_phase == VoicePhase.speaking) _set(_resting);
  }

  // Errors.

  void _fail(VoiceFailureKind kind) {
    _failure = kind;
    _set(VoicePhase.error);
  }

  /// Dismiss, or "Not now" on the permission panel.
  void dismissError() {
    _failure = null;
    _set(_resting);
  }

  /// Try again, Speak again, Retry.
  Future<void> retry() async {
    _failure = null;
    _phase = _resting;
    await begin();
  }

  Future<void> openPermissionSettings() => services.permission.openSettings();

  // Field markers.

  /// The user changed [fieldId] by hand.
  void fieldEdited(String fieldId) {
    final wasVoice = draftState.of(fieldId).isVoice;
    draftState.markTyped(fieldId);
    if (evidenceFieldId == fieldId) evidenceFieldId = null;
    if (wasVoice || round > 0) notifyListeners();
  }

  void openEvidence(String fieldId) {
    evidenceFieldId = evidenceFieldId == fieldId ? null : fieldId;
    notifyListeners();
  }

  void closeEvidence() {
    evidenceFieldId = null;
    notifyListeners();
  }

  /// "Clear field": empties the field and removes its marker.
  void clearField(String fieldId) {
    draftState.clear(fieldId);
    evidenceFieldId = null;
    writeDraft({
      ...readDraft(),
      fieldId: const FieldValueDto(kind: FieldValueKindDto.null_),
    });
    notifyListeners();
  }

  /// The transcript a voice-filled field came from.
  String? transcriptOf(String fieldId) {
    final turn = draftState.of(fieldId).turn;
    if (turn == null || turn < 1 || turn > heard.length) return null;
    return heard[turn - 1];
  }

  // Lifecycle.

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!listening) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _turnToken++;
      _endTurn();
      unawaited(services.engine.cancel());
      _fail(VoiceFailureKind.interruptedBackground);
    }
  }

  /// Stops any turn and forgets every transcript. Called when the sheet closes.
  Future<void> discard() async {
    _turnToken++;
    if (busy) await services.engine.cancel();
    _endTurn();
    heard.clear();
    pendingTranscript = null;
    spokenLine = null;
    if (_phase == VoicePhase.speaking) await services.speech.stop();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    services.models.removeListener(_modelsChanged);
    _turnToken++;
    if (busy) unawaited(services.engine.cancel());
    _stopCapture();
    services.models.setVoiceTurnActive(false);
    heard.clear();
    pendingTranscript = null;
    super.dispose();
  }
}
