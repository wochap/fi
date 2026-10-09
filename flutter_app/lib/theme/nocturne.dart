import 'package:flutter/material.dart';

/// Nocturne design tokens, taken from the design system's `styles.css`.
///
/// Every color, radius and shadow in the app comes from here. The accent is a line and a glow,
/// never a flood: primary actions are outlined, and tinted fills use the dark ramp steps.
/// One theme's colors and shadows, taken from the design system's `styles.css`.
///
/// Read it with `context.nocturne`. Call sites use the theme tokens and the theme-relative
/// roles; the numbered ramps exist for the theme builder only.
@immutable
class NocturneColors extends ThemeExtension<NocturneColors> {
  const NocturneColors({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.text,
    required this.accent,
    required this.divider,
    required this.danger,
    required this.dangerTint,
    required this.success,
    required this.warning,
    required this.scrim,
    required this.section,
    required this.sectionGlow,
    required this.sectionGhost,
    required this.neutral100,
    required this.neutral200,
    required this.neutral300,
    required this.neutral400,
    required this.neutral500,
    required this.neutral600,
    required this.neutral700,
    required this.neutral800,
    required this.neutral900,
    required this.accent100,
    required this.accent200,
    required this.accent300,
    required this.accent400,
    required this.accent500,
    required this.accent600,
    required this.accent700,
    required this.accent800,
    required this.accent900,
    required this.accentFill,
    required this.accentEdge,
    required this.accentText,
    required this.accentInk,
    required this.accentInkStrong,
    required this.neutralFill,
    required this.neutralFillStrong,
    required this.neutralEdge,
    required this.neutralGhost,
    required this.neutralMuted,
    required this.shadowSm,
    required this.shadowMd,
    required this.shadowLg,
  });

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color text;
  final Color accent;

  /// `color-mix(in srgb, surface2 60%, transparent)`.
  final Color divider;
  final Color danger;

  /// [danger] at low alpha, the fill behind danger-tinted marks.
  final Color dangerTint;
  final Color success;
  final Color warning;

  /// The backdrop behind dialogs and sheets.
  final Color scrim;
  final Color section;
  final Color sectionGlow;
  final Color sectionGhost;
  final Color neutral100;
  final Color neutral200;
  final Color neutral300;
  final Color neutral400;
  final Color neutral500;
  final Color neutral600;
  final Color neutral700;
  final Color neutral800;
  final Color neutral900;
  final Color accent100;
  final Color accent200;
  final Color accent300;
  final Color accent400;
  final Color accent500;
  final Color accent600;
  final Color accent700;
  final Color accent800;
  final Color accent900;

  /// A tinted accent fill (selected rows, chips, the switch track).
  final Color accentFill;

  /// An accent border or inner ring.
  final Color accentEdge;

  /// Accent text at paragraph size.
  final Color accentText;

  /// Small accent labels and icons on a fill.
  final Color accentInk;

  /// Text on an accent fill.
  final Color accentInkStrong;

  /// A quiet neutral fill.
  final Color neutralFill;

  /// A stronger neutral fill (neutral tags, tooltips).
  final Color neutralFillStrong;

  /// A neutral border.
  final Color neutralEdge;

  /// A dim or ghosted mark.
  final Color neutralGhost;

  /// Muted chrome.
  final Color neutralMuted;

  /// A hairline edge: `--shadow-sm`.
  final List<BoxShadow> shadowSm;

  /// An edge plus ambient darkness: `--shadow-md`.
  final List<BoxShadow> shadowMd;

  /// The top elevation: `--shadow-lg`.
  final List<BoxShadow> shadowLg;

  /// The text color at [opacity], the `color-mix(text N%, transparent)` of the mocks.
  Color muted(double opacity) => text.withValues(alpha: opacity);

