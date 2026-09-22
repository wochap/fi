import 'package:fi/controllers.dart';
import 'package:fi/reset_dialog.dart';
import 'package:fi/src/rust/api/models.dart';
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

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('pairing-card'),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pair a device', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ..._content(context),
        ],
      ),
    ),
  );

  List<Widget> _content(
    BuildContext context,
  ) => switch (controller.pairing.kind) {
    PairingKindDto.idle => [
      const Text('Pairing is off. Start it only when both devices are nearby.'),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('start-pairing'),
        onPressed: controller.busy ? null : controller.beginPairing,
        icon: const Icon(Icons.link),
        label: const Text('Start pairing'),
      ),
    ],
    PairingKindDto.discoverable => [
      Text(
        'Searching for nearby devices · ${controller.remainingSeconds}s remaining',
      ),
      const LinearProgressIndicator(),
      const SizedBox(height: 8),
      if (controller.candidates.isEmpty)
        const Text('No nearby pairing candidates yet.')
      else ...[
        const Text(
          'Tap Connect on one device only; the other device just waits.',
          key: Key('single-initiator-hint'),
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
        style: Theme.of(context).textTheme.displaySmall,
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
      const Icon(Icons.verified, color: Colors.green, size: 40),
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
          const Icon(Icons.block, color: Colors.red, size: 40),
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
        PairingFailureKindDto.other || null => [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
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
