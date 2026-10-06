import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// The canvas confirm pattern: title, body, the destructive action as a secondary button on the
/// left and the safe action as the primary button on the right, 48px tall on a phone. Dismissal
/// returns false.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String destructive,
  required String safe,
  Key? dialogKey,
  Key? destructiveKey,
  Key? safeKey,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: dialogKey,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: destructiveKey,
            style: TextButton.styleFrom(minimumSize: _buttonSize(dialog)),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(destructive),
          ),
          FilledButton(
            key: safeKey,
            style: FilledButton.styleFrom(minimumSize: _buttonSize(dialog)),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(safe),
          ),
        ],
      ),
    ) ??
    false;

Size? _buttonSize(BuildContext context) =>
    Nocturne.isPhone(context) ? const Size(0, 48) : null;
