import 'dart:async';
import 'dart:math' as math;

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// The one help affordance: a `?` beside a control that opens the registry copy for it.
///
/// It reads from [helpEntry] and never carries copy of its own, so the text for a concept stays
/// reviewable in one place. It is 28×28 on desktop and a 44×44 touch target on a phone.
final class HelpButton extends StatelessWidget {
  const HelpButton(this.id, {super.key});

  final HelpId id;

  @override
  Widget build(BuildContext context) {
    final entry = helpEntry(context.l10n, id);
    final phone = Nocturne.isPhone(context);
    final side = phone ? Nocturne.touchTarget : 28.0;
    return SizedBox.square(
      dimension: side,
      child: IconButton(
        key: Key('help-${id.name}'),
        icon: Icon(FiIcons.help, size: phone ? 18 : 16),
        tooltip: context.l10n.helpAboutTooltip(entry.title),
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: side, height: side),
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        // Opening help is a read; it must not touch the form it sits in.
        onPressed: () => unawaited(showHelp(context, id)),
      ),
    );
  }
}

/// Opens the dismissible popup for [id]: a popover under the `?` that [context] belongs to at
/// 720px and wider, a bottom sheet below. Got it, Esc or a tap outside return without a result,
/// so no caller can mistake dismissal for a decision.
Future<void> showHelp(BuildContext context, HelpId id) async {
  final entry = helpEntry(context.l10n, id);
  final gotIt = context.l10n.helpGotIt;
  if (Nocturne.isPhone(context)) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          key: const Key('help-dialog'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(entry.title, style: Theme.of(sheet).textTheme.titleMedium),
              const SizedBox(height: 8),
              Flexible(child: SingleChildScrollView(child: Text(entry.body))),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const Key('help-close'),
                  onPressed: () => Navigator.pop(sheet),
                  child: Text(gotIt),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  final anchor = box != null && overlay != null && box.hasSize
      ? box.localToGlobal(Offset.zero, ancestor: overlay) & box.size
      : null;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: gotIt,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (popup, _, _) => CustomSingleChildLayout(
      delegate: _PopoverLayout(anchor),
      child: _Popover(
        title: entry.title,
        body: entry.body,
        gotIt: gotIt,
        onClose: () => Navigator.pop(popup),
      ),
    ),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

final class _Popover extends StatelessWidget {
  const _Popover({
    required this.title,
    required this.body,
    required this.gotIt,
    required this.onClose,
  });

  final String title;
  final String body;
  final String gotIt;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('help-dialog'),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(Nocturne.radius),
    elevation: 8,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .6,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 8),
                child: Text(body),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('help-close'),
                autofocus: true,
                onPressed: onClose,
                child: Text(gotIt),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Places the 320px popover under [anchor], or above it when there is no room below, kept on
/// screen horizontally. Without an anchor it is centred.
final class _PopoverLayout extends SingleChildLayoutDelegate {
  const _PopoverLayout(this.anchor);

  static const width = 320.0;
  static const gap = 6.0;
  static const margin = 8.0;

  final Rect? anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(width, constraints.maxWidth - 2 * margin),
        maxHeight: constraints.maxHeight - 2 * margin,
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final anchor = this.anchor;
    if (anchor == null) {
      return Offset(
        (size.width - child.width) / 2,
        (size.height - child.height) / 2,
      );
    }
    final left = (anchor.center.dx - child.width / 2).clamp(
      margin,
      math.max(margin, size.width - child.width - margin),
    );
    final below = anchor.bottom + gap;
    final top = below + child.height <= size.height - margin
        ? below
        : math.max(margin, anchor.top - gap - child.height);
    return Offset(left.toDouble(), top);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) => old.anchor != anchor;
}