  /// Catppuccin Mocha, the dark theme.
  static const mocha = NocturneColors(
    brightness: Brightness.dark,
    bg: Color(0xFF1E1E2E),
    surface: Color(0xFF313244),
    text: Color(0xFFCDD6F4),
    accent: Color(0xFFCBA6F7),
    divider: Color(0x99585B70),
    danger: Color(0xFFF38BA8),
    dangerTint: Color(0x29F38BA8),
    success: Color(0xFFA6E3A1),
    warning: Color(0xFFF9E2AF),
    scrim: Color(0xA611111B),
    section: Color(0xFF181825),
    sectionGlow: Color(0xFF45475A),
    sectionGhost: Color(0xFF6C7086),
    neutral100: Color(0xFFCDD6F4),
    neutral200: Color(0xFFBAC2DE),
    neutral300: Color(0xFFA6ADC8),
    neutral400: Color(0xFF9399B2),
    neutral500: Color(0xFF7F849C),
    neutral600: Color(0xFF6C7086),
    neutral700: Color(0xFF585B70),
    neutral800: Color(0xFF45475A),
    neutral900: Color(0xFF313244),
    accent100: Color(0xFFF5EEFE),
    accent200: Color(0xFFECDDFF),
    accent300: Color(0xFFD9C2F6),
    accent400: Color(0xFFD2B4F6),
    accent500: Color(0xFFCBA6F7),
    accent600: Color(0xFF9377B5),
    accent700: Color(0xFF5F4A76),
    accent800: Color(0xFF413350),
    accent900: Color(0xFF251E2D),
    accentFill: Color(0xFF251E2D),
    accentEdge: Color(0xFF5F4A76),
    accentText: Color(0xFFD9C2F6),
    accentInk: Color(0xFFECDDFF),
    accentInkStrong: Color(0xFFF5EEFE),
    neutralFill: Color(0xFF313244),
    neutralFillStrong: Color(0xFF45475A),
    neutralEdge: Color(0xFF585B70),
    neutralGhost: Color(0xFF6C7086),
    neutralMuted: Color(0xFF7F849C),
    shadowSm: [BoxShadow(color: Color(0xFF585B70), spreadRadius: 1)],
    shadowMd: [
      BoxShadow(color: Color(0xFF6C7086), spreadRadius: 1),
      BoxShadow(color: Color(0x8C000000), offset: Offset(0, 6), blurRadius: 18),
    ],
    shadowLg: [
      BoxShadow(color: Color(0xFF7F849C), spreadRadius: 1),
      BoxShadow(
        color: Color(0xA6000000),
        offset: Offset(0, 16),
        blurRadius: 40,
      ),
    ],
  );

  /// Catppuccin Latte, the light theme.
  static const latte = NocturneColors(
    brightness: Brightness.light,
    bg: Color(0xFFEFF1F5),
    surface: Color(0xFFCCD0DA),
    text: Color(0xFF4C4F69),
    accent: Color(0xFF8839EF),
    divider: Color(0x99ACB0BE),
    danger: Color(0xFFD20F39),
    dangerTint: Color(0x29D20F39),
    success: Color(0xFF40A02B),
    warning: Color(0xFFDF8E1D),
    scrim: Color(0x664C4F69),
    section: Color(0xFFE6E9EF),
    sectionGlow: Color(0xFFBCC0CC),
    sectionGhost: Color(0xFF9CA0B0),
    neutral100: Color(0xFFEFF1F5),
    neutral200: Color(0xFFE6E9EF),
    neutral300: Color(0xFFDCE0E8),
    neutral400: Color(0xFFCCD0DA),
    neutral500: Color(0xFFBCC0CC),
    neutral600: Color(0xFFACB0BE),
    neutral700: Color(0xFF9CA0B0),
    neutral800: Color(0xFF8C8FA1),
    neutral900: Color(0xFF7C7F93),
    accent100: Color(0xFFF3EFFE),
    accent200: Color(0xFFE7DFFF),
    accent300: Color(0xFFD3C3FF),
    accent400: Color(0xFFAC83FE),
    accent500: Color(0xFF8839EF),
    accent600: Color(0xFF743BC7),
    accent700: Color(0xFF613BA0),
    accent800: Color(0xFF422A6B),
    accent900: Color(0xFF251A3C),
    accentFill: Color(0xFFE7DFFF),
    accentEdge: Color(0xFFAC83FE),
    accentText: Color(0xFF613BA0),
    accentInk: Color(0xFF422A6B),
    accentInkStrong: Color(0xFF251A3C),
    neutralFill: Color(0xFFCCD0DA),
    neutralFillStrong: Color(0xFFBCC0CC),
    neutralEdge: Color(0xFFACB0BE),
    neutralGhost: Color(0xFF9CA0B0),
    neutralMuted: Color(0xFF8C8FA1),
    shadowSm: [BoxShadow(color: Color(0xFFCCD0DA), spreadRadius: 1)],
    shadowMd: [
      BoxShadow(color: Color(0xFFBCC0CC), spreadRadius: 1),
      BoxShadow(color: Color(0x244C4F69), offset: Offset(0, 6), blurRadius: 18),
    ],
    shadowLg: [
      BoxShadow(color: Color(0xFFACB0BE), spreadRadius: 1),
      BoxShadow(
        color: Color(0x334C4F69),
        offset: Offset(0, 16),
        blurRadius: 40,
      ),
    ],
  );

