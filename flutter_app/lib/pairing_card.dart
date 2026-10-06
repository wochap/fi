import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/controllers.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/reset_dialog.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';

/// The one pairing surface, shared by onboarding and the devices screen.
///
/// The SAS is rendered exactly as Rust supplies it; this widget never
/// computes or reformats it beyond the fixed six-digit zero padding.
class PairingCard extends StatelessWidget {
  const PairingCard({required this.controller, this.onResetDataset, super.key});
  final DevicesController controller;

  /// Offered on the root-mismatch outcome; the only way past that dead end.
  final ResetDatasetAction? onResetDataset;

  static const _title = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 520;
      final idle = controller.pairing.kind == PairingKindDto.idle;
      return Container(
        key: const Key('pairing-card'),
        padding: compact
            ? const EdgeInsets.all(16)
            : const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          gradient: nocturneGlow(rx: .9, ry: 1.8, stop: .55),
          borderRadius: BorderRadius.circular(Nocturne.radius),
          border: Border.all(color: Nocturne.neutral800),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 13, color: Nocturne.muted(.8)),
          child: idle
              ? _idle(context, compact)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_ownHeading) ...[
                      _heading(context, compact),
                      const SizedBox(height: 12),
                    ],
                    ..._content(context),
                  ],
                ),
        ),
      );
    },
  );

  Widget _mark(bool compact) => compact
      ? const Icon(FiIcons.link, size: 20, color: Nocturne.accent)
      : const IconTile(
          FiIcons.link,
          size: 44,
          fill: null,
          outline: Nocturne.accent700,
          color: Nocturne.accent,
        );

  Widget _heading(BuildContext context, bool compact) => Row(
    children: [
      _mark(compact),
      SizedBox(width: compact ? 10 : 16),
      Expanded(child: Text(context.l10n.pairingTitle, style: _title)),
    ],
  );

  Widget _startButton(BuildContext context, {required bool block}) =>
      FilledButton.icon(
        key: const Key('start-pairing'),
        style: block
            ? FilledButton.styleFrom(minimumSize: const Size(0, 46))
            : null,
        onPressed: controller.busy ? null : controller.beginPairing,
        icon: const Icon(FiIcons.link),
        label: Text(context.l10n.pairingStart),
      );

  /// Shown after the idle copy while Discoverable is off, so the user knows
  /// pairing does not depend on it.
  static String discoveryOffNote(AppLocalizations l) =>
      l.pairingDiscoveryOffNote;

  String _idleText(AppLocalizations l) => controller.preferences.discoverable
      ? l.pairingIdleBody
      : '${l.pairingIdleBody} ${discoveryOffNote(l)}';

  /// Idle is the card's resting state (mock devices-pairing): a row on a wide screen, a stack on a phone.
  Widget _idle(BuildContext context, bool compact) => compact
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _mark(true),
                const SizedBox(width: 10),
                Expanded(child: Text(context.l10n.pairingTitle, style: _title)),
                const HelpButton(HelpId.pairingStartPairing),
              ],
            ),
            const SizedBox(height: 10),
            Text(_idleText(context.l10n), key: const Key('pairing-idle-body')),
            const SizedBox(height: 10),
            _startButton(context, block: true),
          ],
        )
      : Row(
          children: [
            _mark(false),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.pairingTitle, style: _title),
                  const SizedBox(height: 3),
                  Text(
                    _idleText(context.l10n),
                    key: const Key('pairing-idle-body'),
                  ),
                ],
              ),
            ),
            const HelpButton(HelpId.pairingStartPairing),
            const SizedBox(width: 8),
            _startButton(context, block: false),
          ],
        );

  /// The states that draw their own heading rather than "Pair a device".
  bool get _ownHeading => switch (controller.pairing.kind) {
    PairingKindDto.discoverable ||
    PairingKindDto.awaitingConfirmation ||
    PairingKindDto.committing => true,
    PairingKindDto.failed => switch (controller.pairing.failure) {
      PairingFailureKindDto.secureStoreLocked ||
      PairingFailureKindDto.expired ||
      PairingFailureKindDto.rejected => true,
      _ => false,
    },
    _ => false,
  };

  List<Widget> _content(BuildContext context) =>
      switch (controller.pairing.kind) {
        // Rendered by [_idle].
        PairingKindDto.idle => const [],
        PairingKindDto.discoverable => _discoverable(context),
        PairingKindDto.connecting => [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(context.l10n.pairingConnecting),
        ],
        PairingKindDto.awaitingConfirmation => _codeConfirmation(
          context,
          committing: false,
          locked: false,
        ),
        PairingKindDto.committing => _codeConfirmation(
          context,
          committing: true,
          locked: false,
        ),
        PairingKindDto.trusted => [
          const Icon(FiIcons.verified, color: Nocturne.accent, size: 40),
          Text(context.l10n.pairingSuccess, textAlign: TextAlign.center),
          TextButton(
            onPressed: controller.beginPairing,
            child: Text(context.l10n.pairingAnother),
          ),
        ],
        PairingKindDto.failed => _failure(context),
      };

  /// `m:ss` for [seconds].
  static String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  /// The pairing window the app requests in [DevicesController.beginPairing].
  static const _windowSeconds = 120;

  /// Pairing is open (mock devices-pairing): countdown ring, time left, Stop, and the nearby
  /// candidates by endpoint.
  List<Widget> _discoverable(BuildContext context) {
    final l = context.l10n;
    final remaining = controller.remainingSeconds;
    final candidates = controller.candidates;
    return [
      Row(
        children: [
          SizedBox.square(
            dimension: 36,
            child: CircularProgressIndicator(
              key: const Key('pairing-countdown-ring'),
              value: (remaining / _windowSeconds).clamp(0.0, 1.0),
              strokeWidth: 3,
              color: Nocturne.accent,
              backgroundColor: Nocturne.neutral800,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.pairingOpen, style: _title),
                const SizedBox(height: 3),
                Text(
                  l.pairingTimeLeft(_clock(remaining)),
                  key: const Key('pairing-time-left'),
                  style: TextStyle(
                    fontSize: 12,
                    fontFeatures: Nocturne.tabular,
                    color: Nocturne.muted(.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: const Key('stop-pairing'),
            onPressed: controller.busy ? null : controller.stopPairing,
            child: Text(l.pairingStop),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: Text(
              l.pairingNearby(candidates.length),
              key: const Key('pairing-nearby-heading'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          const HelpButton(
            HelpId.pairingSingleInitiator,
            key: Key('single-initiator-hint'),
          ),
        ],
      ),
      const SizedBox(height: 4),
      for (final candidate in candidates)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(FiIcons.devices, size: 16, color: Nocturne.muted(.6)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  candidate.endpoint,
                  key: Key('candidate-endpoint-${candidate.instanceId}'),
                  style: const TextStyle(
                    fontFamily: Nocturne.monoFamily,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                key: Key('candidate-${candidate.instanceId}'),
                onPressed: controller.busy
                    ? null
                    : () => controller.selectCandidate(candidate),
                child: Text(l.pairingConnect),
              ),
            ],
          ),
        ),
      if (controller.allCandidatesAlreadyPaired)
        Text(
          l.pairingAlreadyPaired,
          key: const Key('candidates-already-paired'),
        )
      else ...[
        if (candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(l.pairingNoCandidates),
          ),
        Text(
          l.pairingHiddenPaired,
          key: const Key('candidates-hidden-note'),
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.5)),
        ),
      ],
    ];
  }

  /// A DeviceId in groups of eight hex characters, none elided.
  static String _idGroups(String id) => [
    for (var start = 0; start < id.length; start += 8)
      id.substring(start, start + 8 > id.length ? id.length : start + 8),
  ].join(' ');

  /// Confirm the code (mock devices-code-confirm). While [committing] the title reads "Saving
  /// trust…" and both actions wait; when [locked] the keyring line replaces the instruction and
  /// Retry replaces Confirm. The code and id stay from the session after Rust drops them.
  List<Widget> _codeConfirmation(
    BuildContext context, {
    required bool committing,
    required bool locked,
  }) {
    final l = context.l10n;
    final sas = (controller.pairing.sas ?? controller.sessionSas)?.padLeft(
      6,
      '0',
    );
    final peerId = controller.pairing.peerDeviceId ?? controller.sessionPeerId;
    final name = controller.peerName;
    final waiting = committing || controller.busy;
    return [
      Row(
        children: [
          if (committing) ...[
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                key: Key('pairing-saving-ring'),
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              committing ? l.pairingSavingTrust : l.pairingConfirmTitle,
              key: const Key('pairing-confirm-title'),
              style: _title,
            ),
          ),
        ],
      ),
      if (name != null) ...[
        const SizedBox(height: 2),
        Text(
          l.pairingWith(name),
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        locked ? l.pairingKeyringLine : l.pairingConfirmInstruction,
        key: Key(
          locked ? 'pairing-secure-store-locked' : 'pairing-instruction',
        ),
      ),
      if (sas != null) ...[
        const SizedBox(height: 14),
        Semantics(
          label: sas,
          child: Row(
            key: const Key('pairing-sas'),
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 6,
            children: [
              for (final (index, digit) in sas.split('').indexed)
                Container(
                  key: Key('pairing-sas-digit-$index'),
                  width: 38,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Nocturne.bg,
                    borderRadius: BorderRadius.circular(Nocturne.radius),
                    border: Border.all(color: Nocturne.accent700),
                  ),
                  child: Text(
                    digit,
                    style: const TextStyle(
                      fontFamily: Nocturne.monoFamily,
                      fontSize: 24,
                      color: Nocturne.accent200,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (peerId != null) ...[
        const SizedBox(height: 14),
        Text(
          l.pairingPeerIdOf(name ?? l.devicesOtherDevice),
          key: const Key('pairing-peer-id-label'),
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
        ),
        const SizedBox(height: 4),
        SelectableText(
          _idGroups(peerId),
          key: const Key('pairing-peer-id'),
          style: const TextStyle(fontFamily: Nocturne.monoFamily, fontSize: 12),
        ),
      ],
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: const Key('pairing-reject'),
              onPressed: waiting
                  ? null
                  : locked
                  ? controller.stopPairing
                  : controller.reject,
              child: Text(l.pairingReject),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: locked
                ? FilledButton.icon(
                    key: const Key('pairing-retry-after-unlock'),
                    onPressed: waiting ? null : controller.retryAfterUnlock,
                    icon: const Icon(FiIcons.refresh),
                    label: Text(l.commonRetry),
                  )
                : FilledButton(
                    key: const Key('pairing-confirm'),
                    onPressed: waiting ? null : controller.confirm,
                    child: Text(l.pairingConfirm),
                  ),
          ),
        ],
      ),
    ];
  }

  /// "Pairing expired" / "Pairing rejected" with "Start pairing".
  List<Widget> _ended(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String body,
  }) => [
    Row(
      key: key,
      children: [
        Icon(icon, size: 22, color: Nocturne.muted(.7)),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: _title)),
      ],
    ),
    const SizedBox(height: 6),
    Text(body),
    const SizedBox(height: 14),
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        key: const Key('pairing-start-again'),
        onPressed: controller.busy ? null : controller.beginPairing,
        icon: const Icon(FiIcons.link),
        label: Text(context.l10n.pairingStart),
      ),
    ),
  ];

  List<Widget> _failure(BuildContext context) =>
      switch (controller.pairing.failure) {
        PairingFailureKindDto.bothRootless => [
          const Icon(FiIcons.info, size: 40),
          Text(
            context.l10n.pairingBothRootless,
            key: const Key('pairing-both-rootless'),
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: controller.beginPairing,
            child: Text(context.l10n.pairingAgain),
          ),
        ],
        PairingFailureKindDto.rootMismatch => [
          const Icon(FiIcons.blocked, color: Nocturne.error, size: 40),
          Text(
            context.l10n.pairingRootMismatch,
            key: const Key('pairing-root-mismatch'),
            textAlign: TextAlign.center,
          ),
          if (onResetDataset != null)
            FilledButton.icon(
              key: const Key('reset-dataset'),
              onPressed: controller.busy ? null : () => _confirmReset(context),
              icon: const Icon(FiIcons.reset),
              label: Text(context.l10n.shellResetData),
            ),
          TextButton(
            onPressed: controller.beginPairing,
            child: Text(context.l10n.pairingDifferentDevice),
          ),
        ],
        PairingFailureKindDto.secureStoreLocked => _codeConfirmation(
          context,
          committing: false,
          locked: true,
        ),
        PairingFailureKindDto.expired => _ended(
          context,
          key: const Key('pairing-expired'),
          icon: FiIcons.duration,
          title: context.l10n.pairingExpiredTitle,
          body: context.l10n.pairingExpiredBody,
        ),
        PairingFailureKindDto.rejected => _ended(
          context,
          key: const Key('pairing-rejected'),
          icon: FiIcons.blocked,
          title: context.l10n.pairingRejectedTitle,
          body: context.l10n.pairingRejectedBody,
        ),
        PairingFailureKindDto.other || null => [
          const Icon(FiIcons.error, color: Nocturne.error, size: 40),
          Text(context.l10n.pairingDidNotComplete, textAlign: TextAlign.center),
          if (controller.pairing.message case final detail?)
            Text(
              detail,
              key: const Key('pairing-failure-detail'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
            ),
          TextButton(
            onPressed: controller.beginPairing,
            child: Text(context.l10n.commonTryAgain),
          ),
        ],
      };

  Future<void> _confirmReset(BuildContext context) async {
    final action = onResetDataset;
    if (action == null) return;
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead: context.l10n.pairingResetLead,
      trustedDeviceCount: controller.devices
          .where((device) => !device.revoked)
          .length,
    );
    if (confirmed) await action();
  }
}
