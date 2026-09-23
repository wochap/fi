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
  static const _idleBody =
      'Pairing is off. Start it only when both devices are nearby.';

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
              ? _idle(compact)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _heading(compact),
                    const SizedBox(height: 12),
                    ..._content(context),
                  ],
                ),
        ),
      );
    },
  );

  Widget _mark(bool compact) => compact
      ? const Icon(Icons.link, size: 20, color: Nocturne.accent)
      : const IconTile(
          Icons.link,
          size: 44,
          fill: null,
          outline: Nocturne.accent700,
          color: Nocturne.accent,
        );

  Widget _heading(bool compact) => Row(
    children: [
      _mark(compact),
      SizedBox(width: compact ? 10 : 16),
      const Expanded(child: Text('Pair a device', style: _title)),
    ],
  );

  Widget _startButton({required bool block}) => FilledButton.icon(
    key: const Key('start-pairing'),
    style: block
        ? FilledButton.styleFrom(minimumSize: const Size(0, 46))
        : null,
    onPressed: controller.busy ? null : controller.beginPairing,
    icon: const Icon(Icons.link),
    label: const Text('Start pairing'),
  );

  /// Idle is the card's resting state (mocks 1b, 2i): a row on a wide screen, a stack on a phone.
  Widget _idle(bool compact) => compact
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _mark(true),
                const SizedBox(width: 10),
                const Expanded(child: Text('Pair a device', style: _title)),
                const HelpButton(HelpId.pairingStartPairing),
              ],
            ),
            const SizedBox(height: 10),
            const Text(_idleBody),
            const SizedBox(height: 10),
            _startButton(block: true),
          ],
        )
      : Row(
          children: [
            _mark(false),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pair a device', style: _title),
                  SizedBox(height: 3),
                  Text(_idleBody),
                ],
              ),
            ),
            const HelpButton(HelpId.pairingStartPairing),
            const SizedBox(width: 8),
            _startButton(block: false),
          ],
        );

  List<Widget> _content(
    BuildContext context,
  ) => switch (controller.pairing.kind) {
    // Rendered by [_idle].
    PairingKindDto.idle => const [],
    PairingKindDto.discoverable => [
      Text(
        'Searching for nearby devices · ${controller.remainingSeconds}s remaining',
      ),
      const LinearProgressIndicator(),
      const SizedBox(height: 8),
      if (controller.allCandidatesAlreadyPaired)
        const Text(
          'The devices found here are already paired with this one.',
          key: Key('candidates-already-paired'),
        )
      else if (controller.candidates.isEmpty)
        const Text('No nearby pairing candidates yet.')
      else ...[
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tap Connect on one device only; the other device just waits.',
                key: Key('single-initiator-hint'),
              ),
            ),
            const HelpButton(HelpId.pairingSingleInitiator),
          ],
        ),
        ...controller.candidates.map(
          (candidate) => ListTile(
            key: Key('candidate-${candidate.instanceId}'),
            leading: const Icon(Icons.phone_android),
            title: Text(candidate.endpoint),
            subtitle: const Text('Nearby device'),
            trailing: const Text('Connect'),
            onTap: controller.busy
                ? null
                : () => controller.selectCandidate(candidate),
          ),
        ),
      ],
      OutlinedButton(
        key: const Key('stop-pairing'),
        onPressed: controller.busy ? null : controller.stopPairing,
        child: const Text('Stop pairing'),
      ),
    ],
    PairingKindDto.connecting => const [
      LinearProgressIndicator(),
      SizedBox(height: 8),
      Text('Connecting securely…'),
    ],
    PairingKindDto.awaitingConfirmation => [
      const Text('Confirm that this code matches on both devices:'),
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
      const SizedBox(height: 12),
      FilledButton(
        onPressed: controller.busy ? null : controller.confirm,
        child: const Text('Codes match'),
      ),
      TextButton(
        onPressed: controller.busy ? null : controller.reject,
        child: const Text('Codes do not match'),
      ),
    ],
    PairingKindDto.committing => const [
      LinearProgressIndicator(),
      SizedBox(height: 8),
      Text('Saving trust and synchronizing the dataset…'),
    ],
    PairingKindDto.trusted => [
      const Icon(Icons.verified, color: Nocturne.accent, size: 40),
      const Text('Device paired successfully.', textAlign: TextAlign.center),
      TextButton(
        onPressed: controller.beginPairing,
        child: const Text('Pair another device'),
      ),
    ],
    PairingKindDto.failed => _failure(context),
  };

  List<Widget> _failure(BuildContext context) =>
      switch (controller.pairing.failure) {
        PairingFailureKindDto.bothRootless => [
          const Icon(Icons.info_outline, size: 40),
          const Text(
            'Neither device has a dataset yet, so there is nothing to join. '
            'Pair with a device that already has a dataset, or create a new '
            'dataset on one device first.',
            key: Key('pairing-both-rootless'),
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: controller.beginPairing,
            child: const Text('Pair again'),
          ),
        ],
        PairingFailureKindDto.rootMismatch => [
          const Icon(Icons.block, color: Nocturne.error, size: 40),
          const Text(
            'These devices hold different datasets, and datasets cannot be '
            'merged. Pairing them again will not succeed. To use the other '
            "device's dataset here, this device's local data must be reset "
            'first.',
            key: Key('pairing-root-mismatch'),
            textAlign: TextAlign.center,
          ),
          if (onResetDataset != null)
            FilledButton.icon(
              key: const Key('reset-dataset'),
              onPressed: controller.busy ? null : () => _confirmReset(context),
              icon: const Icon(Icons.restart_alt),
              label: const Text("Reset this device's data"),
            ),
          TextButton(
            onPressed: controller.beginPairing,
            child: const Text('Pair a different device'),
          ),
        ],
        PairingFailureKindDto.secureStoreLocked => [
          const Icon(Icons.lock_outline, size: 40),
          const Text(
            'Your login keyring is locked, so this device could not save the '
            'pairing. Unlock the keyring, then retry — the other device may '
            'already show this one as paired.',
            key: Key('pairing-secure-store-locked'),
            textAlign: TextAlign.center,
          ),
          FilledButton.icon(
            key: const Key('pairing-retry-after-unlock'),
            onPressed: controller.busy ? null : controller.retryAfterUnlock,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
        PairingFailureKindDto.other || null => [
          const Icon(Icons.error_outline, color: Nocturne.error, size: 40),
          Text(
            controller.pairing.message ?? 'Pairing did not complete.',
            textAlign: TextAlign.center,
          ),
          TextButton(
            onPressed: controller.beginPairing,
            child: const Text('Try again'),
          ),
        ],
      };

  Future<void> _confirmReset(BuildContext context) async {
    final action = onResetDataset;
    if (action == null) return;
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          "To join the other device's dataset, this device's local data must "
          'be reset first.',
      trustedDeviceCount: controller.devices
          .where((device) => !device.revoked)
          .length,
    );
    if (confirmed) await action();
  }
}
