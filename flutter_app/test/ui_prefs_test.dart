import 'package:fi/ui_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app language survives a JSON round trip', () {
    for (final language in AppLanguage.values) {
      final prefs = UiPrefs(appLanguage: language, handsFree: true);
      final read = UiPrefs.fromJson(prefs.toJson());
      expect(read.appLanguage, language);
      expect(read.handsFree, isTrue);
    }
  });

  test('a missing app language reads as the system language', () {
    expect(
      UiPrefs.fromJson({'collection_sort': 'name'}).appLanguage,
      AppLanguage.system,
    );
  });

  test('an unknown app language reads as the system language', () {
    expect(
      UiPrefs.fromJson({'app_language': 'fr'}).appLanguage,
      AppLanguage.system,
    );
  });
}