  @override
  NocturneColors copyWith({
    Brightness? brightness,
    Color? bg,
    Color? surface,
    Color? text,
    Color? accent,
    Color? divider,
    Color? danger,
    Color? dangerTint,
    Color? success,
    Color? warning,
    Color? scrim,
    Color? section,
    Color? sectionGlow,
    Color? sectionGhost,
    Color? neutral100,
    Color? neutral200,
    Color? neutral300,
    Color? neutral400,
    Color? neutral500,
    Color? neutral600,
    Color? neutral700,
    Color? neutral800,
    Color? neutral900,
    Color? accent100,
    Color? accent200,
    Color? accent300,
    Color? accent400,
    Color? accent500,
    Color? accent600,
    Color? accent700,
    Color? accent800,
    Color? accent900,
    Color? accentFill,
    Color? accentEdge,
    Color? accentText,
    Color? accentInk,
    Color? accentInkStrong,
    Color? neutralFill,
    Color? neutralFillStrong,
    Color? neutralEdge,
    Color? neutralGhost,
    Color? neutralMuted,
    List<BoxShadow>? shadowSm,
    List<BoxShadow>? shadowMd,
    List<BoxShadow>? shadowLg,
  }) => NocturneColors(
    brightness: brightness ?? this.brightness,
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    text: text ?? this.text,
    accent: accent ?? this.accent,
    divider: divider ?? this.divider,
    danger: danger ?? this.danger,
    dangerTint: dangerTint ?? this.dangerTint,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    scrim: scrim ?? this.scrim,
    section: section ?? this.section,
    sectionGlow: sectionGlow ?? this.sectionGlow,
    sectionGhost: sectionGhost ?? this.sectionGhost,
    neutral100: neutral100 ?? this.neutral100,
    neutral200: neutral200 ?? this.neutral200,
    neutral300: neutral300 ?? this.neutral300,
    neutral400: neutral400 ?? this.neutral400,
    neutral500: neutral500 ?? this.neutral500,
    neutral600: neutral600 ?? this.neutral600,
    neutral700: neutral700 ?? this.neutral700,
    neutral800: neutral800 ?? this.neutral800,
    neutral900: neutral900 ?? this.neutral900,
    accent100: accent100 ?? this.accent100,
    accent200: accent200 ?? this.accent200,
    accent300: accent300 ?? this.accent300,
    accent400: accent400 ?? this.accent400,
    accent500: accent500 ?? this.accent500,
    accent600: accent600 ?? this.accent600,
    accent700: accent700 ?? this.accent700,
    accent800: accent800 ?? this.accent800,
    accent900: accent900 ?? this.accent900,
    accentFill: accentFill ?? this.accentFill,
    accentEdge: accentEdge ?? this.accentEdge,
    accentText: accentText ?? this.accentText,
    accentInk: accentInk ?? this.accentInk,
    accentInkStrong: accentInkStrong ?? this.accentInkStrong,
    neutralFill: neutralFill ?? this.neutralFill,
    neutralFillStrong: neutralFillStrong ?? this.neutralFillStrong,
    neutralEdge: neutralEdge ?? this.neutralEdge,
    neutralGhost: neutralGhost ?? this.neutralGhost,
    neutralMuted: neutralMuted ?? this.neutralMuted,
    shadowSm: shadowSm ?? this.shadowSm,
    shadowMd: shadowMd ?? this.shadowMd,
    shadowLg: shadowLg ?? this.shadowLg,
  );

