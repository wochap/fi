import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/voice/controller.dart';
import 'package:fi/voice/engine.dart';
import 'package:fi/voice/example.dart';
import 'package:fi/voice/mic_button.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

const _panelPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

BoxDecoration _plain({bool outlined = false}) => BoxDecoration(
  color: Nocturne.bg,
  borderRadius: BorderRadius.circular(Nocturne.radius),
  border: outlined ? Border.all(color: Nocturne.accent700) : null,
);

/// The `nocturneGlow` of the primer and listening panels: accent900 fading into bg.
BoxDecoration _glow({required AlignmentGeometry center, double radius = 1}) =>
    BoxDecoration(
      gradient: RadialGradient(
        center: center,
        radius: radius,
        colors: const [Nocturne.accent900, Nocturne.bg],
        stops: const [0, .65],
      ),
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: Border.all(color: Nocturne.accent700),
    );

TextStyle _muted(double opacity, [double size = 12]) =>
    TextStyle(fontSize: size, color: Nocturne.muted(opacity), height: 1.4);

const _title = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

/// A panel title announced to screen readers when it appears.
Widget _announced(String text, {TextStyle style = _title, Key? key}) =>
    Semantics(
      liveRegion: true,
      child: Text(text, key: key, style: style),
    );

String _ordinal(int n) => switch (n) {
  1 => '1st',
  2 => '2nd',
  3 => '3rd',
  _ => '${n}th',
};

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
  NetworkKind? _network;
  int? _freeBytes;
  var _offerLoaded = false;

  Future<void> _loadOffer() async {
    _offerLoaded = true;
    final network = await c.services.network.current();
    final free = await c.services.models.freeStorageBytes();
    if (!mounted) return;
    setState(() {
      _network = network;
      _freeBytes = free;
    });
  }

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
    VoicePhase.primer => _primer(),
    VoicePhase.offer => _offer(),
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
    decoration: _plain(),
    child: Row(
      children: [
        const Icon(FiIcons.sparkle, size: 20, color: Nocturne.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Fill by voice', style: _title),
              const SizedBox(height: 2),
              Text(
                'Tap the mic below and say the details. You review before saving.',
                style: _muted(.6),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('voice-tip-dismiss'),
          tooltip: 'Dismiss tip',
          onPressed: () => c.services.prefs.dismissTip(),
          icon: Icon(FiIcons.close, size: 18, color: Nocturne.muted(.6)),
        ),
      ],
    ),
  );

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

  Widget _primer() => Container(
    key: const Key('voice-primer'),
    padding: const EdgeInsets.all(16),
    decoration: _glow(center: Alignment.topLeft, radius: 1.4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Nocturne.accent),
          ),
          child: const Icon(
            FiIcons.microphone,
            size: 22,
            color: Nocturne.accent,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            _announced(
              'Speak to fill records',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            Text(
              'Audio is processed on this device and never saved. English only for now.',
              style: _muted(.7, 13),
            ),
          ],
        ),
        Text(
          'Next, Android will ask for microphone access.',
          style: _muted(.55),
        ),
        _twoButtons(
          secondaryKey: const Key('voice-primer-not-now'),
          secondary: 'Not now',
          onSecondary: c.primerNotNow,
          primaryKey: const Key('voice-primer-continue'),
          primary: 'Continue',
          onPrimary: c.primerContinue,
        ),
      ],
    ),
  );

  Widget _offer() {
    if (!_offerLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadOffer());
    }
    final size = formatBytes(c.services.models.status.remainingBytes);
    final mobile = _network == NetworkKind.mobile;
    final error = c.downloadError;
    return Container(
      key: const Key('voice-offer'),
      padding: const EdgeInsets.all(16),
      decoration: _plain(outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            children: [
              const Icon(FiIcons.download, size: 22, color: Nocturne.accent),
              const SizedBox(width: 10),
              Expanded(
                child: _announced(
                  'Download voice model',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          Text(
            'A one-time $size download so speech can be understood on this phone.',
            style: _muted(.7, 13),
          ),
          Column(
            spacing: 6,
            children: [
              if (_network != null)
                _infoRow(
                  key: const Key('voice-offer-network'),
                  icon: mobile ? FiIcons.mobileData : FiIcons.wifi,
                  iconColor: mobile ? Nocturne.accent300 : Nocturne.muted(.7),
                  text: mobile ? "You're on mobile data" : "You're on Wi-Fi",
                  trailing: mobile ? 'Wi-Fi recommended' : null,
                  trailingColor: Nocturne.accent300,
                ),
              _infoRow(
                key: const Key('voice-offer-storage'),
                icon: FiIcons.storage,
                iconColor: Nocturne.muted(.7),
                text: 'Storage',
                trailing: _freeBytes == null
                    ? null
                    : '${formatBytes(_freeBytes!)} free',
                trailingColor: Nocturne.muted(.6),
              ),
            ],
          ),
          if (error != null) _downloadErrorLine(error),
          _twoButtons(
            secondaryKey: const Key('voice-offer-later'),
            secondary: 'Later',
            onSecondary: c.offerLater,
            primaryKey: const Key('voice-offer-download'),
            primary: 'Download',
            primaryIcon: FiIcons.download,
            onPrimary: c.offerDownload,
          ),
        ],
      ),
    );
  }

  Widget _downloadErrorLine(ModelErrorDto error) => Text(
    switch (error.kind) {
      ModelErrorKindDto.notEnoughStorage =>
        'Not enough storage: free up ${formatBytes(error.neededBytes ?? 0)} and try again.',
      ModelErrorKindDto.checksum =>
        'The download was damaged and was removed. Try again.',
      ModelErrorKindDto.network ||
      ModelErrorKindDto.httpStatus => "Couldn't reach the download. Try again.",
      _ => "Couldn't download the voice model. Try again.",
    },
    key: const Key('voice-download-error'),
    style: const TextStyle(fontSize: 12, color: Nocturne.error),
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

  Widget _downloading() {
    final status = c.services.models.status;
    final progress = status.totalBytes == 0
        ? 0.0
        : status.doneBytes / status.totalBytes;
    final percent = (progress * 100).floor();
    final paused = status.kind == ModelStatusKindDto.paused;
    final error = c.downloadError;
    return Container(
      key: const Key('voice-downloading'),
      padding: _panelPadding,
      decoration: _plain(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              const Icon(FiIcons.download, size: 18, color: Nocturne.accent),
              const SizedBox(width: 10),
              Expanded(
                child: _announced(
                  paused ? 'Download paused' : 'Downloading voice model',
                ),
              ),
              IconButton(
                key: const Key('voice-download-pause'),
                tooltip: paused ? 'Resume download' : 'Pause download',
                onPressed: paused ? c.resumeDownload : c.pauseDownload,
                icon: Icon(paused ? FiIcons.download : FiIcons.pause, size: 18),
              ),
              IconButton(
                key: const Key('voice-download-hide'),
                tooltip: 'Hide',
                onPressed: c.hideDownload,
                icon: Icon(
                  FiIcons.collapse,
                  size: 18,
                  color: Nocturne.muted(.6),
                ),
              ),
            ],
          ),
          Semantics(
            label: 'Download progress',
            value: '$percent%',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: Nocturne.accent,
                backgroundColor: Nocturne.neutral700,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatBytes(status.doneBytes)} of ${formatBytes(status.totalBytes)} · $percent%',
                  key: const Key('voice-download-progress'),
                  style: _muted(.6).copyWith(fontFeatures: Nocturne.tabular),
                ),
              ),
              if (status.secondsLeft case final seconds? when !paused)
                Text(formatTimeLeft(seconds), style: _muted(.6)),
            ],
          ),
          if (error != null) _downloadErrorLine(error),
          Text(
            "Keep filling by hand. The mic turns on when it's ready.",
            style: _muted(.55),
          ),
        ],
      ),
    );
  }

  Widget _listening() {
    final seconds = c.elapsed.inSeconds;
    final timer =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final example = exampleUtterance(c.fields);
    return Container(
      key: const Key('voice-listening'),
      padding: const EdgeInsets.all(14),
      decoration: _glow(center: Alignment.topCenter, radius: 1.6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Nocturne.accent,
                  boxShadow: [
                    BoxShadow(color: Nocturne.accent900, spreadRadius: 4),
                    BoxShadow(color: Nocturne.accent, blurRadius: 10),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _announced('Listening')),
              Text(
                timer,
                key: const Key('voice-timer'),
                style: const TextStyle(
                  fontFamily: Nocturne.monoFamily,
                  fontSize: 13,
                  color: Nocturne.accent200,
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
                  const TextSpan(text: 'Try: '),
                  TextSpan(
                    text: '“$example”',
                    style: const TextStyle(color: Nocturne.accent100),
                  ),
                ],
              ),
              style: _muted(.7, 13),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tap stop when done, or hold the mic to talk',
                  style: _muted(.55),
                ),
              ),
              TextButton(
                key: const Key('voice-cancel'),
                onPressed: c.cancel,
                child: const Text('Cancel'),
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
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Nocturne.neutral800,
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
                color: done ? Nocturne.muted(.6) : Nocturne.text,
              ),
            ),
          ],
        );
    return Container(
      key: const Key('voice-processing'),
      padding: const EdgeInsets.all(14),
      decoration: _plain(outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Semantics(
            liveRegion: true,
            label: transcribed ? 'Filling fields' : 'Transcribing',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                step(
                  transcribed ? 'Transcribed' : 'Transcribing…',
                  done: transcribed,
                  active: !transcribed,
                ),
                if (transcribed)
                  step('Filling fields…', done: false, active: true),
              ],
            ),
          ),
          if (c.pendingTranscript case final transcript?)
            Container(
              key: const Key('voice-transcript'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Nocturne.surface,
                borderRadius: BorderRadius.circular(Nocturne.radiusSm),
              ),
              child: Text(
                '“$transcript”',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ),
          Row(
            children: [
              Expanded(child: Text('Usually 4–8 seconds', style: _muted(.55))),
              TextButton(
                key: const Key('voice-cancel'),
                onPressed: c.cancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heardToggle() => TextButton.icon(
    key: const Key('voice-heard'),
    onPressed: () => setState(() => _heardOpen = !_heardOpen),
    iconAlignment: IconAlignment.end,
    icon: Icon(_heardOpen ? FiIcons.collapse : FiIcons.expand, size: 14),
    label: Text('Heard', style: TextStyle(color: Nocturne.muted(.65))),
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
                  text: '${_ordinal(index + 1).toUpperCase()} ',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .66,
                    color: Nocturne.muted(.55),
                  ),
                ),
                TextSpan(text: '“$transcript”'),
              ],
            ),
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: index == c.heard.length - 1 ? null : Nocturne.muted(.55),
            ),
          ),
      ],
    ),
  );

  Widget _headline(IconData icon, String text, {Widget? trailing}) => Row(
    children: [
      Icon(icon, size: 18, color: Nocturne.accent),
      const SizedBox(width: 10),
      Expanded(child: _announced(text, key: const Key('voice-headline'))),
      ?trailing,
    ],
  );

  Widget? _keptLine() => c.lastKeptTyped.isEmpty
      ? null
      : Text(
          'Your ${c.lastKeptTyped.length == 1 ? 'edit' : 'edits'} to ${c.namesOf(c.lastKeptTyped)} '
          '${c.lastKeptTyped.length == 1 ? 'was' : 'were'} kept.',
          key: const Key('voice-kept'),
          style: _muted(.55),
        );

  String _filledCount(int n) => 'Filled $n ${n == 1 ? 'field' : 'fields'}';

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
    decoration: _plain(),
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
              child: Text('Check the fields, then save.', style: _muted(.55)),
            ),
            _speakAgain('Speak again'),
          ],
        ),
      ],
    ),
  );

  Widget _need() => Container(
    key: const Key('voice-need'),
    padding: _panelPadding,
    decoration: _plain(outlined: true),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _headline(
          FiIcons.needed,
          c.stillNeedLine,
          trailing: Text(
            '${c.round} of $maxAskingRounds',
            key: const Key('voice-round'),
            style: _muted(.5, 11),
          ),
        ),
        Text(
          '${_filledCount(c.lastApplied.length)}. Say the rest, or type into the marked fields.',
          style: _muted(.6),
        ),
        ?_keptLine(),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('voice-answer'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: c.begin,
            icon: const Icon(FiIcons.microphone, size: 18),
            label: const Text('Answer by voice'),
          ),
        ),
      ],
    ),
  );

  Widget _exhausted() => Container(
    key: const Key('voice-exhausted'),
    padding: _panelPadding,
    decoration: _plain(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _headline(
          FiIcons.needed,
          "Couldn't get the ${c.missingRequired.map((field) => field.name).join(', ')}",
        ),
        Text(
          'Type it in the marked field, then save. The mic still works if you want to try again.',
          style: _muted(.6),
        ),
      ],
    ),
  );

  Widget _followup() => Container(
    key: const Key('voice-followup'),
    padding: _panelPadding,
    decoration: _plain(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _headline(
          FiIcons.sparkle,
          'Updated ${c.namesOf(c.lastApplied)}',
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
    decoration: _plain(outlined: true),
    child: Row(
      children: [
        const ExcludeSemantics(child: _SpeakingBars()),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Speaking',
                style: TextStyle(fontSize: 12, color: Nocturne.accent200),
              ),
              const SizedBox(height: 2),
              Text(c.spokenLine ?? '', style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
        IconButton(
          key: const Key('voice-mute'),
          tooltip: 'Mute spoken feedback',
          onPressed: c.muteSpeech,
          icon: const Icon(FiIcons.mute, size: 20),
        ),
      ],
    ),
  );

  Widget _error(VoiceFailureKind kind) {
    final openSettings = VoiceScope.openSettingsOf(context);
    final copy = voiceErrorCopy(kind);
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
        text('Dismiss', c.dismissError, 'voice-error-dismiss'),
        primary('Try again', c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.nothingMatched ||
      VoiceFailureKind.micBusy ||
      VoiceFailureKind.lowMemory ||
      VoiceFailureKind.cancelled => [
        primary('Try again', c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.permissionDenied => [
        text('Not now', c.dismissError, 'voice-error-dismiss'),
        primary(
          'Open settings',
          c.openPermissionSettings,
          'voice-error-open-settings',
        ),
      ],
      VoiceFailureKind.modelLoadFailed => [
        text('Settings', () {
          c.dismissError();
          Navigator.maybePop(context);
          openSettings?.call();
        }, 'voice-error-settings'),
        primary('Retry', c.retry, 'voice-error-retry'),
      ],
      VoiceFailureKind.interruptedBackground ||
      VoiceFailureKind.interruptedCall => [
        primary('Speak again', c.retry, 'voice-error-retry'),
      ],
    };
    return Container(
      key: Key('voice-error-${kind.name}'),
      padding: _panelPadding,
      decoration: _plain(outlined: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(copy.icon, size: 18, color: Nocturne.accent),
              const SizedBox(width: 10),
              Expanded(child: _announced(copy.title)),
            ],
          ),
          Text(copy.line, style: _muted(.6, 13)),
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

/// Title, line and icon of each voice error panel (mock 7j).
({IconData icon, String title, String line}) voiceErrorCopy(
  VoiceFailureKind kind,
) => switch (kind) {
  VoiceFailureKind.noSpeech => (
    icon: FiIcons.noSpeech,
    title: "Didn't hear anything",
    line: "Check the mic isn't covered, then try again.",
  ),
  VoiceFailureKind.nothingMatched => (
    icon: FiIcons.nothingMatched,
    title: 'Nothing matched',
    line:
        "I couldn't match anything to this collection's fields. Try naming a field, like “amount 12.50”.",
  ),
  VoiceFailureKind.permissionDenied => (
    icon: FiIcons.microphoneOff,
    title: 'Microphone access is off',
    line:
        'Allow microphone access in Android settings to fill by voice. You can keep typing.',
  ),
  VoiceFailureKind.micBusy => (
    icon: FiIcons.microphoneBusy,
    title: 'Microphone is busy',
    line: 'Another app is using the microphone. Close it, then try again.',
  ),
  VoiceFailureKind.modelLoadFailed => (
    icon: FiIcons.modelBroken,
    title: "Voice model couldn't load",
    line:
        'The model file may be damaged. Retry, or re-download it in Settings.',
  ),
  VoiceFailureKind.lowMemory => (
    icon: FiIcons.lowMemory,
    title: 'Not enough memory',
    line: 'Close other apps and try again. Your form is kept.',
  ),
  VoiceFailureKind.interruptedBackground => (
    icon: FiIcons.backgrounded,
    title: 'Recording stopped',
    line: 'Fi went to the background, so recording stopped. Nothing was kept.',
  ),
  VoiceFailureKind.interruptedCall => (
    icon: FiIcons.callInterrupted,
    title: 'Stopped for a call',
    line: 'Recording stopped when a call came in. Nothing was kept.',
  ),
  VoiceFailureKind.cancelled => (
    icon: FiIcons.info,
    title: 'Stopped',
    line: 'Nothing was kept.',
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
                color: Nocturne.accent,
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
              color: Nocturne.accent,
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
      label: 'What was heard',
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: Nocturne.neutral800,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          boxShadow: Nocturne.shadowMd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Row(
              children: [
                const Icon(FiIcons.voice, size: 12, color: Nocturne.accent),
                const SizedBox(width: 6),
                Text(
                  'HEARD',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .66,
                    color: Nocturne.muted(.55),
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
                    style: const TextStyle(
                      color: Nocturne.accent100,
                      backgroundColor: Nocturne.accent900,
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
                  child: const Text('Clear field'),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('voice-evidence-done'),
                  onPressed: onDone,
                  child: const Text('Done'),
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
      painter: voice ? const _TintPainter() : null,
      foregroundPainter: _BorderPainter(dashed: needed && !voice),
      child: child,
    );
  }
}

class _TintPainter extends CustomPainter {
  const _TintPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRRect(
    RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(Nocturne.radius),
    ),
    Paint()..color = Nocturne.accent900,
  );

  @override
  bool shouldRepaint(_TintPainter oldDelegate) => false;
}

class _BorderPainter extends CustomPainter {
  const _BorderPainter({required this.dashed});

  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dashed ? Nocturne.accent : Nocturne.accent700;
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
