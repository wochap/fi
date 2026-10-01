import 'package:fi/l10n/app_localizations.dart';
import 'package:intl/intl.dart';

/// Humane presentation of status metadata such as last seen and last sync.
///
/// Relative wording under 24 hours, a short local date and time beyond that,
/// in the active locale. Record values keep their exact formatting in
/// `exact_format.dart`; this is for "how recently" status lines only.
String formatStatusTime(
  AppLocalizations l,
  int? epochMs, {
  required DateTime now,
}) {
  if (epochMs == null) return l.timeNever;
  final value = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final delta = now.difference(value);
  // A negative delta is clock skew between peers; it reads as just now.
  if (delta < const Duration(minutes: 1)) return l.timeJustNow;
  if (delta < const Duration(hours: 1)) {
    return l.timeMinutesAgo(delta.inMinutes);
  }
  if (delta < const Duration(days: 1)) return l.timeHoursAgo(delta.inHours);
  final local = value.toLocal();
  final format = local.year == now.toLocal().year
      ? DateFormat.MMMEd().add_Hm()
      : DateFormat.yMMMEd().add_Hm();
  return format.format(local);
}
