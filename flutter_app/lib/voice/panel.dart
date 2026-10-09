import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/voice/controller.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/example.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/models_card.dart';
import 'package:fi/voice/rust_engine.dart' show maxTurnDuration;
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

const _panelPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

BoxDecoration _plain(NocturneColors c, {bool outlined = false}) =>
    BoxDecoration(
      color: c.bg,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: outlined ? Border.all(color: c.accentEdge) : null,
    );

/// The `nocturneGlow` of the primer and listening panels: accentFill fading into bg.
BoxDecoration _glow(
  NocturneColors c, {
  required AlignmentGeometry center,
  double radius = 1,
}) => BoxDecoration(
  gradient: RadialGradient(
    center: center,
    radius: radius,
    colors: [c.accentFill, c.bg],
    stops: const [0, .65],
  ),
  borderRadius: BorderRadius.circular(Nocturne.radius),
  border: Border.all(color: c.accentEdge),
);

TextStyle _muted(NocturneColors c, double opacity, [double size = 12]) =>
    TextStyle(fontSize: size, color: c.muted(opacity), height: 1.4);

const _title = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

/// A panel title announced to screen readers when it appears.
Widget _announced(String text, {TextStyle style = _title, Key? key}) =>
    Semantics(
      liveRegion: true,
      child: Text(text, key: key, style: style),
    );

String _ordinal(AppLocalizations l, int n) => switch (n) {
  1 => l.voiceOrdinalFirst,
  2 => l.voiceOrdinalSecond,
  3 => l.voiceOrdinalThird,
  _ => l.voiceOrdinalOther(n),
};

Widget _twoButtons({
  required Key secondaryKey,
  required String secondary,
  required VoidCallback onSecondary,
  required Key primaryKey,
  required String primary,
  required VoidCallback onPrimary,
  IconData? primaryIcon,
}) => Row(
  children: [
    Expanded(
      child: OutlinedButton(
        key: secondaryKey,
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: onSecondary,
        child: Text(secondary),
      ),
    ),
    const SizedBox(width: 10),
    Expanded(
      child: FilledButton.icon(
        key: primaryKey,
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
        onPressed: onPrimary,
        icon: primaryIcon == null ? null : Icon(primaryIcon, size: 18),
        label: Text(primary),
      ),
    ),
  ],
);

Widget _infoRow({
  required Key key,
  required IconData icon,
  required Color iconColor,
  required String text,
  String? trailing,
  required Color trailingColor,
}) => Row(
  key: key,
  children: [
    Icon(icon, size: 16, color: iconColor),
    const SizedBox(width: 8),
    Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
    if (trailing != null)
      Text(trailing, style: TextStyle(fontSize: 12, color: trailingColor)),
  ],
);

/// The microphone primer: why voice needs the microphone, before the system prompt.
class VoicePrimerCard extends StatelessWidget {
  const VoicePrimerCard({
    required this.onNotNow,
    required this.onContinue,
    super.key,
  });

  final VoidCallback onNotNow;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('voice-primer'),
    padding: const EdgeInsets.all(16),
    decoration: _glow(context.nocturne, center: Alignment.topLeft, radius: 1.4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: context.nocturne.accent),
          ),
          child: Icon(
            FiIcons.microphone,
            size: 22,
            color: context.nocturne.accent,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            _announced(
              context.l10n.voicePrimerTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            Text(
              context.l10n.voicePrivacyLine,
              style: _muted(context.nocturne, .7, 13),
            ),
          ],
        ),
        Text(
          context.l10n.voicePrimerNext,
          style: _muted(context.nocturne, .55),
        ),
        _twoButtons(
          secondaryKey: const Key('voice-primer-not-now'),
          secondary: context.l10n.voiceNotNow,
          onSecondary: onNotNow,
          primaryKey: const Key('voice-primer-continue'),
          primary: context.l10n.voiceContinue,
          onPrimary: onContinue,
        ),
      ],
    ),
  );
}

/// The voice model download offer: the set's size and files, network and free storage.
class VoiceOfferCard extends StatefulWidget {
  const VoiceOfferCard({
    required this.services,
    required this.onLater,
    required this.onDownload,
    this.error,
    super.key,
  });

  final VoiceServices services;

