import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// A freestanding rule that fades to transparent over 48px at each end (`.hr`).
class FadedRule extends StatelessWidget {
  const FadedRule({this.color, this.indent = 0, super.key});

  /// Defaults to the theme's divider.
  final Color? color;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.nocturne.divider;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: indent),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final ramp = width <= 96 ? .5 : 48 / width;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0),
                  color,
                  color,
                  color.withValues(alpha: 0),
                ],
                stops: [0, ramp, 1 - ramp, 1],
              ),
            ),
            child: const SizedBox(height: 1, width: double.infinity),
          );
        },
      ),
    );
  }
}

/// The small uppercase accent label above a card title (`.card-kicker`).
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 10,
      letterSpacing: 1,
      color: context.nocturne.accent,
      height: 1.4,
    ),
  );
}

/// A section heading: the uppercase `h6` at 60% text.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  /// The label's text style, in the theme's text at 60%.
  static TextStyle styleOf(BuildContext context) => TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.04,
    height: 1.12,
    color: context.nocturne.muted(.6),
  );

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: styleOf(context));
}

/// The live status dot: an accent point with a ring and a glow.
class GlowDot extends StatelessWidget {
  const GlowDot({this.size = 8, this.ring = true, this.color, super.key});

  final double size;
  final bool ring;

  /// Defaults to the theme's accent.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    final color = this.color ?? c.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          if (ring) BoxShadow(color: c.accentFill, spreadRadius: 4),
          BoxShadow(color: color, blurRadius: 12),
        ],
      ),
    );
  }
}

/// A rounded square holding one icon, tinted or outlined.
class IconTile extends StatelessWidget {
  const IconTile(
    this.icon, {
    this.size = 36,
    this.fill = _accentFill,
    this.color,
    this.outline,
    super.key,
  });

  // Sentinel: [fill] left unset takes the theme's accentFill; an explicit null means no fill.
  static const _accentFill = Color.fromARGB(0, 0, 0, 1);

  final IconData icon;
  final double size;
  final Color? fill;

  /// Defaults to the theme's accentInk.
  final Color? color;
  final Color? outline;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: identical(fill, _accentFill) ? c.accentFill : fill,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: outline == null ? null : Border.all(color: outline!),
      ),
      child: Icon(icon, size: size / 2, color: color ?? c.accentInk),
    );
  }
}

/// A small label (`.tag`): accent by default, [Tag.neutral], [Tag.outline],
/// [Tag.danger] or [Tag.success].
///
/// The label is drawn in the theme's text (accentInkStrong on the accent tag); a status
/// color only draws the icon and the edge or fill.
class Tag extends StatelessWidget {
  /// `.tag`: an accentFill fill and an accentInkStrong label.
  const Tag(
    this.text, {
    this.background,
    this.color,
    this.fontSize = 11,
    this.leading,
    super.key,
  }) : _kind = _TagKind.accent;

  /// `.tag-neutral`: a neutralFillStrong fill and a text label.
  const Tag.neutral(this.text, {this.fontSize = 11, this.leading, super.key})
    : _kind = _TagKind.neutral,
      background = null,
      color = null;

  /// Danger: a 1px danger border, a text-colored label and a danger icon.
  const Tag.danger(this.text, {this.fontSize = 11, this.leading, super.key})
    : _kind = _TagKind.danger,
      background = null,
      color = null;

  /// Success: a success fill at 22%, a text-colored label and a success icon.
  const Tag.success(this.text, {this.fontSize = 11, this.leading, super.key})
    : _kind = _TagKind.success,
      background = null,
      color = null;

  /// `.tag-outline`: no fill, a 1px accent border and accent text.
  const Tag.outline(this.text, {this.fontSize = 11, this.leading, super.key})
    : _kind = _TagKind.outline,
      background = null,
      color = null;

  final String text;
  final _TagKind _kind;

  /// Overrides the accent tag's fill.
  final Color? background;

  /// Overrides the accent tag's label and icon color.
  final Color? color;
  final double fontSize;

  /// An icon drawn 4px before the text.
  final IconData? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    final (
      Color fill,
      Color label,
      Color icon,
      Color? border,
    ) = switch (_kind) {
      _TagKind.accent => (
        background ?? c.accentFill,
        color ?? c.accentInkStrong,
        color ?? c.accentInkStrong,
        null,
      ),
      _TagKind.neutral => (c.neutralFillStrong, c.text, c.text, null),
      _TagKind.danger => (Colors.transparent, c.text, c.danger, c.danger),
      _TagKind.success => (
        c.success.withValues(alpha: .22),
        c.text,
        c.success,
        null,
      ),
      _TagKind.outline => (Colors.transparent, c.accent, c.accent, c.accent),
    };
    // Never cut short: a long (translated) tag wraps instead.
    final text = Text(
      this.text,
      style: TextStyle(
        fontSize: fontSize,
        letterSpacing: fontSize * .02,
        color: label,
        height: 1.3,
      ),
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: fontSize < 11 ? 6 : 10,
        vertical: fontSize < 11 ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: border == null ? null : Border.all(color: border),
      ),
      child: leading == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(leading, size: fontSize + 1, color: icon),
                const SizedBox(width: 4),
                Flexible(child: text),
              ],
            ),
    );
  }
}

