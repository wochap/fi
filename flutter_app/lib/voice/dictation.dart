import 'dart:async';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/panel.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// The form's one voice turn at a time: a whole-form fill turn or a dictation turn, never both.
/// The owner of the running turn holds it; every other mic is disabled meanwhile.
class VoiceTurnCoordinator extends ChangeNotifier {
  Object? _owner;

  /// Whether a turn runs.
  bool get busy => _owner != null;

  /// Whether a turn owned by someone other than [owner] runs.
  bool blockedFor(Object owner) => _owner != null && !identical(_owner, owner);

  /// Takes the turn; false when another owner holds it.
  bool claim(Object owner) {
    if (blockedFor(owner)) return false;
    if (_owner == null) {
      _owner = owner;
      notifyListeners();
    }
    return true;
  }

  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    notifyListeners();
  }
}

/// What a dictation turn into one field shows.
enum DictationPhase { idle, listening, processing }

/// A setup step a mic tap needs first. The form shows it in a sheet (phone) or dialog (wide).
enum DictationSetup { primer, permissionOff, offer }

/// Owns dictation into the Text fields of one record form: the running turn, its field, levels
/// and timer, and each field's inline error. Transcripts live only for the turn.
class DictationController extends ChangeNotifier with WidgetsBindingObserver {
  DictationController({
    required this.services,
    required this.coordinator,
    required this.onResult,
    required this.onSetup,
  }) {
    WidgetsBinding.instance.addObserver(this);
    services.models.addListener(_changed);
    coordinator.addListener(_changed);
    if (services.models.ready) services.engine.prepare();
  }

  final VoiceServices services;
  final VoiceTurnCoordinator coordinator;

  /// A turn into [fieldId] finished; the form reviews and applies it. The result is dropped
  /// when this completes.
  final Future<void> Function(String fieldId, DictationResult result) onResult;

  /// A tap on [fieldId]'s mic needs a setup step first.
  final void Function(String fieldId, DictationSetup setup) onSetup;

  DictationPhase _phase = DictationPhase.idle;
  DictationPhase get phase => _phase;

  /// The field the running turn dictates into.
  String? _fieldId;
  String? get fieldId => _fieldId;

  final Map<String, VoiceFailureKind> _errors = {};

  /// The inline error under [fieldId], if its last turn failed.
  VoiceFailureKind? errorOf(String fieldId) => _errors[fieldId];

  /// The latest input levels, oldest first.
  final List<double> levels = [];
  Duration elapsed = Duration.zero;

  Timer? _elapsedTimer;
  StreamSubscription<double>? _levelSubscription;
  var _turnToken = 0;
  var _disposed = false;

  bool get busy => _phase != DictationPhase.idle;

  /// Whether [fieldId]'s mic is disabled: another field's turn or a fill turn runs.
  bool disabledFor(String fieldId) =>
      coordinator.blockedFor(this) || (busy && _fieldId != fieldId);

  DictationPhase phaseOf(String fieldId) =>
      _fieldId == fieldId ? _phase : DictationPhase.idle;

  bool get downloading => services.models.status.transferring;