  /// Why the last download couldn't start, such as not enough storage.
  final ModelErrorDto? error;
  final VoidCallback onLater;
  final VoidCallback onDownload;

  @override
  State<VoiceOfferCard> createState() => _VoiceOfferCardState();
}

class _VoiceOfferCardState extends State<VoiceOfferCard> {
  NetworkKind? _network;
  int? _freeBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final network = await widget.services.network.current();
    final free = await widget.services.models.freeStorageBytes();
    if (!mounted) return;
    setState(() {
      _network = network;
      _freeBytes = free;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.services.models.status;
    final size = formatBytes(status.remainingBytes);
    final language = modelLanguageName(context.l10n, status.speechLanguage);
    final partlyStored = status.files.any(
      (file) => file.state == ModelFileStateDto.ready,
    );
    final mobile = _network == NetworkKind.mobile;
    final error = widget.error;
    return Container(
      key: const Key('voice-offer'),
      padding: const EdgeInsets.all(16),
      decoration: _plain(context.nocturne, outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            children: [
              Icon(FiIcons.download, size: 22, color: context.nocturne.accent),
              const SizedBox(width: 10),
              Expanded(
                child: _announced(
                  context.l10n.modelOfferTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          Text(
            partlyStored
                ? context.l10n.modelOfferToDownload(
                    languageEndonym(status.language),
                    size,
                  )
                : context.l10n.modelOfferLine(language, size),
            style: _muted(context.nocturne, .7, 13),
          ),
          Column(
            spacing: 6,
            children: [
              for (final file in status.files)
                Row(
                  key: Key('voice-offer-model-${file.name}'),
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            modelRoleName(context.l10n, file.role),
                            style: _muted(context.nocturne, .55, 11),
                          ),
                          Text(
                            modelDisplayLabel(context.l10n, file),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      file.state == ModelFileStateDto.ready
                          ? context.l10n.modelOnThisPhone
                          : formatBytes(file.sizeBytes),
                      style: _muted(
                        context.nocturne,
                        .6,
                      ).copyWith(fontFeatures: Nocturne.tabular),
                    ),
                  ],
                ),
            ],
          ),
          Column(
            spacing: 6,
            children: [
              if (_network != null)
                _infoRow(
                  key: const Key('voice-offer-network'),
                  icon: mobile ? FiIcons.mobileData : FiIcons.wifi,
                  iconColor: mobile
                      ? context.nocturne.accentText
                      : context.nocturne.muted(.7),
                  text: mobile
                      ? context.l10n.modelOnMobileData
                      : context.l10n.modelOnWifi,
                  trailing: mobile ? context.l10n.modelWifiRecommended : null,
                  trailingColor: context.nocturne.accentText,
                ),
              _infoRow(
                key: const Key('voice-offer-storage'),
                icon: FiIcons.storage,
                iconColor: context.nocturne.muted(.7),
                text: context.l10n.modelStorage,
                trailing: _freeBytes == null
                    ? null
                    : context.l10n.modelFree(formatBytes(_freeBytes!)),
                trailingColor: context.nocturne.muted(.6),
              ),
            ],
          ),
          if (error != null) _downloadErrorLine(error),
          _twoButtons(
            secondaryKey: const Key('voice-offer-later'),
            secondary: context.l10n.modelLater,
            onSecondary: widget.onLater,
            primaryKey: const Key('voice-offer-download'),
            primary: context.l10n.modelDownload(size),
            primaryIcon: FiIcons.download,
            onPrimary: widget.onDownload,
          ),
        ],
      ),
    );
  }

  Widget _downloadErrorLine(ModelErrorDto error) {
    final (title, line) = modelFailureText(
      context.l10n,
      widget.services.models.status.error == error
          ? widget.services.models.status
          : modelStatusOf(ModelStatusKindDto.failed, error: error),
    );
    return Text(
      context.l10n.modelErrorLine(title, line),
      key: const Key('voice-download-error'),
      style: TextStyle(fontSize: 12, color: context.nocturne.danger),
    );
  }
}

/// The voice slot at the top of the New record sheet: the one-time tip, first-use setup,
/// the running turn, its outcome, spoken feedback and the error panels.
class VoicePanel extends StatefulWidget {
  const VoicePanel({required this.controller, super.key});

