import 'package:flutter/material.dart';

/// Callback an entry point invokes once the user confirmed the reset.
typedef ResetDatasetAction = Future<void> Function();

/// The one confirmation for a dataset reset, shared by every entry point.
///
/// The four consequence statements are fixed; entry points differ only in the
/// [lead] sentence saying why the user is here. [trustedDeviceCount], when
/// known, is the strongest signal of whether a copy exists elsewhere.
class ResetDatasetDialog extends StatelessWidget {
  const ResetDatasetDialog({
    required this.lead,
    this.trustedDeviceCount,
    super.key,
  });

  final String lead;
  final int? trustedDeviceCount;

  /// Shows the dialog and resolves to whether the user confirmed.
  static Future<bool> show(
    BuildContext context, {
    required String lead,
    int? trustedDeviceCount,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ResetDatasetDialog(
        lead: lead,
        trustedDeviceCount: trustedDeviceCount,
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('reset-dataset-dialog'),
    title: const Text("Reset this device's data?"),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(lead),
        const SizedBox(height: 12),
        const _Consequence(
          'This deletes the only copy of the dataset on this device.',
        ),
        const _Consequence('Your other devices keep their copies.'),
        const _Consequence(
          'If this is the only device, the data is permanently lost.',
        ),
        const _Consequence('Other devices are not told about this reset.'),
        if (trustedDeviceCount case final count?) ...[
          const SizedBox(height: 12),
          Text(switch (count) {
            0 => 'This device currently trusts no other devices.',
            1 => 'This device currently trusts 1 other device.',
            _ => 'This device currently trusts $count other devices.',
          }, key: const Key('reset-trusted-count')),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const Key('reset-cancel'),
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reset-confirm'),
        onPressed: () => Navigator.pop(context, true),
        child: const Text("Reset this device's data"),
      ),
    ],
  );
}

class _Consequence extends StatelessWidget {
  const _Consequence(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• '),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
