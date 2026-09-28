import 'dart:math' as math;

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/voice/controller.dart';
import 'package:flutter/material.dart';

/// The 56px round mic at the leading edge of the New record footer (mock 6).
///
/// Each state has its own icon and label: idle "Fill by voice", ready "Answer by voice",
/// listening "Stop listening", processing "Processing speech" (busy), downloading
/// "Voice model downloading, N percent". Tap toggles listening; press and hold listens until
/// release.
class VoiceMicButton extends StatelessWidget {
  const VoiceMicButton({
    required this.state,
    required this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.percent = 0,
    this.progress = .28,
    super.key,
  });

  static const size = 56.0;

  final MicState state;
  final VoidCallback? onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  /// Download percent, 0..100, for the downloading ring.
  final int percent;

  /// The processing ring's filled fraction.
  final double progress;

  String get label => switch (state) {
    MicState.idle => 'Fill by voice',
    MicState.ready => 'Answer by voice',
    MicState.listening => 'Stop listening',
    MicState.processing => 'Processing speech',
    MicState.downloading => 'Voice model downloading, $percent percent',
  };

  @override
  Widget build(BuildContext context) {
    final (icon, iconColor, iconSize) = switch (state) {
      MicState.idle => (FiIcons.microphone, Nocturne.accent, 24.0),
      MicState.ready => (FiIcons.microphone, Nocturne.accent, 24.0),
      MicState.listening => (FiIcons.stop, Nocturne.accent100, 22.0),
      MicState.processing => (FiIcons.moreHorizontal, Nocturne.accent200, 22.0),
      MicState.downloading => (FiIcons.download, Nocturne.muted(.7), 20.0),
    };
    final decoration = switch (state) {
      MicState.idle => BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Nocturne.accent),
      ),
      MicState.ready => BoxDecoration(
        shape: BoxShape.circle,
        color: Nocturne.accent900,
        border: Border.all(color: Nocturne.accent),
        boxShadow: [
          BoxShadow(
            color: Nocturne.accent.withValues(alpha: .18),
            spreadRadius: 5,
          ),
        ],
      ),
      MicState.listening => BoxDecoration(
        shape: BoxShape.circle,
        color: Nocturne.accent900,
        border: Border.all(color: Nocturne.accent, width: 2),
        boxShadow: [
          BoxShadow(
            color: Nocturne.accent.withValues(alpha: .22),
            spreadRadius: 6,
          ),
          const BoxShadow(color: Nocturne.accent700, blurRadius: 24),
        ],
      ),
      _ => const BoxDecoration(shape: BoxShape.circle),
    };
    final ring = switch (state) {
      MicState.processing => progress,
      MicState.downloading => percent / 100,
      _ => null,
    };
    final busy = state == MicState.processing;
    return Semantics(
      button: true,
      label: label,
      enabled: !busy,
      excludeSemantics: true,
      // Flutter has no aria-busy; the label says it and the button is disabled meanwhile.
      child: GestureDetector(
        key: const Key('voice-mic'),
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        onLongPressStart: busy || onHoldStart == null
            ? null
            : (_) => onHoldStart!(),
        onLongPressEnd: onHoldEnd == null ? null : (_) => onHoldEnd!(),
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: decoration,
            child: CustomPaint(
              painter: ring == null ? null : _RingPainter(ring),
              child: Center(
                child: Icon(icon, size: iconSize, color: iconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 2px conic ring: accent for [fraction], neutral700 for the rest.
class _RingPainter extends CustomPainter {
  const _RingPainter(this.fraction);

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Nocturne.neutral700;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction.clamp(0, 1),
      false,
      track..color = Nocturne.accent,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction;
}

/// A small conic progress ring, as the processing panel's "Filling fields…" step shows.
class VoiceProgressRing extends StatelessWidget {
  const VoiceProgressRing({this.fraction = .3, this.size = 20, super.key});

  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _RingPainter(fraction)),
  );
}
