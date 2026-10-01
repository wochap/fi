import 'package:fi/l10n/l10n.dart';
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
    title: Text(context.l10n.resetTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(lead),
        const SizedBox(height: 12),
        _Consequence(context.l10n.resetOnlyCopy),
        _Consequence(context.l10n.resetOthersKeep),
        _Consequence(context.l10n.resetLostIfOnly),
        _Consequence(context.l10n.resetNotTold),
        if (trustedDeviceCount case final count?) ...[
          const SizedBox(height: 12),
          Text(
            context.l10n.resetTrustedCount(count),
            key: const Key('reset-trusted-count'),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const Key('reset-cancel'),
        onPressed: () => Navigator.pop(context, false),
        child: Text(context.l10n.commonCancel),
      ),
      FilledButton(
        key: const Key('reset-confirm'),
        onPressed: () => Navigator.pop(context, true),
        child: Text(context.l10n.resetConfirm),
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