enum _TagKind { accent, neutral, danger, success, outline }

/// The one clear (✕) mark: a 22px neutral-700 circle holding an 11px `x`.
///
/// On a phone its tappable area grows to [Nocturne.touchTarget] while the circle stays 22px.
class ClearMark extends StatelessWidget {
  const ClearMark({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    final hit = Nocturne.isPhone(context)
        ? Nocturne.touchTarget
        : Nocturne.clearMarkSize;
    return Semantics(
      button: true,
      label: context.l10n.commonClear,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: hit,
          child: Center(
            child: Container(
              key: const Key('clear-mark-circle'),
              width: Nocturne.clearMarkSize,
              height: Nocturne.clearMarkSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.neutralEdge,
                shape: BoxShape.circle,
              ),
              child: Icon(FiIcons.clear, size: 11, color: c.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// The trailing label-row marker for a field filled by voice: a sparkle and "Voice".
class VoiceChip extends StatelessWidget {
  const VoiceChip({required this.fieldLabel, this.onTap, super.key});

  /// The field's name, read out as part of the button's label.
  final String fieldLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    return Semantics(
      button: true,
      label: context.l10n.themeFilledByVoice(fieldLabel),
      excludeSemantics: true,
      child: Material(
        color: c.accentFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.accentEdge),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FiIcons.voice, size: 12, color: c.accentInkStrong),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n.themeVoice,
                    style: TextStyle(fontSize: 11, color: c.accentInkStrong),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The trailing label-row marker for a field holding its default value.
class DefaultMarker extends StatelessWidget {
  const DefaultMarker({super.key});

  @override
  Widget build(BuildContext context) => _Marker(
    FiIcons.defaultValue,
    context.l10n.themeDefault,
    context.nocturne.muted(.55),
  );
}

/// The trailing label-row marker for a required field that still needs a value.
class NeededMarker extends StatelessWidget {
  const NeededMarker({super.key});

  @override
  Widget build(BuildContext context) => _Marker(
    FiIcons.needed,
    context.l10n.themeNeeded,
    context.nocturne.accentInk,
  );
}

class _Marker extends StatelessWidget {
  const _Marker(this.icon, this.text, this.color);

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 4),
      Text(text, style: TextStyle(fontSize: 11, color: color)),
    ],
  );
}

/// The Nocturne switch: 38×22 with a 12px knob, 44×26 with a 14px knob on a phone.
///
/// On, it has an accent border, an accent-900 track and an accent knob at the trailing end;
/// off, a divider border, no fill and a muted knob at the leading end.
class FiSwitch extends StatelessWidget {
  const FiSwitch({required this.value, required this.onChanged, super.key});

  final bool value;

  /// Null disables the switch.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    final phone = Nocturne.isPhone(context);
    final width = phone ? 44.0 : 38.0;
    final height = phone ? 26.0 : 22.0;
    final knob = phone ? 14.0 : 12.0;
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      onTap: enabled ? () => onChanged!(!value) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : .4,
          child: AnimatedContainer(
            key: const Key('fi-switch-track'),
            duration: const Duration(milliseconds: 150),
            width: width,
            height: height,
            // Inside the 1px border the knob sits as far from the ends as from the edges.
            padding: EdgeInsets.symmetric(horizontal: (height - 2 - knob) / 2),
            alignment: value
                ? AlignmentDirectional.centerEnd
                : AlignmentDirectional.centerStart,
            decoration: BoxDecoration(
              color: value ? c.accentFill : Colors.transparent,
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: value ? c.accent : c.divider),
            ),
            child: Container(
              key: const Key('fi-switch-knob'),
              width: knob,
              height: knob,
              decoration: BoxDecoration(
                color: value ? c.accent : c.muted(.55),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list tile with a trailing [FiSwitch]; tapping anywhere on the tile toggles it.
class FiSwitchTile extends StatelessWidget {
  const FiSwitchTile({
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.leading,
    this.contentPadding,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// A widget before the title, such as an [IconTile].
  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;

  /// A widget before the switch, such as a help button.
  final Widget? secondary;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: ListTile(
        contentPadding: contentPadding,
        enabled: enabled,
        leading: leading,
        title: title,
        subtitle: subtitle,
        onTap: enabled ? () => onChanged!(!value) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?secondary,
            if (secondary != null) const SizedBox(width: 8),
            FiSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

/// The shared icon-only button: 36×36 on wider screens, at least 44×44 on a phone.
class FiIconButton extends StatelessWidget {
  const FiIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 18,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final box = Nocturne.isPhone(context) ? Nocturne.touchTarget : 36.0;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: size, color: color),
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: box, height: box),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    );
  }
}

/// The shared card list row: at least 64px tall on a phone, sized to its content otherwise.
class CardListRow extends StatelessWidget {
  const CardListRow({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      minHeight: Nocturne.isPhone(context) ? Nocturne.phoneRowMinHeight : 0,
    ),
    child: child,
  );
}

/// The soft radial glow cards use for depth: accent-900 in one corner fading into the surface.
///
/// [rx] and [ry] are the ellipse radii as fractions of the box, as in CSS
/// `radial-gradient(rx ry at …)`; [stop] is where the surface takes over.
Gradient nocturneGlow(
  NocturneColors c, {
  Alignment center = Alignment.topLeft,
  double rx = 1.2,
  double ry = 1.4,
  double stop = .6,
}) => RadialGradient(
  center: center,
  radius: 1,
  colors: [c.accentFill, c.surface],
  stops: [0, stop],
  transform: _EllipseTransform(center, rx, ry),
);

final class _EllipseTransform extends GradientTransform {
  const _EllipseTransform(this.center, this.rx, this.ry);

  final Alignment center;
  final double rx;
  final double ry;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    // RadialGradient's radius is a fraction of the shortest side; scale it into an ellipse
    // around the gradient's own center.
    final shortest = bounds.shortestSide;
    final sx = bounds.width * rx / shortest;
    final sy = bounds.height * ry / shortest;
    final origin = center.withinRect(bounds);
    return Matrix4.diagonal3Values(sx, sy, 1)
      ..setTranslationRaw(origin.dx * (1 - sx), origin.dy * (1 - sy), 0);
  }
}

/// A surface card with the hairline edge (`.card.elev-sm`), optionally glowing.
class NocturneCard extends StatelessWidget {
  const NocturneCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.gradient,
    this.onTap,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Gradient? gradient;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    const radius = BorderRadius.all(Radius.circular(Nocturne.radius));
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: gradient == null ? c.surface : null,
          gradient: gradient,
          borderRadius: radius,
          border: Border.all(color: c.neutralFillStrong),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A dashed rounded outline, for "add another" slots.
class DashedSlot extends StatelessWidget {
  const DashedSlot({required this.child, this.onTap, super.key});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    return CustomPaint(
      painter: _DashedRRectPainter(color: c.divider),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(Nocturne.radius),
          onTap: onTap,
          child: DefaultTextStyle.merge(
            style: TextStyle(fontSize: 13, color: c.muted(.5)),
            child: IconTheme.merge(
              data: IconThemeData(color: c.muted(.5), size: 18),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dashed rounded outline in [color] around [child], marking something that needs attention.
class DashedOutline extends StatelessWidget {
  const DashedOutline({required this.child, required this.color, super.key});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashedRRectPainter(color: color),
    child: child,
  );
}

final class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(Nocturne.radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 4), paint);
        distance += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// The Fi mark, option 3b: an F built from three schema rows, the dot is the i.
class FiLogoMark extends StatelessWidget {
  const FiLogoMark({this.size = 20, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _FiMarkPainter(context.nocturne),
  );
}

final class _FiMarkPainter extends CustomPainter {
  const _FiMarkPainter(this.c);

  final NocturneColors c;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn in the mark's own 64-unit box.
    canvas.scale(size.width / 64, size.height / 64);
    void bar(double x, double y, double w, double h, Color color) =>
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, w, h),
            const Radius.circular(3.5),
          ),
          Paint()..color = color,
        );
    bar(12, 12, 7, 40, c.text);
    bar(24, 12, 28, 7, c.text);
    bar(24, 28.5, 16, 7, c.text);
    bar(24, 45, 10, 7, c.neutralGhost);
    canvas.drawCircle(const Offset(48.5, 32), 4, Paint()..color = c.accent);
  }

  @override
  bool shouldRepaint(_FiMarkPainter oldDelegate) => c != oldDelegate.c;
}

/// The mark in its 28px tile with an inset accent ring, as in the sidebar and mobile header.
class FiLogoTile extends StatelessWidget {
  const FiLogoTile({this.size = 28, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: Border.all(color: context.nocturne.accent),
    ),
    child: FiLogoMark(size: size * .72),
  );
}
