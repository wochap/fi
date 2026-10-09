import 'package:fi/controllers.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';

/// The shared layout of every pre-shell screen (mocks onboarding-*, startup-errors): the Fi logo
/// tile and wordmark, a title, a muted lead, and a 560px left-aligned column. Desktop gets the
/// radial accent background; a phone gets 16px gutters.
class SetupScaffold extends StatelessWidget {
  const SetupScaffold({
    required this.title,
    this.lead,
    this.leading,
    this.children = const [],
    super.key,
  });

  final String title;
  final String? lead;

  /// Drawn left of the title, such as a progress ring.
  final Widget? leading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < Nocturne.phoneBreakpoint;
    final titleText = Text(
      title,
      key: const Key('setup-title'),
      style: TextStyle(
        fontSize: phone ? 28 : 36,
        fontWeight: FontWeight.w500,
        height: 1.15,
      ),
    );
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: context.nocturne.bg,
          gradient: phone
              ? null
              : RadialGradient(
                  center: Alignment(-.8, -1),
                  radius: 1.3,
                  colors: [context.nocturne.accentFill, context.nocturne.bg],
                  stops: [0, .6],
                ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: phone
                ? const EdgeInsets.fromLTRB(16, 18, 16, 24)
                : const EdgeInsets.fromLTRB(56, 40, 56, 48),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        FiLogoTile(),
                        SizedBox(width: 10),
                        Text(
                          'Fi',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: phone ? 28 : 56),
                    if (leading case final leading?)
                      Row(
                        children: [
                          leading,
                          const SizedBox(width: 14),
                          Expanded(child: titleText),
                        ],
                      )
                    else
                      titleText,
                    if (lead case final lead?) ...[
                      const SizedBox(height: 10),
                      Text(
                        lead,
                        key: const Key('setup-lead'),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: context.nocturne.muted(.65),
                        ),
                      ),
                    ],
                    SizedBox(height: phone ? 22 : 28),
                    ...children,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An indeterminate ring sized for a [SetupScaffold] title.
class SetupRing extends StatelessWidget {
  const SetupRing({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 28,
    child: CircularProgressIndicator(
      key: Key('setup-ring'),
      strokeWidth: 3,
      color: context.nocturne.accent,
      backgroundColor: context.nocturne.neutralFillStrong,
    ),
  );
}

/// A pre-shell action row: secondary actions first, the primary last. On a phone the actions
/// stack full width with the primary at the bottom.
class SetupActions extends StatelessWidget {
  const SetupActions({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < Nocturne.phoneBreakpoint;
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          for (final child in children)
            SizedBox(height: Nocturne.touchTarget + 2, child: child),
        ],
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.end,
      children: children,
    );
  }
}

/// The muted paragraph style of the pre-shell screens.
TextStyle setupBodyStyle(BuildContext context) =>
    TextStyle(fontSize: 14, height: 1.5, color: context.nocturne.muted(.8));

/// One choice on "Set up this device" (mock onboarding-first-run). The card is the action:
/// tapping it chooses. [selected] draws the accent border and fill; [lockedReason] replaces the
/// body, mutes the icon and title, shows a lock and makes the card inert.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    required this.icon,
    required this.title,
    required this.body,
    this.bullets = const [],
    this.selected = false,
    this.lockedReason,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<String> bullets;
  final bool selected;
  final String? lockedReason;
  final VoidCallback? onTap;

  bool get locked => lockedReason != null;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(Nocturne.radius));
    final titleColor = locked
        ? context.nocturne.muted(.5)
        : context.nocturne.text;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.45,
      color: context.nocturne.muted(locked ? .45 : .65),
    );
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? context.nocturne.accentFill
              : context.nocturne.surface,
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? context.nocturne.accent
                : context.nocturne.divider,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: locked ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconTile(
                  icon,
                  size: 36,
                  fill: locked
                      ? context.nocturne.neutralFill
                      : context.nocturne.accentFill,
                  color: locked
                      ? context.nocturne.muted(.45)
                      : context.nocturne.accent,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        lockedReason ?? body,
                        key: locked ? const Key('choice-locked-reason') : null,
                        style: muted,
                      ),
                      if (bullets.isNotEmpty && !locked) ...[
                        const SizedBox(height: 8),
                        for (final bullet in bullets)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Icon(
                                    FiIcons.check,
                                    size: 14,
                                    color: context.nocturne.muted(.55),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(child: Text(bullet, style: muted)),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  locked ? FiIcons.locked : FiIcons.chevronRight,
                  size: 18,
                  color: context.nocturne.muted(.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Couldn't join": a both-rootless pairing from onboarding (mock onboarding-first-run).
class CouldntJoinScreen extends StatelessWidget {
  const CouldntJoinScreen({required this.onBack, super.key});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SetupScaffold(
    key: const Key('couldnt-join'),
    title: context.l10n.couldntJoinTitle,
    lead: context.l10n.couldntJoinBody,
    children: [
      SetupActions(
        children: [
          FilledButton(
            key: const Key('couldnt-join-back'),
            onPressed: onBack,
            child: Text(context.l10n.commonBack),
          ),
        ],
      ),
    ],
  );
}

/// "This device has a different dataset" (mock onboarding-dataset-mismatch): a root-mismatch
/// pairing, from onboarding or the Devices page. Reset is the only resolution; no retry.
class DatasetMismatchScreen extends StatelessWidget {
  const DatasetMismatchScreen({
    required this.peerName,
    required this.onBack,
    required this.onPairDifferent,
    this.onReset,
    super.key,
  });

  final String? peerName;
  final VoidCallback onBack;
  final VoidCallback onPairDifferent;

  /// Opens the reset confirmation; hidden when the host has no reset.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SetupScaffold(
      key: const Key('dataset-mismatch'),
      title: l.mismatchTitle,
      children: [
        Text(
          switch (peerName) {
            final name? => l.mismatchBodyNamed(name),
            null => l.mismatchBody,
          },
          key: const Key('dataset-mismatch-body'),
          style: setupBodyStyle(context),
        ),
        const SizedBox(height: 10),
        Text(l.mismatchResetNote, style: setupBodyStyle(context)),
        const SizedBox(height: 24),
        SetupActions(
          children: [
            if (onReset != null)
              OutlinedButton(
                key: const Key('reset-dataset'),
                onPressed: onReset,
                child: Text(l.resetDataEllipsis),
              ),
            OutlinedButton(
              key: const Key('pair-different-device'),
              onPressed: onPairDifferent,
              child: Text(l.pairingDifferentDevice),
            ),
            FilledButton(
              key: const Key('dataset-mismatch-back'),
              onPressed: onBack,
              child: Text(l.commonBack),
            ),
          ],
        ),
      ],
    );
  }
}

/// "Pairing is open · m:ss left" with Stop pairing, under the onboarding choices.
class PairingStatusRow extends StatelessWidget {
  const PairingStatusRow({required this.devices, super.key});
  final DevicesController devices;

  static String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      key: const Key('pairing-status-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const GlowDot(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.setupPairingStatus(_clock(devices.remainingSeconds)),
                key: const Key('pairing-status-text'),
                style: const TextStyle(
                  fontSize: 14,
                  fontFeatures: Nocturne.tabular,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('stop-pairing'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, Nocturne.touchTarget),
              ),
              onPressed: devices.busy ? null : devices.stopPairing,
              child: Text(l.setupStopPairing),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          l.setupPairingWaiting,
          style: TextStyle(fontSize: 13, color: context.nocturne.muted(.6)),
        ),
      ],
    );
  }
}
