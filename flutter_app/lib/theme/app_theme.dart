import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui_prefs.dart';
import 'nocturne.dart';

/// The light theme, built once.
final ThemeData latteTheme = nocturneTheme(NocturneColors.latte);

/// The dark theme, built once.
final ThemeData mochaTheme = nocturneTheme(NocturneColors.mocha);

/// The chosen color theme. Changes apply at once and are stored in [UiPrefs].
final class AppThemeController extends ChangeNotifier {
  AppThemeMode value = AppThemeMode.system;

  /// Whether theme switches animate. Off until the frame after the stored
  /// choice is applied, so that choice never cross-fades in at start.
  bool animate = false;

  UiPrefsStore? _store;
  bool _setCalled = false;

  ThemeMode get themeMode => switch (value) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };

  /// Reads the stored choice. A [set] made meanwhile wins.
  Future<void> load(UiPrefsStore store) async {
    _store = store;
    final stored = (await store.load()).appTheme;
    if (!_setCalled) value = stored;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      animate = true;
      notifyListeners();
    });
  }

  Future<void> set(AppThemeMode mode) async {
    _setCalled = true;
    value = mode;
    notifyListeners();
    await _store?.update((p) => p.copyWith(appTheme: mode));
  }
}

/// Gives the subtree the app's [AppThemeController].
class ThemeScope extends InheritedNotifier<AppThemeController> {
  const ThemeScope({
    super.key,
    required AppThemeController super.notifier,
    required super.child,
  });

  static AppThemeController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!.notifier!;
}

/// The system bar style for a theme of [brightness]: icon brightness only.
/// Bar colors are left unset; the app draws under the bars (edge-to-edge).
SystemUiOverlayStyle systemOverlayStyle(Brightness brightness) =>
    brightness == Brightness.light
    ? const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.dark,
      )
    : const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarIconBrightness: Brightness.light,
      );
