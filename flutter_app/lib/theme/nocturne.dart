import 'package:flutter/material.dart';

/// Nocturne design tokens, taken from the design system's `styles.css`.
///
/// Every color, radius and shadow in the app comes from here. The accent is a line and a glow,
/// never a flood: primary actions are outlined, and tinted fills use the dark ramp steps.
abstract final class Nocturne {
  static const bg = Color(0xFF161826);
  static const surface = Color(0xFF232532);
  static const text = Color(0xFFE9E9ED);
  static const accent = Color(0xFF9184D9);

  /// `color-mix(in srgb, text 16%, transparent)`.
  static const divider = Color(0x29E9E9ED);

  static const neutral100 = Color(0xFFF3F5FE);
  static const neutral200 = Color(0xFFE4E7F5);
  static const neutral300 = Color(0xFFCFD3E5);
  static const neutral400 = Color(0xFFB2B6CA);
  static const neutral500 = Color(0xFF9397AB);
  static const neutral600 = Color(0xFF75798C);
  static const neutral700 = Color(0xFF595D6C);
  static const neutral800 = Color(0xFF3F424D);
  static const neutral900 = Color(0xFF292B31);

  static const accent100 = Color(0xFFF5F4FF);
  static const accent200 = Color(0xFFE7E5FE);
  static const accent300 = Color(0xFFD2CEFD);
  static const accent400 = Color(0xFFB5ABFC);
  static const accent500 = Color(0xFF968AE0);
  static const accent600 = Color(0xFF796CBF);
  static const accent700 = Color(0xFF5D5294);
  static const accent800 = Color(0xFF423A6A);
  static const accent900 = Color(0xFF2B2741);

  /// The design has no error role; this muted red sits on the shared lightness scale.
  static const error = Color(0xFFE8797F);

  static const radiusSm = 4.0;
  static const radius = 8.0;
  static const radiusLg = 14.0;

  static const fontFamily = 'Inter';
  static const monoFamily = 'JetBrains Mono';

  /// The text color at [opacity], the `color-mix(text N%, transparent)` of the mocks.
  static Color muted(double opacity) => text.withValues(alpha: opacity);

  /// A hairline edge: `--shadow-sm`.
  static const shadowSm = [BoxShadow(color: neutral800, spreadRadius: 1)];

  /// An edge plus ambient darkness: `--shadow-md`.
  static const shadowMd = [
    BoxShadow(color: neutral700, spreadRadius: 1),
    BoxShadow(color: Color(0x8C000000), offset: Offset(0, 6), blurRadius: 18),
  ];

  /// The top elevation: `--shadow-lg`.
  static const shadowLg = [
    BoxShadow(color: neutral500, spreadRadius: 1),
    BoxShadow(color: Color(0xA6000000), offset: Offset(0, 16), blurRadius: 40),
  ];

  static const tabular = [FontFeature.tabularFigures()];