  final VoiceFillController controller;

  @override
  State<VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<VoicePanel> {
  VoiceFillController get c => widget.controller;
  var _heardOpen = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c, c.services.prefs]),
    builder: (context, _) {
      final panel = _panel(context);
      return AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: panel == null
            ? const SizedBox(width: double.infinity)
            : KeyedSubtree(key: const Key('voice-panel'), child: panel),
      );
    },
  );

  Widget? _panel(BuildContext context) => switch (c.phase) {
    VoicePhase.idle => c.services.prefs.tipDismissed ? null : _tip(),
    VoicePhase.primer => VoicePrimerCard(
      onNotNow: c.primerNotNow,
      onContinue: c.primerContinue,
    ),
    VoicePhase.offer => VoiceOfferCard(
      services: c.services,
      error: c.downloadError,
      onLater: c.offerLater,
      onDownload: c.offerDownload,
    ),
    VoicePhase.downloading => _downloading(),
    VoicePhase.listening => _listening(),
    VoicePhase.processing => _processing(),
    VoicePhase.filled => _filled(),
    VoicePhase.need => _need(),
    VoicePhase.exhausted => _exhausted(),
    VoicePhase.followup => _followup(),
    VoicePhase.speaking => _speaking(),
    VoicePhase.error => _error(c.failure ?? VoiceFailureKind.modelLoadFailed),
  };

  Widget _tip() => Container(
    key: const Key('voice-tip'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne),
    child: Row(
      children: [
        Icon(FiIcons.sparkle, size: 20, color: context.nocturne.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.voiceFillByVoice, style: _title),
              const SizedBox(height: 2),
              Text(
                context.l10n.voiceTipLine,
                style: _muted(context.nocturne, .6),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('voice-tip-dismiss'),
          tooltip: context.l10n.voiceDismissTip,
          onPressed: () => c.services.prefs.dismissTip(),
          icon: Icon(
            FiIcons.close,
            size: 18,
            color: context.nocturne.muted(.6),
          ),
        ),
      ],
    ),
  );

  Widget _downloadErrorLine(ModelErrorDto error) {
    final (title, line) = modelFailureText(
      context.l10n,
      c.services.models.status.error == error
          ? c.services.models.status
          : modelStatusOf(ModelStatusKindDto.failed, error: error),
    );
    return Text(
      context.l10n.modelErrorLine(title, line),
      key: const Key('voice-download-error'),
      style: TextStyle(fontSize: 12, color: context.nocturne.danger),
    );
  }

  /// The failure reason alone, under the "Download failed" title.
  Widget _failureReasonLine(ModelErrorDto error) {
    final (_, line) = modelFailureText(
      context.l10n,
      c.services.models.status.error == error
          ? c.services.models.status
          : modelStatusOf(ModelStatusKindDto.failed, error: error),
    );
    return Text(
      line,
      key: const Key('voice-download-error'),
      style: TextStyle(fontSize: 12, color: context.nocturne.danger),
    );
  }

  Widget _downloading() {
    final status = c.services.models.status;
    final progress = status.totalBytes == 0
        ? 0.0
        : status.doneBytes / status.totalBytes;
    final percent = (progress * 100).floor();
    final paused = status.kind == ModelStatusKindDto.paused;
    final stopped = paused || status.kind == ModelStatusKindDto.failed;
    final verifying = status.kind == ModelStatusKindDto.verifying;
    final title = switch (status.kind) {
      ModelStatusKindDto.reconnecting => context.l10n.modelReconnectingShort,
      ModelStatusKindDto.verifying => context.l10n.modelVerifyingTitle,
      ModelStatusKindDto.paused => context.l10n.modelPausedTitle,
      ModelStatusKindDto.failed => context.l10n.modelFailedTitle,
      _ => context.l10n.modelDownloadingTitle,
    };
    final failed = status.kind == ModelStatusKindDto.failed;
    final error = c.downloadError;
    return Container(
      key: const Key('voice-downloading'),
      padding: _panelPadding,
      decoration: _plain(context.nocturne),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Icon(FiIcons.download, size: 18, color: context.nocturne.accent),
              const SizedBox(width: 10),
              Expanded(child: _announced(title)),
              if (stopped)
                OutlinedButton.icon(
                  key: const Key('voice-download-resume'),
                  onPressed: c.resumeDownload,
                  icon: Icon(
                    failed ? FiIcons.refresh : FiIcons.download,
                    size: 16,
                  ),
                  label: Text(
                    failed
                        ? context.l10n.commonRetry
                        : context.l10n.modelResume,
                  ),
                )
              else if (!verifying)
                IconButton(
                  key: const Key('voice-download-pause'),
                  tooltip: context.l10n.modelPauseDownload,
                  onPressed: c.pauseDownload,
                  icon: const Icon(FiIcons.pause, size: 18),
                ),
              IconButton(
                key: const Key('voice-download-hide'),
                tooltip: context.l10n.modelHide,
                onPressed: c.hideDownload,
                icon: Icon(
                  FiIcons.collapse,
                  size: 18,
                  color: context.nocturne.muted(.6),
                ),
              ),
            ],
          ),
          Semantics(
            label: context.l10n.voiceDownloadProgressLabel,
            value: context.l10n.modelPercent(percent),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: verifying ? null : progress,
                minHeight: 4,
                color: stopped || status.kind == ModelStatusKindDto.reconnecting
                    ? context.nocturne.neutralMuted
                    : context.nocturne.accent,
                backgroundColor: context.nocturne.neutralEdge,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  stopped
                      ? context.l10n.modelKeptLine(
                          formatBytes(status.doneBytes),
                          formatBytes(status.totalBytes),
                        )
                      : context.l10n.modelProgressLine(
                          formatBytes(status.doneBytes),
                          formatBytes(status.totalBytes),
                          percent,
                        ),
                  key: const Key('voice-download-progress'),
                  style: _muted(
                    context.nocturne,
                    .6,
                  ).copyWith(fontFeatures: Nocturne.tabular),
                ),
              ),
              if (status.secondsLeft case final seconds? when !stopped)
                Text(
                  formatTimeLeft(context.l10n, seconds),
                  style: _muted(context.nocturne, .6),
                ),
            ],
          ),
          if (status.kind == ModelStatusKindDto.reconnecting)
            Text(
              context.l10n.modelReconnectingResumesLong,
              key: const Key('voice-download-reconnecting'),
              style: _muted(context.nocturne, .6),
            ),
          if (error != null)
            failed ? _failureReasonLine(error) : _downloadErrorLine(error),
          Text(
            context.l10n.modelKeepFilling,
            style: _muted(context.nocturne, .55),
          ),
        ],
      ),
    );
  }

  Widget _listening() {
    final seconds = c.elapsed.inSeconds;
    final timer =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final example = exampleUtterance(c.fields, language: c.services.language);
    return Container(
      key: const Key('voice-listening'),
      padding: const EdgeInsets.all(14),
      decoration: _glow(
        context.nocturne,
        center: Alignment.topCenter,
        radius: 1.6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.nocturne.accent,
                  boxShadow: [
                    BoxShadow(
                      color: context.nocturne.accentFill,
                      spreadRadius: 4,
                    ),
                    BoxShadow(color: context.nocturne.accent, blurRadius: 10),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _announced(context.l10n.voiceListening)),
              Text(
                timer,
                key: const Key('voice-timer'),
                style: TextStyle(
                  fontFamily: Nocturne.monoFamily,
                  fontSize: 13,
                  color: context.nocturne.accentInk,
                ),
              ),
            ],
          ),
          ExcludeSemantics(child: _LevelBars(levels: c.levels)),
          if (example.isNotEmpty)
            Text.rich(
              key: const Key('voice-example'),
              TextSpan(
                children: [
                  for (final (index, part)
                      in context.l10n
                          .voiceTry('\u0000')
                          .split('\u0000')
                          .indexed)
                    if (index == 0)
                      TextSpan(text: part)
                    else ...[
                      TextSpan(
                        text: example,
                        style: TextStyle(
                          color: context.nocturne.accentInkStrong,
                        ),
                      ),
                      TextSpan(text: part),
                    ],
                ],
              ),
              style: _muted(context.nocturne, .7, 13),
            ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      context.l10n.voiceListeningHint,
                      style: _muted(context.nocturne, .55),
                    ),
                    Text(
                      context.l10n.voiceListeningCap(maxTurnDuration.inSeconds),
                      key: const Key('voice-listening-cap'),
                      style: _muted(context.nocturne, .45, 11),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('voice-cancel'),
                onPressed: c.cancel,
                child: Text(context.l10n.commonCancel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _processing() {
    final transcribed = c.stage == ProcessingStage.filling;
    Widget step(String label, {required bool done, required bool active}) =>
        Row(
          children: [
            if (done)
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.nocturne.neutralFillStrong,
                ),
                child: const Icon(FiIcons.check, size: 11),
              )
            else if (active)
              const VoiceProgressRing()
            else
              const SizedBox.square(dimension: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                color: done
                    ? context.nocturne.muted(.6)
                    : context.nocturne.text,
              ),
            ),
          ],
        );
    return Container(
      key: const Key('voice-processing'),
      padding: const EdgeInsets.all(14),
      decoration: _plain(context.nocturne, outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Semantics(
            liveRegion: true,
            label: transcribed
                ? context.l10n.voiceFillingFields
                : context.l10n.voiceTranscribing,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                step(
                  transcribed
                      ? context.l10n.voiceTranscribed
                      : context.l10n.voiceTranscribingStep,
                  done: transcribed,
                  active: !transcribed,
                ),
                if (transcribed)
                  step(
                    context.l10n.voiceFillingFieldsStep,
                    done: false,
                    active: true,
                  ),
              ],
            ),
          ),
          if (c.pendingTranscript case final transcript?)
            Container(
              key: const Key('voice-transcript'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: context.nocturne.surface,
                borderRadius: BorderRadius.circular(Nocturne.radiusSm),
              ),
              child: Text(
                context.l10n.voiceQuotedTranscript(transcript),
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.voiceUsuallySeconds,
                  style: _muted(context.nocturne, .55),
                ),
              ),
              TextButton(
                key: const Key('voice-cancel'),
                onPressed: c.cancel,
                child: Text(context.l10n.commonCancel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The read-only Heard block of the Nothing matched panel (mock voice-errors).
  Widget _failedHeard(String transcript) => Container(
    key: const Key('voice-error-heard'),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: context.nocturne.neutralFillStrong,
      borderRadius: BorderRadius.circular(Nocturne.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        ExcludeSemantics(
          child: Row(
            children: [
              Icon(FiIcons.voice, size: 12, color: context.nocturne.accent),
              const SizedBox(width: 6),
              Text(
                context.l10n.voiceHeardCaps,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: .66,
                  color: context.nocturne.muted(.55),
                ),
              ),
            ],
          ),
        ),
        Text(
          context.l10n.voiceQuotedTranscript(transcript),
          semanticsLabel: '${context.l10n.voiceHeard}: $transcript',
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
      ],
    ),
  );

  Widget _heardToggle() => TextButton.icon(
    key: const Key('voice-heard'),
    onPressed: () => setState(() => _heardOpen = !_heardOpen),
    iconAlignment: IconAlignment.end,
    icon: Icon(_heardOpen ? FiIcons.collapse : FiIcons.expand, size: 14),
    label: Text(
      context.l10n.voiceHeard,
      style: TextStyle(color: context.nocturne.muted(.65)),
    ),
  );

  Widget _heardList() => Padding(
    key: const Key('voice-heard-list'),
    padding: const EdgeInsets.only(left: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        for (final (index, transcript) in c.heard.indexed)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${_ordinal(context.l10n, index + 1).toUpperCase()} ',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .66,
                    color: context.nocturne.muted(.55),
                  ),
                ),
                TextSpan(text: '“$transcript”'),
              ],
            ),
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: index == c.heard.length - 1
                  ? null
                  : context.nocturne.muted(.55),
            ),
          ),
      ],
    ),
  );

  Widget _headline(IconData icon, String text, {Widget? trailing}) => Row(
    children: [
      Icon(icon, size: 18, color: context.nocturne.accent),
      const SizedBox(width: 10),
      Expanded(child: _announced(text, key: const Key('voice-headline'))),
      ?trailing,
    ],
  );

  Widget? _keptLine() => c.lastKeptTyped.isEmpty
      ? null
      : Text(
          context.l10n.voiceKept(
            c.lastKeptTyped.length,
            c.namesOf(c.lastKeptTyped),
          ),
          key: const Key('voice-kept'),
          style: _muted(context.nocturne, .55),
        );

  String _filledCount(int n) => context.l10n.voiceFilledCount(n);

  Widget _speakAgain(String label) => OutlinedButton.icon(
    key: const Key('voice-speak-again'),
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
    onPressed: c.begin,
    icon: const Icon(FiIcons.microphone, size: 18),
    label: Text(label),
  );

  Widget _filled() => Container(
    key: const Key('voice-filled'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _headline(
          FiIcons.sparkle,
          _filledCount(c.lastApplied.length),
          trailing: _heardToggle(),
        ),
        if (_heardOpen) _heardList(),
        ?_keptLine(),
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.voiceCheckThenSave,
                style: _muted(context.nocturne, .55),
              ),
            ),
            _speakAgain(context.l10n.voiceSpeakAgain),
          ],
        ),
      ],
    ),
  );

  Widget _need() => Container(
    key: const Key('voice-need'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne, outlined: true),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _headline(
          FiIcons.needed,
          c.stillNeedLine,
          trailing: Text(
            context.l10n.voiceRound(c.round, maxAskingRounds),
            key: const Key('voice-round'),
            style: _muted(context.nocturne, .5, 11),
          ),
        ),
        Text(
          context.l10n.voiceNeedLine(_filledCount(c.lastApplied.length)),
          style: _muted(context.nocturne, .6),
        ),
        ?_keptLine(),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('voice-answer'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: c.begin,
            icon: const Icon(FiIcons.microphone, size: 18),
            label: Text(context.l10n.voiceAnswerByVoice),
          ),
        ),
      ],
    ),
  );

  Widget _exhausted() => Container(
    key: const Key('voice-exhausted'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _headline(
          FiIcons.needed,
          context.l10n.voiceCouldntGet(
            c.missingRequired.map((field) => field.name).join(', '),
          ),
        ),
        Text(
          context.l10n.voiceExhaustedLine,
          style: _muted(context.nocturne, .6),
        ),
      ],
    ),
  );

  Widget _followup() => Container(
    key: const Key('voice-followup'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _headline(
          FiIcons.sparkle,
          context.l10n.voiceUpdated(c.namesOf(c.lastApplied)),
          trailing: _heardToggle(),
        ),
        if (_heardOpen) _heardList(),
        ?_keptLine(),
      ],
    ),
  );

  Widget _speaking() => Container(
    key: const Key('voice-speaking'),
    padding: _panelPadding,
    decoration: _plain(context.nocturne, outlined: true),
    child: Row(
      children: [
        const ExcludeSemantics(child: _SpeakingBars()),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.voiceSpeaking,
                style: TextStyle(
                  fontSize: 12,
                  color: context.nocturne.accentInk,
                ),
              ),
              const SizedBox(height: 2),
              Text(c.spokenLine ?? '', style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
        IconButton(
          key: const Key('voice-mute'),
          tooltip: context.l10n.voiceMute,
          onPressed: c.muteSpeech,
          icon: const Icon(FiIcons.mute, size: 20),
        ),
      ],
    ),
  );

  Widget _error(VoiceFailureKind kind) {
    final openSettings = VoiceScope.openSettingsOf(context);
    final l = context.l10n;
    Widget text(String label, VoidCallback? onPressed, String key) =>
        TextButton(key: Key(key), onPressed: onPressed, child: Text(label));
    Widget primary(String label, VoidCallback? onPressed, String key) =>
        OutlinedButton(
          key: Key(key),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: onPressed,
          child: Text(label),
        );
    final actions = switch (kind) {
      VoiceFailureKind.noSpeech => [
        text(l.voiceDismiss, c.dismissError, 'voice-error-dismiss'),
        primary(l.commonTryAgain, c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.nothingMatched ||
      VoiceFailureKind.micBusy ||
      VoiceFailureKind.lowMemory ||
      VoiceFailureKind.cancelled => [
        primary(l.commonTryAgain, c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.permissionDenied => [
        text(l.voiceNotNow, c.dismissError, 'voice-error-dismiss'),
        primary(
          l.voiceOpenSettings,
          c.openPermissionSettings,
          'voice-error-open-settings',
        ),
      ],
      VoiceFailureKind.modelLoadFailed => [
        text(l.voiceSettings, () {
          c.dismissError();
          Navigator.maybePop(context);
          openSettings?.call();
        }, 'voice-error-settings'),
        primary(l.commonRetry, c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.interruptedBackground ||
      VoiceFailureKind.interruptedCall => [
        primary(l.voiceSpeakAgain, c.retry, 'voice-error-retry'),
      ],
    };
    return VoiceErrorCard(
      kind: kind,
      actions: actions,
      extra: kind == VoiceFailureKind.nothingMatched
          ? switch (c.failedTranscript) {
              final transcript? => _failedHeard(transcript),
              null => null,
            }
          : null,
    );
  }
}

/// A voice error panel: icon, title, line and actions (mock voice-errors).
class VoiceErrorCard extends StatelessWidget {
  const VoiceErrorCard({
    required this.kind,
    required this.actions,
    this.extra,
    super.key,
  });

  final VoiceFailureKind kind;
  final List<Widget> actions;

  /// Shown between the line and the actions.
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final copy = voiceErrorCopy(context.l10n, kind);
    return Container(
      key: Key('voice-error-${kind.name}'),
      padding: _panelPadding,
      decoration: _plain(context.nocturne, outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(copy.icon, size: 18, color: context.nocturne.danger),
              const SizedBox(width: 10),
              Expanded(child: _announced(copy.title)),
            ],
          ),
          Text(copy.line, style: _muted(context.nocturne, .6, 13)),
          ?extra,
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: actions,
          ),
        ],
      ),
    );
  }
}

