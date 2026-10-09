import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const m = NocturneColors.mocha;

  test('Mocha matches the design palette', () {
    expect(m.brightness, Brightness.dark);
    expect(m.bg, const Color(0xFF1E1E2E));
    expect(m.surface, const Color(0xFF313244));
    expect(m.text, const Color(0xFFCDD6F4));
    expect(m.accent, const Color(0xFFCBA6F7));
    expect(m.divider, const Color(0x99585B70));
    expect(m.danger, const Color(0xFFF38BA8));
    expect(m.success, const Color(0xFFA6E3A1));
    expect(m.warning, const Color(0xFFF9E2AF));
    expect(m.scrim, const Color(0xA611111B));
    expect(m.section, const Color(0xFF181825));
    expect(m.sectionGlow, const Color(0xFF45475A));
    expect(m.sectionGhost, const Color(0xFF6C7086));
    expect(
      [
        m.neutral100,
        m.neutral200,
        m.neutral300,
        m.neutral400,
        m.neutral500,
        m.neutral600,
        m.neutral700,
        m.neutral800,
        m.neutral900,
      ],
      const [
        Color(0xFFCDD6F4),
        Color(0xFFBAC2DE),
        Color(0xFFA6ADC8),
        Color(0xFF9399B2),
        Color(0xFF7F849C),
        Color(0xFF6C7086),
        Color(0xFF585B70),
        Color(0xFF45475A),
        Color(0xFF313244),
      ],
    );
    expect(
      [
        m.accent100,
        m.accent200,
        m.accent300,
        m.accent400,
        m.accent500,
        m.accent600,
        m.accent700,
        m.accent800,
        m.accent900,
      ],
      const [
        Color(0xFFF5EEFE),
        Color(0xFFECDDFF),
        Color(0xFFD9C2F6),
        Color(0xFFD2B4F6),
        Color(0xFFCBA6F7),
        Color(0xFF9377B5),
        Color(0xFF5F4A76),
        Color(0xFF413350),
        Color(0xFF251E2D),
      ],
    );
    expect(m.shadowSm.single.color, const Color(0xFF585B70));
    expect(m.shadowMd.first.color, const Color(0xFF6C7086));
    expect(m.shadowLg.first.color, const Color(0xFF7F849C));
  });

  test('roles resolve to the Mocha steps', () {
    expect(m.accentFill, m.accent900);
    expect(m.accentEdge, m.accent700);
    expect(m.accentText, m.accent300);
    expect(m.accentInk, m.accent200);
    expect(m.accentInkStrong, m.accent100);
    expect(m.neutralFill, m.neutral900);
    expect(m.neutralFillStrong, m.neutral800);
    expect(m.neutralEdge, m.neutral700);
    expect(m.neutralGhost, m.neutral600);
    expect(m.neutralMuted, m.neutral500);
  });

  test('lerp of Mocha with itself is Mocha', () {
    final l = m.lerp(m, .5);
    expect(l.bg, m.bg);
    expect(l.accentFill, m.accentFill);
    expect(l.shadowMd, m.shadowMd);
    expect(l.brightness, m.brightness);
  });

  test('the theme carries the color set', () {
    final theme = nocturneTheme(m);
    expect(theme.extension<NocturneColors>(), m);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.colorScheme.error, m.danger);
    expect(theme.colorScheme.scrim, m.scrim);
  });
}