  /// Below this screen width the app is laid out for a phone.
  static const phoneBreakpoint = 720.0;

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

/// The one app theme. Dark only: the design has no light variant.
ThemeData nocturneTheme() {
  const scheme = ColorScheme.dark(
    primary: Nocturne.accent,
    onPrimary: Nocturne.bg,
    primaryContainer: Nocturne.accent900,
    onPrimaryContainer: Nocturne.accent200,
    secondary: Nocturne.accent300,
    onSecondary: Nocturne.bg,
    secondaryContainer: Nocturne.neutral800,
    onSecondaryContainer: Nocturne.neutral100,
    tertiary: Nocturne.accent400,
    surface: Nocturne.surface,
    onSurface: Nocturne.text,
    onSurfaceVariant: Color(0x99E9E9ED),
    surfaceContainerLowest: Nocturne.bg,
    surfaceContainerLow: Nocturne.bg,
    surfaceContainer: Nocturne.surface,
    surfaceContainerHigh: Nocturne.surface,
    surfaceContainerHighest: Nocturne.neutral800,
    surfaceTint: Colors.transparent,
    outline: Nocturne.divider,
    outlineVariant: Nocturne.neutral800,
    error: Nocturne.error,
    onError: Nocturne.bg,
    errorContainer: Color(0xFF4A2A30),
    onErrorContainer: Color(0xFFF6D3D5),
    inverseSurface: Nocturne.neutral200,
    onInverseSurface: Nocturne.bg,
    inversePrimary: Nocturne.accent700,
    shadow: Colors.black,
    scrim: Nocturne.neutral900,
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
  ).apply(bodyColor: Nocturne.text, displayColor: Nocturne.text);

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
          ? Nocturne.accent.withValues(alpha: .45)
          : Nocturne.accent,
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? Nocturne.accent.withValues(alpha: .45)
          : Nocturne.accent,
    ),
    overlayColor: overlay(Nocturne.accent, .12, .22),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? Nocturne.accent.withValues(alpha: .45)
            : Nocturne.accent,
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
      (states) => states.contains(WidgetState.disabled)
          ? Nocturne.muted(.45)
          : Nocturne.text,
    ),
    overlayColor: overlay(Nocturne.text, .07, .14),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? Nocturne.divider.withValues(alpha: .08)
            : Nocturne.divider,
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
          ? Nocturne.accent.withValues(alpha: .45)
          : Nocturne.accent,
    ),
    overlayColor: overlay(Nocturne.accent, .10, .18),
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
      color = Nocturne.error;
    } else if (states.contains(WidgetState.focused)) {
      color = Nocturne.accent;
    } else if (states.contains(WidgetState.disabled)) {
      color = Nocturne.divider.withValues(alpha: .08);
    } else if (states.contains(WidgetState.hovered)) {
      color = Nocturne.muted(.45);
    } else {
      color = Nocturne.divider;
    }
    return OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color),
    );
  });

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: Nocturne.fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: Nocturne.bg,
    canvasColor: Nocturne.surface,
    cardColor: Nocturne.surface,
    dividerColor: Nocturne.divider,
    hoverColor: Nocturne.muted(.04),
    focusColor: Nocturne.accent.withValues(alpha: .12),
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    iconTheme: const IconThemeData(color: Nocturne.text, size: 20),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Nocturne.accent,
      selectionColor: Nocturne.accent.withValues(alpha: .3),
      selectionHandleColor: Nocturne.accent,
    ),
    filledButtonTheme: FilledButtonThemeData(style: primary),
    elevatedButtonTheme: ElevatedButtonThemeData(style: primary),
    outlinedButtonTheme: OutlinedButtonThemeData(style: secondary),
    textButtonTheme: TextButtonThemeData(style: ghost),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? Nocturne.muted(.3)
              : Nocturne.muted(.75),
        ),
        overlayColor: overlay(Nocturne.text, .07, .14),
        shape: const WidgetStatePropertyAll(shape),
        minimumSize: const WidgetStatePropertyAll(Size(36, 36)),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: Nocturne.bg,
      foregroundColor: Nocturne.accent,
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
        side: BorderSide(color: Nocturne.accent),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Nocturne.surface,
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: inputBorder,
      labelStyle: style(14).copyWith(color: Nocturne.muted(.7)),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith(
        (states) => style(13).copyWith(
          color: states.contains(WidgetState.error)
              ? Nocturne.error
              : states.contains(WidgetState.focused)
              ? Nocturne.accent
              : Nocturne.muted(.7),
        ),
      ),
      hintStyle: style(14).copyWith(color: Nocturne.muted(.45)),
      helperStyle: style(11).copyWith(color: Nocturne.muted(.5)),
      errorStyle: style(12).copyWith(color: Nocturne.error),
      iconColor: Nocturne.muted(.6),
      prefixIconColor: Nocturne.muted(.6),
      suffixIconColor: Nocturne.muted(.6),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Nocturne.surface),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: Nocturne.neutral700),
          ),
        ),
      ),
    ),
    cardTheme: const CardThemeData(
      color: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: Nocturne.neutral800),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black,
      barrierColor: Nocturne.neutral900.withValues(alpha: .5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
        side: BorderSide(color: Nocturne.neutral700),
      ),
      titleTextStyle: heading(20).copyWith(color: Nocturne.text),
      contentTextStyle: style(14).copyWith(color: Nocturne.muted(.85)),
      actionsPadding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Nocturne.surface,
      modalBackgroundColor: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Nocturne.neutral900.withValues(alpha: .7),
      showDragHandle: true,
      dragHandleColor: Nocturne.divider,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Nocturne.accent800,
      labelStyle: style(11).copyWith(color: Nocturne.accent100),
      side: BorderSide.none,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Nocturne.accent
              : Nocturne.text,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Nocturne.accent.withValues(alpha: .10)
              : Colors.transparent,
        ),
        overlayColor: overlay(Nocturne.text, .07, .14),
        side: const WidgetStatePropertyAll(BorderSide(color: Nocturne.divider)),
        shape: const WidgetStatePropertyAll(shape),
        textStyle: WidgetStatePropertyAll(style(13)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        visualDensity: VisualDensity.compact,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: Nocturne.accent900,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => style(11).copyWith(
          color: states.contains(WidgetState.selected)
              ? Nocturne.accent200
              : Nocturne.muted(.6),
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 20,
          color: states.contains(WidgetState.selected)
              ? Nocturne.accent200
              : Nocturne.muted(.6),
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Nocturne.surface,
      indicatorColor: Nocturne.accent900,
      selectedIconTheme: const IconThemeData(color: Nocturne.accent200),
      unselectedIconTheme: IconThemeData(color: Nocturne.muted(.6)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Nocturne.accent
            : Nocturne.muted(.55),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Nocturne.accent900
            : Colors.transparent,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Nocturne.accent
            : Nocturne.divider,
      ),
      trackOutlineWidth: const WidgetStatePropertyAll(1),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: const WidgetStatePropertyAll(Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Nocturne.accent),
      side: WidgetStateBorderSide.resolveWith(
        (states) => BorderSide(
          width: 1.5,
          color: states.contains(WidgetState.selected)
              ? Nocturne.accent
              : Nocturne.divider,
        ),
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusSm)),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Nocturne.accent
            : Nocturne.divider,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Nocturne.divider,
      space: 1,
      thickness: 1,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: shape,
      iconColor: Nocturne.muted(.6),
      textColor: Nocturne.text,
      titleTextStyle: style(14).copyWith(color: Nocturne.text),
      subtitleTextStyle: style(12).copyWith(color: Nocturne.muted(.55)),
      selectedColor: Nocturne.accent200,
      selectedTileColor: Nocturne.accent900,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Nocturne.bg,
      foregroundColor: Nocturne.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: style(16, weight: FontWeight.w500),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: Nocturne.neutral700),
      ),
      textStyle: style(14).copyWith(color: Nocturne.text),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Nocturne.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: Nocturne.neutral700),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Nocturne.neutral800,
      contentTextStyle: style(14).copyWith(color: Nocturne.text),
      actionTextColor: Nocturne.accent300,
      behavior: SnackBarBehavior.floating,
      shape: shape,
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(
        color: Nocturne.neutral800,
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusSm)),
      ),
      textStyle: style(12).copyWith(color: Nocturne.text),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Nocturne.accent,
      linearTrackColor: Nocturne.neutral800,
      circularTrackColor: Colors.transparent,
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      contentTextStyle: style(14).copyWith(color: Nocturne.text),
      dividerColor: Nocturne.divider,
    ),
    datePickerTheme: const DatePickerThemeData(
      backgroundColor: Nocturne.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: Nocturne.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
      ),
    ),
    timePickerTheme: const TimePickerThemeData(
      backgroundColor: Nocturne.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Nocturne.radiusLg)),
      ),
    ),
  );
}