/// Title, line and icon of each voice error panel (mock voice-errors).
({IconData icon, String title, String line}) voiceErrorCopy(
  AppLocalizations l,
  VoiceFailureKind kind,
) => switch (kind) {
  VoiceFailureKind.noSpeech => (
    icon: FiIcons.noSpeech,
    title: l.voiceErrorNoSpeechTitle,
    line: l.voiceErrorNoSpeechLine,
  ),
  VoiceFailureKind.nothingMatched => (
    icon: FiIcons.nothingMatched,
    title: l.voiceErrorNothingMatchedTitle,
    line: l.voiceErrorNothingMatchedLine,
  ),
  VoiceFailureKind.permissionDenied => (
    icon: FiIcons.microphoneOff,
    title: l.voiceErrorPermissionDeniedTitle,
    line: l.voiceErrorPermissionDeniedLine,
  ),
  VoiceFailureKind.micBusy => (
    icon: FiIcons.microphoneBusy,
    title: l.voiceErrorMicBusyTitle,
    line: l.voiceErrorMicBusyLine,
  ),
  VoiceFailureKind.modelLoadFailed => (
    icon: FiIcons.modelBroken,
    title: l.voiceErrorModelLoadFailedTitle,
    line: l.voiceErrorModelLoadFailedLine,
  ),
  VoiceFailureKind.lowMemory => (
    icon: FiIcons.lowMemory,
    title: l.voiceErrorLowMemoryTitle,
    line: l.voiceErrorLowMemoryLine,
  ),
  VoiceFailureKind.interruptedBackground => (
    icon: FiIcons.backgrounded,
    title: l.voiceErrorInterruptedBackgroundTitle,
    line: l.voiceErrorInterruptedBackgroundLine,
  ),
  VoiceFailureKind.interruptedCall => (
    icon: FiIcons.callInterrupted,
    title: l.voiceErrorInterruptedCallTitle,
    line: l.voiceErrorInterruptedCallLine,
  ),
  VoiceFailureKind.cancelled => (
    icon: FiIcons.info,
    title: l.voiceErrorCancelledTitle,
    line: l.voiceErrorCancelledLine,
  ),
};