  @override
  NocturneColors lerp(NocturneColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    List<BoxShadow> s(List<BoxShadow> a, List<BoxShadow> b) =>
        BoxShadow.lerpList(a, b, t)!;
    return NocturneColors(
      brightness: t < .5 ? brightness : other.brightness,
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      text: c(text, other.text),
      accent: c(accent, other.accent),
      divider: c(divider, other.divider),
      danger: c(danger, other.danger),
      dangerTint: c(dangerTint, other.dangerTint),
      success: c(success, other.success),
      warning: c(warning, other.warning),
      scrim: c(scrim, other.scrim),
      section: c(section, other.section),
      sectionGlow: c(sectionGlow, other.sectionGlow),
      sectionGhost: c(sectionGhost, other.sectionGhost),
      neutral100: c(neutral100, other.neutral100),
      neutral200: c(neutral200, other.neutral200),
      neutral300: c(neutral300, other.neutral300),
      neutral400: c(neutral400, other.neutral400),
      neutral500: c(neutral500, other.neutral500),
      neutral600: c(neutral600, other.neutral600),
      neutral700: c(neutral700, other.neutral700),
      neutral800: c(neutral800, other.neutral800),
      neutral900: c(neutral900, other.neutral900),
      accent100: c(accent100, other.accent100),
      accent200: c(accent200, other.accent200),
      accent300: c(accent300, other.accent300),
      accent400: c(accent400, other.accent400),
      accent500: c(accent500, other.accent500),
      accent600: c(accent600, other.accent600),
      accent700: c(accent700, other.accent700),
      accent800: c(accent800, other.accent800),
      accent900: c(accent900, other.accent900),
      accentFill: c(accentFill, other.accentFill),
      accentEdge: c(accentEdge, other.accentEdge),
      accentText: c(accentText, other.accentText),
      accentInk: c(accentInk, other.accentInk),
      accentInkStrong: c(accentInkStrong, other.accentInkStrong),
      neutralFill: c(neutralFill, other.neutralFill),
      neutralFillStrong: c(neutralFillStrong, other.neutralFillStrong),
      neutralEdge: c(neutralEdge, other.neutralEdge),
      neutralGhost: c(neutralGhost, other.neutralGhost),
      neutralMuted: c(neutralMuted, other.neutralMuted),
      shadowSm: s(shadowSm, other.shadowSm),
      shadowMd: s(shadowMd, other.shadowMd),
      shadowLg: s(shadowLg, other.shadowLg),
    );
  }
}

extension NocturneContext on BuildContext {
  /// The color set of the current theme; Mocha under a theme built without one.
  NocturneColors get nocturne =>
      Theme.of(this).extension<NocturneColors>() ?? NocturneColors.mocha;
}

/// Nocturne's theme-independent tokens: radii, fonts, sizes and breakpoints.
abstract final class Nocturne {
  static const radiusSm = 4.0;
  static const radius = 8.0;
  static const radiusLg = 14.0;

  static const fontFamily = 'Inter';
  static const monoFamily = 'JetBrains Mono';

  static const tabular = [FontFeature.tabularFigures()];

  /// Below this screen width the app is laid out for a phone.
  static const phoneBreakpoint = 720.0;

  /// The smallest tappable area on a phone.
  static const touchTarget = 44.0;

  /// The smallest height of a card list row on a phone.
  static const phoneRowMinHeight = 64.0;

  /// The drawn diameter of the clear (✕) mark.
  static const clearMarkSize = 22.0;

  /// Whether this screen is laid out for a phone.
  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < phoneBreakpoint;

  /// The box height of a shared input (`lib/theme/inputs.dart`) of [size] on this screen:
  /// small is 32 (40 on a phone), normal is 40 (48 on a phone).
  static double inputHeight(BuildContext context, InputSize size) {
    final phone = MediaQuery.sizeOf(context).width < phoneBreakpoint;
    return switch (size) {
      InputSize.small => phone ? 40 : 32,
      InputSize.normal => phone ? 48 : 40,
    };
  }
}

/// The two input heights: [normal] for form fields, [small] for inline builder rows
/// (expression builder nodes, query builder conditions).
enum InputSize { small, normal }

