import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Callback an entry point invokes once the user confirmed the reset.
typedef ResetDatasetAction = Future<void> Function();

/// The one confirmation for a dataset reset, shared by every entry point (mock
/// devices-confirm-dialogs).
///
/// The consequence paragraph is fixed; an entry point may add a [lead] sentence
/// saying why the user is here. [trustedDeviceCount], when known, is the
/// strongest signal of whether a copy exists elsewhere. "Reset data" stays
/// unavailable until the user ticks the acknowledgement.
class ResetDatasetDialog extends StatefulWidget {
  const ResetDatasetDialog({this.lead, this.trustedDeviceCount, super.key});

  final String? lead;
  final int? trustedDeviceCount;

  /// Shows the dialog and resolves to whether the user confirmed.
  static Future<bool> show(
    BuildContext context, {
    String? lead,
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
  State<ResetDatasetDialog> createState() => _ResetDatasetDialogState();
}

class _ResetDatasetDialogState extends State<ResetDatasetDialog> {
  var _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final buttonSize = Nocturne.isPhone(context) ? const Size(0, 48) : null;
    return AlertDialog(
      key: const Key('reset-dataset-dialog'),
      title: Text(l.resetTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.lead case final lead?) ...[
            Text(lead),
            const SizedBox(height: 10),
          ],
          Text(l.resetParagraph, key: const Key('reset-paragraph')),
          if (widget.trustedDeviceCount case final count?) ...[
            const SizedBox(height: 10),
            Text(
              l.resetTrustedCount(count),
              key: const Key('reset-trusted-count'),
            ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const Key('reset-acknowledge'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _acknowledged,
            onChanged: (value) =>
                setState(() => _acknowledged = value ?? false),
            title: Text(l.resetAcknowledge),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('reset-confirm'),
          style: TextButton.styleFrom(minimumSize: buttonSize),
          onPressed: _acknowledged ? () => Navigator.pop(context, true) : null,
          child: Text(l.resetConfirm),
        ),
        FilledButton(
          key: const Key('reset-cancel'),
          style: FilledButton.styleFrom(minimumSize: buttonSize),
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.resetKeep),
        ),
      ],
    );
  }
}