/// 28 accent bars following the latest input levels.
class _LevelBars extends StatelessWidget {
  const _LevelBars({required this.levels});

  final List<double> levels;

  static const count = 28;

  @override
  Widget build(BuildContext context) {
    final recent = levels.length > count
        ? levels.sublist(levels.length - count)
        : levels;
    return SizedBox(
      key: const Key('voice-levels'),
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 3,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: 4,
              height:
                  4 +
                  34 *
                      (i < count - recent.length
                          ? 0
                          : recent[i - (count - recent.length)]),
              decoration: BoxDecoration(
                color: context.nocturne.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeakingBars extends StatelessWidget {
  const _SpeakingBars();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 20,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final height in const [8.0, 16.0, 11.0, 18.0])
          Container(
            width: 3,
            height: height,
            decoration: BoxDecoration(
              color: context.nocturne.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    ),
  );
}

/// The "Heard" popover under a voice-filled field's label: the transcript with the evidence
/// words highlighted, "Clear field" and "Done". Inline, so it scrolls with the form.
class VoiceEvidencePopover extends StatelessWidget {
  const VoiceEvidencePopover({
    required this.transcript,
    required this.evidence,
    required this.onClear,
    required this.onDone,
    super.key,
  });

  final String transcript;
  final String evidence;
  final VoidCallback onClear;
  final VoidCallback onDone;

  /// Splits [transcript] around the first case-insensitive match of [evidence].
  static (String, String, String) split(String transcript, String evidence) {
    final at = transcript.toLowerCase().indexOf(evidence.toLowerCase());
    if (at < 0 || evidence.isEmpty) return (transcript, '', '');
    return (
      transcript.substring(0, at),
      transcript.substring(at, at + evidence.length),
      transcript.substring(at + evidence.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (before, match, after) = split(transcript, evidence);
    return Semantics(
      container: true,
      label: context.l10n.voiceWhatWasHeard,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: context.nocturne.neutralFillStrong,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          boxShadow: context.nocturne.shadowMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Row(
              children: [
                Icon(FiIcons.voice, size: 12, color: context.nocturne.accent),
                const SizedBox(width: 6),
                Text(
                  context.l10n.voiceHeardCaps,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .66,
                    color: context.nocturne.muted(.55),
                  ),
                ),
              ],
            ),
            Text.rich(
              key: const Key('voice-evidence-text'),
              TextSpan(
                children: [
                  TextSpan(text: '“$before'),
                  TextSpan(
                    text: match,
                    style: TextStyle(
                      color: context.nocturne.accentInkStrong,
                      backgroundColor: context.nocturne.accentFill,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  TextSpan(text: '$after”'),
                ],
              ),
              style: const TextStyle(fontSize: 14, height: 1.45),
            ),
            Row(
              children: [
                TextButton(
                  key: const Key('voice-evidence-clear'),
                  onPressed: onClear,
                  child: Text(context.l10n.voiceClearField),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('voice-evidence-done'),
                  onPressed: onDone,
                  child: Text(context.l10n.commonDone),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws a field control's voice or needed marking: an accent-900 tint with an accent-700
/// border when filled by voice, a dashed accent border when needed.
class VoiceFieldMark extends StatelessWidget {
  const VoiceFieldMark({
    required this.child,
    this.voice = false,
    this.needed = false,
    super.key,
  });

  final Widget child;
  final bool voice;
  final bool needed;

  @override
  Widget build(BuildContext context) {
    if (!voice && !needed) return child;
    return CustomPaint(
      painter: voice ? _TintPainter(context.nocturne) : null,
      foregroundPainter: _BorderPainter(
        dashed: needed && !voice,
        colors: context.nocturne,
      ),
      child: child,
    );
  }
}

class _TintPainter extends CustomPainter {
  const _TintPainter(this.colors);

  final NocturneColors colors;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRRect(
    RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(Nocturne.radius),
    ),
    Paint()..color = colors.accentFill,
  );

  @override
  bool shouldRepaint(_TintPainter oldDelegate) => oldDelegate.colors != colors;
}

class _BorderPainter extends CustomPainter {
  const _BorderPainter({required this.dashed, required this.colors});

  final bool dashed;
  final NocturneColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dashed ? colors.accent : colors.accentEdge;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(Nocturne.radius),
        ),
      );
    if (!dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 8) {
        canvas.drawPath(metric.extractPath(d, d + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BorderPainter oldDelegate) =>
      oldDelegate.dashed != dashed;
}
