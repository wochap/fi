import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// A freestanding rule that fades to transparent over 48px at each end (`.hr`).
class FadedRule extends StatelessWidget {
  const FadedRule({this.color = Nocturne.divider, this.indent = 0, super.key});

  final Color color;
  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
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

/// The small uppercase accent label above a card title (`.card-kicker`).
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontSize: 10,
      letterSpacing: 1,
      color: Nocturne.accent,
      height: 1.4,
    ),
  );
}

/// A section heading: the uppercase `h6` at 60% text.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  static const style = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.04,
    height: 1.12,
    color: Color(0x99E9E9ED),
  );

  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: style);
}

/// The live status dot: an accent point with a ring and a glow.
class GlowDot extends StatelessWidget {
  const GlowDot({
    this.size = 8,
    this.ring = true,
    this.color = Nocturne.accent,
    super.key,
  });

  final double size;
  final bool ring;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [
        if (ring) const BoxShadow(color: Nocturne.accent900, spreadRadius: 4),
        BoxShadow(color: color, blurRadius: 12),
      ],
    ),
  );
}

/// A rounded square holding one icon, tinted or outlined.
class IconTile extends StatelessWidget {
  const IconTile(
    this.icon, {
    this.size = 36,
    this.fill = Nocturne.accent900,
    this.color = Nocturne.accent200,
    this.outline,
    super.key,
  });

  final IconData icon;
  final double size;
  final Color? fill;
  final Color color;
  final Color? outline;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: outline == null ? null : Border.all(color: outline!),
    ),
    child: Icon(icon, size: size / 2, color: color),
  );
}

/// A small tinted label (`.tag`).
class Tag extends StatelessWidget {
  const Tag(
    this.text, {
    this.background = Nocturne.accent800,
    this.color = Nocturne.accent100,
    this.fontSize = 11,
    super.key,
  });

  /// `.tag-neutral`.
  const Tag.neutral(this.text, {this.fontSize = 11, super.key})
    : background = Nocturne.neutral800,
      color = Nocturne.neutral100;

  final String text;
  final Color background;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: fontSize < 11 ? 6 : 10,
      vertical: fontSize < 11 ? 1 : 3,
    ),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        letterSpacing: fontSize * .02,
        color: color,
        height: 1.3,
      ),
    ),
  );
}

/// The soft radial glow cards use for depth: accent-900 in one corner fading into the surface.
///
/// [rx] and [ry] are the ellipse radii as fractions of the box, as in CSS
/// `radial-gradient(rx ry at …)`; [stop] is where the surface takes over.
Gradient nocturneGlow({
  Alignment center = Alignment.topLeft,
  double rx = 1.2,
  double ry = 1.4,
  double stop = .6,
}) => RadialGradient(
  center: center,
  radius: 1,
  colors: const [Nocturne.accent900, Nocturne.surface],
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
    const radius = BorderRadius.all(Radius.circular(Nocturne.radius));
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: gradient == null ? Nocturne.surface : null,
          gradient: gradient,
          borderRadius: radius,
          border: Border.all(color: Nocturne.neutral800),
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
  Widget build(BuildContext context) => CustomPaint(
    painter: const _DashedRRectPainter(),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        onTap: onTap,
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 13, color: Nocturne.muted(.5)),
          child: IconTheme.merge(
            data: IconThemeData(color: Nocturne.muted(.5), size: 18),
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );
}

final class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter();

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
      ..color = Nocturne.divider
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
  bool shouldRepaint(_DashedRRectPainter oldDelegate) => false;
}

/// The Fi mark, option 3b: an F built from three schema rows, the dot is the i.
class FiLogoMark extends StatelessWidget {
  const FiLogoMark({this.size = 20, super.key});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: const _FiMarkPainter());
}

final class _FiMarkPainter extends CustomPainter {
  const _FiMarkPainter();

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
    bar(12, 12, 7, 40, Nocturne.text);
    bar(24, 12, 28, 7, Nocturne.text);
    bar(24, 28.5, 16, 7, Nocturne.text);
    bar(24, 45, 10, 7, Nocturne.neutral600);
    canvas.drawCircle(
      const Offset(48.5, 32),
      4,
      Paint()..color = Nocturne.accent,
    );
  }

  @override
  bool shouldRepaint(_FiMarkPainter oldDelegate) => false;
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
      border: Border.all(color: Nocturne.accent),
    ),
    child: FiLogoMark(size: size * .72),
  );
}