  int get downloadPercent {
    final status = services.models.status;
    return status.totalBytes == 0
        ? 0
        : status.doneBytes * 100 ~/ status.totalBytes;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _set(DictationPhase phase) {
    _phase = phase;
    _changed();
  }

  /// Tap on [fieldId]'s mic: start, or stop when it is listening.
  Future<void> micTapped(String fieldId) async {
    if (_fieldId == fieldId && _phase == DictationPhase.listening) {
      await stop();
      return;
    }
    if (busy || disabledFor(fieldId)) return;
    await begin(fieldId);
  }

  /// Runs any setup step still needed, then listens. Retry calls this too.
  Future<void> begin(String fieldId) async {
    if (busy || disabledFor(fieldId)) return;
    if (_errors.remove(fieldId) != null) _changed();
    final permission = await services.permission.status();
    if (permission == MicPermission.permanentlyDenied) {
      onSetup(fieldId, DictationSetup.permissionOff);
      return;
    }
    if (permission == MicPermission.notGranted) {
      onSetup(fieldId, DictationSetup.primer);
      return;
    }
    await afterPermission(fieldId);
  }

  /// "Continue" on the primer: asks for the microphone, then carries on.
  Future<void> primerContinue(String fieldId) async {
    final permission = await services.permission.request();
    if (permission != MicPermission.granted) {
      if (permission == MicPermission.permanentlyDenied) {
        onSetup(fieldId, DictationSetup.permissionOff);
      }
      return;
    }
    await afterPermission(fieldId);
  }

  Future<void> afterPermission(String fieldId) async {
    final models = services.models;
    if (models.ready) {
      await startListening(fieldId);
    } else if (!models.status.transferring) {
      onSetup(fieldId, DictationSetup.offer);
    }
    // A running download shows on the mic's ring; the tap waits for it.
  }

  ModelErrorDto? _downloadError;

  /// Why the last download couldn't start, such as not enough storage.
  ModelErrorDto? get downloadError =>
      _downloadError ?? services.models.status.error;

  /// "Download" on the offer.
  Future<void> startDownload() async {
    _downloadError = null;
    try {
      await services.models.start();
    } catch (error) {
      _downloadError = error is ModelErrorDto ? error : null;
    }
    _changed();
  }

  Future<void> startListening(String fieldId) async {
    if (busy || !coordinator.claim(this)) return;
    final token = ++_turnToken;
    _fieldId = fieldId;
    _errors.remove(fieldId);
    levels.clear();
    elapsed = Duration.zero;
    services.models.setVoiceTurnActive(true);
    _set(DictationPhase.listening);
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsed += const Duration(seconds: 1);
      _changed();
    });
    _levelSubscription = services.engine
        .start(kind: VoiceTurnKind.dictation)
        .listen(
          (level) {
            levels.add(level);
            if (levels.length > 24) levels.removeAt(0);
            _changed();
          },
          onError: (Object error) {
            if (token != _turnToken) return;
            final kind = error is VoiceFailure
                ? error.kind
                : VoiceFailureKind.modelLoadFailed;
            _endTurn();
            _fail(fieldId, kind);
          },
          // The engine ends the level stream itself at the turn's time cap.
          onDone: () {
            if (token == _turnToken && _phase == DictationPhase.listening) {
              unawaited(stop());
            }
          },
        );
  }

  /// Stops listening and processes the turn.
  Future<void> stop() async {
    if (_phase != DictationPhase.listening) return;
    final token = _turnToken;
    final fieldId = _fieldId!;
    _stopCapture();
    _set(DictationPhase.processing);
    DictationResult result;
    try {
      result = await services.engine.stopDictation(services.language);
    } on VoiceFailure catch (failure) {
      if (token != _turnToken) return;
      _endTurn();
      if (failure.kind != VoiceFailureKind.cancelled) {
        _fail(fieldId, failure.kind);
      }
      return;
    }
    if (token != _turnToken || _disposed) return;
    _endTurn();
    if (result.transcript.trim().isEmpty) {
      _fail(fieldId, VoiceFailureKind.noSpeech);
      return;
    }
    await onResult(fieldId, result);
  }

  void _fail(String fieldId, VoiceFailureKind kind) {
    if (kind == VoiceFailureKind.permissionDenied) {
      onSetup(fieldId, DictationSetup.permissionOff);
      return;
    }
    _errors[fieldId] = kind;
    _changed();
  }

  /// Retry under [fieldId]'s inline error.
  Future<void> retry(String fieldId) => begin(fieldId);

  /// Stops the turn silently, discarding its audio and transcript.
  Future<void> cancel() async {
    if (!busy) return;
    _turnToken++;
    _endTurn();
    await services.engine.cancel();
  }

  void _stopCapture() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    unawaited(_levelSubscription?.cancel());
    _levelSubscription = null;
  }

  void _endTurn() {
    _stopCapture();
    _fieldId = null;
    _phase = DictationPhase.idle;
    coordinator.release(this);
    if (!_disposed) services.models.setVoiceTurnActive(false);
    _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_phase != DictationPhase.listening) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      final fieldId = _fieldId!;
      _turnToken++;
      _endTurn();
      unawaited(services.engine.cancel());
      _fail(fieldId, VoiceFailureKind.interruptedBackground);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    services.models.removeListener(_changed);
    coordinator.removeListener(_changed);
    _turnToken++;
    if (busy) unawaited(services.engine.cancel());
    _stopCapture();
    coordinator.release(this);
    if (busy) services.models.setVoiceTurnActive(false);
    super.dispose();
  }
}

