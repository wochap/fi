import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

extension L10nContext on BuildContext {
  /// Localized strings for this context. Falls back to English when the
  /// tree has no localization delegates (bare `MaterialApp` in tests).
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? lookupAppLocalizations(const Locale('en'));
}

/// The name of a UI language in that language. Never translated.
String languageEndonym(String code) => code == 'es' ? 'Español' : 'English';

/// The decimal separator of the active locale ("." in English, "," in Spanish).
String decimalSeparatorOf(BuildContext context) => NumberFormat.decimalPattern(
  Localizations.maybeLocaleOf(context)?.languageCode ?? 'en',
).symbols.DECIMAL_SEP;
