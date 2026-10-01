import 'package:flutter/widgets.dart';

import '../ui_prefs.dart';

/// The interface language for the system's [preferred] locales: the first one
/// in English or Spanish, else English.
Locale resolveAppLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  for (final locale in preferred ?? const <Locale>[]) {
    final code = locale.languageCode;
    if (code == 'en' || code == 'es') return Locale(code);
  }
  return const Locale('en');
}

/// The chosen interface language. Changes apply at once and are stored in
/// [UiPrefs].
final class LanguageController extends ChangeNotifier {
  AppLanguage value = AppLanguage.system;

  UiPrefsStore? _store;
  bool _setCalled = false;

  /// The forced locale, or null to follow the system.
  Locale? get locale => switch (value) {
    AppLanguage.system => null,
    AppLanguage.english => const Locale('en'),
    AppLanguage.spanish => const Locale('es'),
  };

  /// Reads the stored choice. A [set] made meanwhile wins.
  Future<void> load(UiPrefsStore store) async {
    _store = store;
    final stored = (await store.load()).appLanguage;
    if (_setCalled || stored == value) return;
    value = stored;
    notifyListeners();
  }

  Future<void> set(AppLanguage language) async {
    _setCalled = true;
    value = language;
    notifyListeners();
    await _store?.update((p) => p.copyWith(appLanguage: language));
  }
}

/// Gives the subtree the app's [LanguageController].
class LanguageScope extends InheritedNotifier<LanguageController> {
  const LanguageScope({
    super.key,
    required LanguageController super.notifier,
    required super.child,
  });

  static LanguageController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()!.notifier!;
}
