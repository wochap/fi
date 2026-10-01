import 'package:fi/l10n/language.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _supported = [Locale('en'), Locale('es')];

void main() {
  test('resolveAppLocale picks the first English or Spanish locale', () {
    expect(
      resolveAppLocale(const [Locale('es', 'MX')], _supported),
      const Locale('es'),
    );
    expect(
      resolveAppLocale(const [
        Locale('fr', 'FR'),
        Locale('de', 'DE'),
      ], _supported),
      const Locale('en'),
    );
    expect(
      resolveAppLocale(const [
        Locale('fr', 'FR'),
        Locale('es', 'ES'),
      ], _supported),
      const Locale('es'),
    );
    expect(resolveAppLocale(null, _supported), const Locale('en'));
  });

  test('the controller persists its choice and loads it back', () async {
    final store = MemoryUiPrefsStore();
    final controller = LanguageController();
    await controller.load(store);
    expect(controller.locale, isNull);
    await controller.set(AppLanguage.spanish);
    expect(store.prefs.appLanguage, AppLanguage.spanish);

    final reloaded = LanguageController();
    await reloaded.load(store);
    expect(reloaded.value, AppLanguage.spanish);
    expect(reloaded.locale, const Locale('es'));
  });
}