/// The app theme built from the color set [c].
ThemeData nocturneTheme(NocturneColors c) {
  final scheme = ColorScheme(
    brightness: c.brightness,
    primary: c.accent,
    onPrimary: c.bg,
    primaryContainer: c.accentFill,
    onPrimaryContainer: c.accentInk,
    secondary: c.accentText,
    onSecondary: c.bg,
    secondaryContainer: c.neutralFillStrong,
    onSecondaryContainer: c.text,
    tertiary: c.accentText,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.muted(.6),
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.bg,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surface,
    surfaceContainerHighest: c.neutralFillStrong,
    surfaceTint: Colors.transparent,
    outline: c.divider,
    outlineVariant: c.neutralFillStrong,
    error: c.danger,
    onError: c.bg,
    errorContainer: c.dangerTint,
    onErrorContainer: c.danger,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    inversePrimary: c.accentEdge,
    shadow: const Color(0xFF000000),
    scrim: c.scrim,
  );

  TextStyle style(double size, {FontWeight weight = FontWeight.w400}) =>
      TextStyle(
        fontFamily: Nocturne.fontFamily,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: 0,
        height: 1.4,
      );
  TextStyle heading(double size) => style(
    size,
    weight: FontWeight.w500,
  ).copyWith(height: 1.12, letterSpacing: -0.015 * size);

  final textTheme = TextTheme(
    displayLarge: heading(57),
    displayMedium: heading(45),
    displaySmall: heading(36),
    headlineLarge: heading(42),
    headlineMedium: heading(32),
    headlineSmall: heading(25),
    titleLarge: heading(20),
    // Material reads titleMedium for a dropdown's value and bodyLarge for a text field's, and
    // Nocturne sets both at the input's 14px; card titles set their 17px directly.
    titleMedium: style(14),
    titleSmall: style(14, weight: FontWeight.w500),
    bodyLarge: style(14),
    bodyMedium: style(14),
    bodySmall: style(12),
    labelLarge: style(14, weight: FontWeight.w500),
    labelMedium: style(13),
    labelSmall: style(11),
  ).apply(bodyColor: c.text, displayColor: c.text);

  const radius = BorderRadius.all(Radius.circular(Nocturne.radius));
  const shape = RoundedRectangleBorder(borderRadius: radius);
  final buttonText = style(14, weight: FontWeight.w500);

  WidgetStateProperty<Color?> overlay(Color base, double hover, double press) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return base.withValues(alpha: press);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return base.withValues(alpha: hover);
        }
        return null;
      });

  // `.btn-primary`: an accent outline on transparent, never a fill. It stays a FilledButton so
  // the one primary action per surface is still the filled type in code.
  final primary = ButtonStyle(
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? c.accent.withValues(alpha: .45)
          : c.accent,
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? c.accent.withValues(alpha: .45)
          : c.accent,
    ),
    overlayColor: overlay(c.accent, .12, .22),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? c.accent.withValues(alpha: .45)
            : c.accent,
      ),
    ),
    shape: const WidgetStatePropertyAll(shape),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    iconSize: const WidgetStatePropertyAll(16),
    textStyle: WidgetStatePropertyAll(buttonText),
  );

  // `.btn-secondary`: a divider outline in the text color.
  final secondary = ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? c.muted(.45) : c.text,
    ),
    overlayColor: overlay(c.text, .07, .14),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? c.divider.withValues(alpha: .08)
            : c.divider,
      ),
    ),
    shape: const WidgetStatePropertyAll(shape),
    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    ),
    iconSize: const WidgetStatePropertyAll(16),
    textStyle: WidgetStatePropertyAll(buttonText),
  );

  // `.btn-ghost`: accent text, a tint on hover.
  final ghost = ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? c.accent.withValues(alpha: .45)
          : c.accent,
    ),
    overlayColor: overlay(c.accent, .10, .18),
    shape: const WidgetStatePropertyAll(shape),
    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    iconSize: const WidgetStatePropertyAll(16),
    textStyle: WidgetStatePropertyAll(buttonText),
  );

  final inputBorder = WidgetStateInputBorder.resolveWith((states) {
    final Color color;
    if (states.contains(WidgetState.error)) {
      // A field error is marked by the accent border, beside its warning icon and message.
      color = c.accent;
    } else if (states.contains(WidgetState.focused)) {
      color = c.accent;
    } else if (states.contains(WidgetState.disabled)) {
      color = c.divider.withValues(alpha: .08);
    } else if (states.contains(WidgetState.hovered)) {
      color = c.muted(.45);
    } else {
      color = c.divider;
    }
    return OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color),
    );
  });

  return ThemeData(
    extensions: [c],
    useMaterial3: true,
    brightness: c.brightness,
    colorScheme: scheme,
    fontFamily: Nocturne.fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.surface,
    cardColor: c.surface,
    dividerColor: c.divider,
    hoverColor: c.muted(.04),
    focusColor: c.accent.withValues(alpha: .12),
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    iconTheme: IconThemeData(color: c.text, size: 20),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: .3),
      selectionHandleColor: c.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(style: primary),
    elevatedButtonTheme: ElevatedButtonThemeData(style: primary),
    outlinedButtonTheme: OutlinedButtonThemeData(style: secondary),
    textButtonTheme: TextButtonThemeData(style: ghost),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? c.muted(.3)
              : c.muted(.75),
        ),
        overlayColor: overlay(c.text, .07, .14),
        shape: const WidgetStatePropertyAll(shape),
        minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.bg,
      foregroundColor: c.accent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      extendedTextStyle: TextStyle(
        fontFamily: Nocturne.fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: c.accent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: inputBorder,
      labelStyle: style(14).copyWith(color: c.muted(.7)),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => style(13).copyWith(
          color: states.contains(WidgetState.error)
              ? c.danger
              : states.contains(WidgetState.focused)
              ? c.accent
              : c.muted(.7),
        ),
      ),
      hintStyle: style(14).copyWith(color: c.muted(.45)),
      helperStyle: style(11).copyWith(color: c.muted(.5)),
      errorStyle: style(12).copyWith(color: c.danger),
      iconColor: c.muted(.6),
      prefixIconColor: c.muted(.6),
      suffixIconColor: c.muted(.6),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: c.neutralEdge),
          ),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: c.neutralFillStrong),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: const Color(0xFF000000),
      barrierColor: c.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
        side: BorderSide(color: c.neutralEdge),
      ),
      titleTextStyle: heading(20).copyWith(color: c.text),
      contentTextStyle: style(14).copyWith(color: c.muted(.85)),
      actionsPadding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      modalBackgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: c.scrim,
      showDragHandle: true,
      dragHandleColor: c.divider,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.accentFill,
      labelStyle: style(11).copyWith(color: c.accentInkStrong),
      side: BorderSide.none,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.accent : c.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? c.accent.withValues(alpha: .10)
              : Colors.transparent,
        ),
        overlayColor: overlay(c.text, .07, .14),
        side: WidgetStatePropertyAll(BorderSide(color: c.divider)),
        shape: const WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(style(13)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        visualDensity: VisualDensity.compact,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: c.accentFill,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => style(11).copyWith(
          color: states.contains(WidgetState.selected)
              ? c.accentInk
              : c.muted(.6),
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 20,
          color: states.contains(WidgetState.selected)
              ? c.accentInk
              : c.muted(.6),
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentFill,
      selectedIconTheme: IconThemeData(color: c.accentInk),
      unselectedIconTheme: IconThemeData(color: c.muted(.6)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.accent : c.muted(.55),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? c.accentFill
            : Colors.transparent,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.accent : c.divider,
      ),
      trackOutlineWidth: const WidgetStatePropertyAll(1),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: const WidgetStatePropertyAll(Colors.transparent),
      checkColor: WidgetStatePropertyAll(c.accent),
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          width: 1.5,
          color: states.contains(WidgetState.selected) ? c.accent : c.divider,
        ),
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusSm)),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.accent : c.divider,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.divider, space: 1, thickness: 1),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: shape,
      iconColor: c.muted(.6),
      textColor: c.text,
      titleTextStyle: style(14).copyWith(color: c.text),
      subtitleTextStyle: style(12).copyWith(color: c.muted(.55)),
      selectedColor: c.accentInk,
      selectedTileColor: c.accentFill,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: style(16, weight: FontWeight.w500),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: c.neutralEdge),
      ),
      textStyle: style(14).copyWith(color: c.text),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: c.neutralEdge),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.neutralFillStrong,
      contentTextStyle: style(14).copyWith(color: c.text),
      actionTextColor: c.accentText,
      behavior: SnackBarBehavior.floating,
      shape: shape,
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.neutralFillStrong,
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusSm)),
      ),
      textStyle: style(12).copyWith(color: c.text),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.neutralFillStrong,
      circularTrackColor: Colors.transparent,
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      contentTextStyle: style(14).copyWith(color: c.text),
      dividerColor: c.divider,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
      ),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
      ),
    ),
  );
}
