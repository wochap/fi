import 'package:intl/intl.dart';

/// Humane presentation of status metadata such as last seen and last sync.
///
/// Relative wording under 24 hours, a short local date and time beyond that.
/// Record values keep their exact formatting in `exact_format.dart`; this is
/// for "how recently" status lines only.
String formatStatusTime(int? epochMs, {required DateTime now}) {
  if (epochMs == null) return 'never';
  final value = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final delta = now.difference(value);
  // A negative delta is clock skew between peers; it reads as just now.
  if (delta < const Duration(minutes: 1)) return 'just now';
  if (delta < const Duration(hours: 1)) return '${delta.inMinutes} min ago';
  if (delta < const Duration(days: 1)) return '${delta.inHours} h ago';
  final local = value.toLocal();
  final pattern = local.year == now.toLocal().year
      ? 'EEE d MMM HH:mm'
      : 'EEE d MMM yyyy HH:mm';
  return DateFormat(pattern).format(local);
}