/// The field mic in a Text input's trailing slot: idle, disabled while another turn runs, a
/// download ring while the models download, and a stop square while listening.
class DictationMic extends StatelessWidget {
  const DictationMic({
    required this.fieldName,
    required this.phase,
    required this.onTap,
    this.disabled = false,
    this.downloadPercent,
    super.key,
  });

  final String fieldName;
  final DictationPhase phase;
  final VoidCallback onTap;
  final bool disabled;

  /// Set while the models download: the mic shows the progress ring.
  final int? downloadPercent;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final processing = phase == DictationPhase.processing;
    final enabled = !disabled && !processing;
    final label = switch (phase) {
      DictationPhase.listening => l.voiceMicStopListening,
      DictationPhase.processing => l.voiceMicProcessing,
      DictationPhase.idle when downloadPercent != null => l.voiceMicDownloading(
        downloadPercent!,
      ),
      DictationPhase.idle => l.dictationMicLabel(fieldName),
    };
    final Widget icon = switch (phase) {
      DictationPhase.listening => Container(
        key: const Key('dictation-stop'),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: context.nocturne.accent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      DictationPhase.processing => const VoiceProgressRing(size: 18),
      DictationPhase.idle => Icon(
        FiIcons.microphone,
        size: 18,
        color: enabled ? context.nocturne.accent : context.nocturne.muted(.3),
      ),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: SizedBox.square(
          dimension: Nocturne.touchTarget,
          child: Center(
            child: downloadPercent != null && phase == DictationPhase.idle
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      VoiceProgressRing(
                        key: const Key('dictation-download-ring'),
                        fraction: downloadPercent! / 100,
                        size: 28,
                      ),
                      icon,
                    ],
                  )
                : icon,
          ),
        ),
      ),
    );
  }
}

/// "Listening… m:ss" with live level bars, or "Cleaning up…" with a ring, drawn inside the field.
class DictationStateRow extends StatelessWidget {
  const DictationStateRow({
    required this.phase,
    required this.levels,
    required this.elapsed,
    super.key,
  });

  final DictationPhase phase;
  final List<double> levels;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (phase == DictationPhase.processing) {
      return Semantics(
        key: const Key('dictation-processing'),
        liveRegion: true,
        label: l.dictationCleaningUp,
        excludeSemantics: true,
        child: Row(
          spacing: 8,
          children: [
            const VoiceProgressRing(size: 14),
            Text(
              l.dictationCleaningUp,
              style: TextStyle(
                fontSize: 13,
                color: context.nocturne.muted(.75),
              ),
            ),
          ],
        ),
      );
    }
    final seconds = elapsed.inSeconds;
    final timer =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final recent = levels.length > 5
        ? levels.sublist(levels.length - 5)
        : levels;
    return Semantics(
      key: const Key('dictation-listening'),
      liveRegion: true,
      label: l.dictationListening,
      child: Row(
        spacing: 8,
        children: [
          ExcludeSemantics(
            child: Row(
              key: const Key('dictation-levels'),
              spacing: 2,
              children: [
                for (var i = 0; i < 5; i++)
                  Container(
                    width: 3,
                    height:
                        4 +
                        12 *
                            (i < 5 - recent.length
                                ? 0
                                : recent[i - (5 - recent.length)]),
                    decoration: BoxDecoration(
                      color: context.nocturne.accent,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
              ],
            ),
          ),
          ExcludeSemantics(
            child: Text(
              '${l.dictationListening} $timer',
              key: const Key('dictation-timer'),
              style: TextStyle(fontSize: 13, color: context.nocturne.accentInk),
            ),
          ),
        ],
      ),
    );
  }
}

/// The inline error under a field after a failed dictation turn, with Retry.
class DictationErrorLine extends StatelessWidget {
  const DictationErrorLine({
    required this.kind,
    required this.onRetry,
    super.key,
  });

