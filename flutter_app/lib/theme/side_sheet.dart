import 'dart:math' as math;

import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';

/// Below this screen width a side sheet becomes a bottom sheet.
const double sideSheetBreakpoint = 720;

/// Opens a 480px sheet sliding in from the right, or a bottom sheet on a phone.
///
/// The sheet has a header ([kicker] over [title] with a close button), a scrolling [body] and a
/// footer holding [footerNote] and a primary Done. [body] is built with the sheet's own context,
/// so dialogs it opens stack above the sheet.
Future<void> showSideSheet(
  BuildContext context, {
  required String kicker,
  required String title,
  required WidgetBuilder body,
  String? footerNote,
  Key? key,
}) {
  Widget frame(BuildContext sheet) => _SideSheetFrame(
    key: key,
    kicker: kicker,
    title: title,
    body: body(sheet),
    footerNote: footerNote,
  );
  final size = MediaQuery.sizeOf(context);
  if (size.width < sideSheetBreakpoint) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) =>
          SizedBox(height: size.height * .85, child: frame(sheet)),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: title,
    barrierColor: Nocturne.neutral900.withValues(alpha: .7),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (sheet, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: math.min(480, size.width),
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Nocturne.surface,
          boxShadow: Nocturne.shadowLg,
        ),
        child: Material(type: MaterialType.transparency, child: frame(sheet)),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _SideSheetFrame extends StatelessWidget {
  const _SideSheetFrame({
    required this.kicker,
    required this.title,
    required this.body,
    this.footerNote,
    super.key,
  });

  final String kicker;
  final String title;
  final Widget body;
  final String? footerNote;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Kicker(kicker),
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      Expanded(child: body),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Nocturne.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                footerNote ?? '',
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    ],
  );
}
