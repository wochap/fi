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
                    _heading(context, compact),
                    const SizedBox(height: 12),
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

  /// Idle is the card's resting state (mocks 1b, 2i): a row on a wide screen, a stack on a phone.
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

  List<Widget> _content(BuildContext context) =>
      switch (controller.pairing.kind) {
        // Rendered by [_idle].
        PairingKindDto.idle => const [],
        PairingKindDto.discoverable => [
          Text(context.l10n.pairingSearching(controller.remainingSeconds)),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          if (controller.allCandidatesAlreadyPaired)
            Text(
              context.l10n.pairingAlreadyPaired,
              key: const Key('candidates-already-paired'),
            )
          else if (controller.candidates.isEmpty)
            Text(context.l10n.pairingNoCandidates)
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.pairingSingleInitiator,
                    key: const Key('single-initiator-hint'),
                  ),
                ),
                const HelpButton(HelpId.pairingSingleInitiator),
              ],
            ),
            ...controller.candidates.map(
              (candidate) => ListTile(
                key: Key('candidate-${candidate.instanceId}'),
                leading: const Icon(FiIcons.phone),
                title: Text(candidate.endpoint),
                subtitle: Text(context.l10n.pairingNearbyDevice),
                trailing: Text(context.l10n.pairingConnect),
                onTap: controller.busy
                    ? null
                    : () => controller.selectCandidate(candidate),
              ),
            ),
          ],
          OutlinedButton(
            key: const Key('stop-pairing'),
            onPressed: controller.busy ? null : controller.stopPairing,
            child: Text(context.l10n.pairingStop),
          ),
        ],
        PairingKindDto.connecting => [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(context.l10n.pairingConnecting),
        ],
        PairingKindDto.awaitingConfirmation => [
          Text(context.l10n.pairingConfirmCode),
          const SizedBox(height: 8),
          SelectableText(
            controller.pairing.sas?.padLeft(6, '0') ?? '------',
            key: const Key('pairing-sas'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: Nocturne.monoFamily,
              fontSize: 36,
              letterSpacing: 6,
              color: Nocturne.accent200,
            ),
          ),
          if (controller.pairing.peerDeviceId case final peerId?) ...[
            const SizedBox(height: 8),
            SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(text: context.l10n.pairingOtherDevice),
                  TextSpan(
                    text: peerId,
                    style: const TextStyle(fontFamily: Nocturne.monoFamily),
                  ),
                ],
              ),
              key: const Key('pairing-peer-id'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
            ),
            Text(
              context.l10n.pairingReferenceOnly,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Nocturne.muted(.45)),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: controller.busy ? null : controller.confirm,
            child: Text(context.l10n.pairingCodesMatch),
          ),
          TextButton(
            onPressed: controller.busy ? null : controller.reject,
            child: Text(context.l10n.pairingCodesDiffer),
          ),
        ],
        PairingKindDto.committing => [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(context.l10n.pairingCommitting),
        ],
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
        PairingFailureKindDto.secureStoreLocked => [
          const Icon(FiIcons.locked, size: 40),
          Text(
            context.l10n.pairingKeyringLocked,
            key: const Key('pairing-secure-store-locked'),
            textAlign: TextAlign.center,
          ),
          FilledButton.icon(
            key: const Key('pairing-retry-after-unlock'),
            onPressed: controller.busy ? null : controller.retryAfterUnlock,
            icon: const Icon(FiIcons.refresh),
            label: Text(context.l10n.commonRetry),
          ),
        ],
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