  final VoiceFailureKind kind;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final copy = voiceErrorCopy(context.l10n, kind);
    return Row(
      children: [
        Icon(copy.icon, size: 14, color: context.nocturne.danger),
        const SizedBox(width: 6),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(
              copy.title,
              style: TextStyle(
                fontSize: 12,
                color: context.nocturne.muted(.75),
              ),
            ),
          ),
        ),
        TextButton(
          key: const Key('dictation-retry'),
          onPressed: onRetry,
          child: Text(context.l10n.commonRetry),
        ),
      ],
    );
  }
}

/// [current] with [addition] after it: one space between, or none when [current] already ends
/// in whitespace or is empty.
String appendDictation(String current, String addition) {
  if (current.isEmpty || RegExp(r'\s$').hasMatch(current)) {
    return '$current$addition';
  }
  return '$current $addition';
}

/// Shows [child] as a bottom sheet on a phone or a dialog on a wide screen.
Future<T?> showDictationSurface<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (MediaQuery.sizeOf(context).width < Nocturne.phoneBreakpoint) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => BottomSheetInsets(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: builder(sheet),
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialog) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(child: builder(dialog)),
        ),
      ),
    ),
  );
}

/// Opens [setup] for a dictation mic tap in a sheet or dialog, reusing the voice panel's
/// primer, "Microphone access is off" and download offer.
Future<void> showDictationSetup(
  BuildContext context, {
  required DictationController controller,
  required String fieldId,
  required DictationSetup setup,
}) async {
  // What to do once the surface is closed.
  Future<void> Function()? next;
  await showDictationSurface<void>(
    context,
    builder: (surface) {
      void close(Future<void> Function()? then) {
        next = then;
        Navigator.pop(surface);
      }

      final l = surface.l10n;
      return switch (setup) {
        DictationSetup.primer => VoicePrimerCard(
          onNotNow: () => close(null),
          onContinue: () => close(() => controller.primerContinue(fieldId)),
        ),
        DictationSetup.permissionOff => VoiceErrorCard(
          kind: VoiceFailureKind.permissionDenied,
          actions: [
            TextButton(
              key: const Key('voice-error-dismiss'),
              onPressed: () => close(null),
              child: Text(l.voiceNotNow),
            ),
            OutlinedButton(
              key: const Key('voice-error-open-settings'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () =>
                  close(controller.services.permission.openSettings),
              child: Text(l.voiceOpenSettings),
            ),
          ],
        ),
        DictationSetup.offer => ListenableBuilder(
          listenable: controller,
          builder: (context, _) => VoiceOfferCard(
            services: controller.services,
            error: controller.downloadError,
            onLater: () => close(null),
            onDownload: () async {
              await controller.startDownload();
              if (controller.downloadError == null && surface.mounted) {
                close(null);
              }
            },
          ),
        ),
      };
    },
  );
  await next?.call();
}

/// The "Dictated" review sheet (mock voice-dictation-review). Pops with the field's new text,
/// or null when dismissed.
class DictationReview extends StatefulWidget {
  const DictationReview({
    required this.fieldName,
    required this.current,
    required this.result,
    super.key,
  });

  final String fieldName;

  /// The field's text now; empty when the field is empty.
  final String current;
  final DictationResult result;

  @override
  State<DictationReview> createState() => _DictationReviewState();
}

class _DictationReviewState extends State<DictationReview> {
  var _cleaned = true;

  String get _selected =>
      _cleaned ? widget.result.cleaned : widget.result.transcript;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l = context.l10n;
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          '${l.dictatedTitle}, ${l.dictatedInto(widget.fieldName)}',
          Directionality.of(context),
        ),
      );
    });
  }

  Widget _version({
    required Key key,
    required bool selected,
    required String title,
    String? tag,
    required InlineSpan text,
    required VoidCallback? onTap,
    String? semanticsLabel,
  }) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? context.nocturne.accentFill : context.nocturne.bg,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          border: Border.all(
            color: selected
                ? context.nocturne.accent
                : context.nocturne.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(
                  selected ? FiIcons.radioOn : FiIcons.radioOff,
                  size: 14,
                  color: selected
                      ? context.nocturne.accent
                      : context.nocturne.muted(.4),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (tag != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: context.nocturne.accentEdge),
                    ),
                    child: Text(
                      tag,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.nocturne.accentInk,
                      ),
                    ),
                  ),
              ],
            ),
            Text.rich(
              text,
              semanticsLabel: semanticsLabel,
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );

  /// The transcript, then the removed words, since a strike-through isn't read out.
  String? _asHeardLabel(AppLocalizations l) {
    final removed = widget.result.removedWordIndexes.toSet();
    final struck = [
      for (final (index, word)
          in widget.result.transcript.split(RegExp(r'\s+')).indexed)
        if (removed.contains(index)) word,
    ];
    if (struck.isEmpty) return null;
    return '${widget.result.transcript}. ${l.dictatedRemovedWords(struck.join(' '))}';
  }

  /// The transcript with the removed words struck through.
  InlineSpan _asHeard() {
    final removed = widget.result.removedWordIndexes.toSet();
    final words = widget.result.transcript.split(RegExp(r'\s+'));
    return TextSpan(
      children: [
        for (final (index, word) in words.indexed) ...[
          if (index > 0) const TextSpan(text: ' '),
          removed.contains(index)
              ? TextSpan(
                  text: word,
                  style: TextStyle(
                    color: context.nocturne.muted(.45),
                    decoration: TextDecoration.lineThrough,
                    decorationColor: context.nocturne.muted(.6),
                  ),
                )
              : TextSpan(text: word),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final identical = widget.result.identical;
    final empty = widget.current.isEmpty;
    final quoted = l.dictatedInFieldNow(widget.current);
    return Column(
      key: const Key('dictation-review'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Row(
          children: [
            Icon(FiIcons.microphone, size: 20, color: context.nocturne.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.dictatedTitle,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    l.dictatedInto(widget.fieldName),
                    style: TextStyle(
                      fontSize: 12,
                      color: context.nocturne.muted(.6),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('dictation-review-dismiss'),
              tooltip: l.commonClose,
              onPressed: () => Navigator.pop(context),
              icon: Icon(
                FiIcons.close,
                size: 18,
                color: context.nocturne.muted(.6),
              ),
            ),
          ],
        ),
        if (identical) ...[
          _version(
            key: const Key('dictation-version-only'),
            selected: true,
            title: l.dictatedAsHeard,
            text: TextSpan(text: widget.result.transcript),
            onTap: null,
          ),
          Text(
            l.dictatedNothingToClean,
            key: const Key('dictation-nothing-to-clean'),
            style: TextStyle(fontSize: 12, color: context.nocturne.muted(.6)),
          ),
        ] else ...[
          _version(
            key: const Key('dictation-version-cleaned'),
            selected: _cleaned,
            title: l.dictatedCleaned,
            tag: l.dictatedDefault,
            text: TextSpan(text: widget.result.cleaned),
            onTap: () => setState(() => _cleaned = true),
          ),
          _version(
            key: const Key('dictation-version-heard'),
            selected: !_cleaned,
            title: l.dictatedAsHeard,
            text: _asHeard(),
            semanticsLabel: _asHeardLabel(l),
            onTap: () => setState(() => _cleaned = false),
          ),
        ],
        Text(
          empty ? l.dictatedFieldEmpty : quoted,
          key: const Key('dictation-field-now'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: context.nocturne.muted(.6)),
        ),
        if (empty)
          FilledButton(
            key: const Key('dictation-insert'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => Navigator.pop(context, _selected),
            child: Text(l.dictatedInsert),
          )
        else
          Row(
            spacing: 10,
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('dictation-append'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: () => Navigator.pop(
                    context,
                    appendDictation(widget.current, _selected),
                  ),
                  child: Text(l.dictatedAppend),
                ),
              ),
              Expanded(
                child: FilledButton(
                  key: const Key('dictation-replace'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => Navigator.pop(context, _selected),
                  child: Text(l.dictatedReplace),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Reviews a dictation [result] for a field holding [current]: skips the sheet and returns the
/// text when the field is empty and nothing was cleaned up; otherwise shows the Dictated sheet.
/// Null when dismissed.
Future<String?> reviewDictation(
  BuildContext context, {
  required String fieldName,
  required String current,
  required DictationResult result,
}) async {
  if (current.isEmpty && result.identical) return result.transcript;
  return showDictationSurface<String>(
    context,
    builder: (_) =>
        DictationReview(fieldName: fieldName, current: current, result: result),
  );
}
