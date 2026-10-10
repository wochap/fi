import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:intl/intl.dart';

/// Exact presentation of a typed bridge value.
///
/// Signed decimals never pass through a double: the scaled integer representation and its scale
/// are formatted directly, so `257650` at scale 2 always renders `2576.50`. Only chart drawing
/// coordinates may convert to `double`, and those are rendering artifacts, never stored or
/// aggregated values.
sealed class ExactValue {
  const ExactValue();

  /// The exact human-readable representation; [decimalSeparator] is the active locale's.
  String label(AppLocalizations l, {String decimalSeparator = '.'});

  /// The value as a drawing coordinate. The only place a double appears.
  double get coordinate;

  bool get isNumeric;
}

final class ExactMissing extends ExactValue {
  const ExactMissing();
  @override
  String label(AppLocalizations l, {String decimalSeparator = '.'}) => '—';
  @override
  double get coordinate => 0;
  @override
  bool get isNumeric => false;
}

final class ExactText extends ExactValue {
  const ExactText(this.text);
  final String text;
  @override
  String label(AppLocalizations l, {String decimalSeparator = '.'}) => text;
  @override
  double get coordinate => 0;
  @override
  bool get isNumeric => false;
}

final class ExactBoolean extends ExactValue {
  const ExactBoolean(this.value);
  final bool value;
  @override
  String label(AppLocalizations l, {String decimalSeparator = '.'}) =>
      value ? l.commonYes : l.commonNo;
  @override
  double get coordinate => value ? 1 : 0;
  @override
  bool get isNumeric => false;
}

/// An exact scaled integer. `representation` is the stored minor-unit value.
final class ExactDecimal extends ExactValue {
  const ExactDecimal(this.representation, this.scale);

  final int representation;
  final int scale;

  @override
  String label(AppLocalizations l, {String decimalSeparator = '.'}) =>
      formatScaled(representation, scale, decimalSeparator: decimalSeparator);

  @override
  double get coordinate => representation / pow10(scale);

  @override
  bool get isNumeric => true;
}

/// A plain signed integer: a count, a UTC epoch day, epoch milliseconds, or a duration.
final class ExactInteger extends ExactValue {
  const ExactInteger(this.value, {this.formatter});

  final int value;
  final ExactIntegerFormatter? formatter;

  @override
  String label(AppLocalizations l, {String decimalSeparator = '.'}) =>
      switch (formatter) {
        null => '$value',
        ExactIntegerFormatter.date => formatDate(value),
        ExactIntegerFormatter.dateTime => formatDateTime(value),
        ExactIntegerFormatter.duration => formatDuration(value),
      };

  @override
  double get coordinate => value.toDouble();

  @override
  bool get isNumeric => true;
}

enum ExactIntegerFormatter { date, dateTime, duration }

/// Converts one typed bridge value into its exact presentation. `enumLabels` maps an enum option
/// id to its label so category axes stay readable while the underlying value stays exact.
ExactValue exactFromTypedValue(
  TypedValueDto? value, {
  Map<String, String>? enumLabels,
}) {
  if (value == null) return const ExactMissing();
  final type = value.valueType.kind;
  final scale = value.valueType.scale ?? 0;
  return switch (type) {
    ValueTypeKindDto.null_ => const ExactMissing(),
    ValueTypeKindDto.text => ExactText(value.textValue ?? ''),
    ValueTypeKindDto.enum_ => ExactText(
      enumLabels?[value.textValue] ?? value.textValue ?? '',
    ),
    ValueTypeKindDto.enumSet =>
      value.listValue.isEmpty
          ? const ExactMissing()
          : ExactText(
              value.listValue.map((id) => enumLabels?[id] ?? id).join(', '),
            ),
    ValueTypeKindDto.boolean => ExactBoolean(value.booleanValue ?? false),
    ValueTypeKindDto.integer => ExactInteger(value.integerValue ?? 0),
    ValueTypeKindDto.fixedDecimal => ExactDecimal(
      value.integerValue ?? 0,
      scale,
    ),
    ValueTypeKindDto.date => ExactInteger(
      value.integerValue ?? 0,
      formatter: ExactIntegerFormatter.date,
    ),
    ValueTypeKindDto.dateTime => ExactInteger(
      value.integerValue ?? 0,
      formatter: ExactIntegerFormatter.dateTime,
    ),
    ValueTypeKindDto.duration => ExactInteger(
      value.integerValue ?? 0,
      formatter: ExactIntegerFormatter.duration,
    ),
  };
}

/// Formats a scaled integer exactly, without a double intermediate.
String formatScaled(
  int representation,
  int scale, {
  String decimalSeparator = '.',
}) {
  final negative = representation < 0;
  final digits = BigInt.from(
    representation,
  ).abs().toString().padLeft(scale + 1, '0');
  final value = scale == 0
      ? digits
      : '${digits.substring(0, digits.length - scale)}$decimalSeparator${digits.substring(digits.length - scale)}';
  return negative ? '-$value' : value;
}

/// Parses a decimal string into an exact scaled integer, rejecting precision the scale cannot hold.
/// Accepts [decimalSeparator] and `.` as the separator.
int? parseScaled(String input, int scale, {String decimalSeparator = '.'}) {
  final normalized = decimalSeparator == '.'
      ? input
      : input.replaceFirst(decimalSeparator, '.');
  final match = RegExp(
    r'^([+-]?)([0-9]+)(?:\.([0-9]*))?$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final fraction = match.group(3) ?? '';
  if (fraction.length > scale) return null;
  final padded = (fraction + '0' * scale).substring(0, scale);
  final magnitude =
      BigInt.parse(match.group(2)!) * BigInt.from(10).pow(scale) +
      BigInt.parse(padded.isEmpty ? '0' : padded);
  final signed = match.group(1) == '-' ? -magnitude : magnitude;
  final min = BigInt.from(-9223372036854775807) - BigInt.one;
  final max = BigInt.from(9223372036854775807);
  return signed < min || signed > max ? null : signed.toInt();
}

double pow10(int scale) {
  var result = 1.0;
  for (var i = 0; i < scale; i++) {
    result *= 10;
  }
  return result;
}

String formatDate(int epochDays) => DateFormat('yyyy-MM-dd').format(
  DateTime.fromMillisecondsSinceEpoch(
    epochDays * Duration.millisecondsPerDay,
    isUtc: true,
  ),
);

/// The zone record timestamps are read in. Date grouping happens in Rust in the device zone it
/// reports with each view result; Flutter's local time is the same zone, except when Rust could
/// not determine it and fell back to UTC. Then [utc] is set so cards and rows print the same
/// day as the group headers.
abstract final class RecordDateZone {
  static bool utc = false;

  /// [epochMs] in the zone record dates are shown in.
  static DateTime of(int epochMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    return utc ? time : time.toLocal();
  }

  /// Follows the zone a view execution reported.
  static void follow(String zone) => utc = zone == 'UTC';
}

/// An instant in the sortable form editors use, `2026-09-24 14:05`, in local time.
String formatDateTime(int epochMs) => DateFormat(
  'yyyy-MM-dd HH:mm',
).format(DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true).toLocal());

/// A record timestamp for reading rather than editing, in the active locale: `Sep 22, 2026 · 14:05`
/// in local time, or `Sep 22 · 14:05` when [short]. Editors keep [formatDateTime]'s sortable form.
String formatDateTimeHuman(int epochMs, {bool short = false}) {
  final time = RecordDateZone.of(epochMs);
  final date = short ? DateFormat.MMMd() : DateFormat.yMMMd();
  return '${date.format(time)} · ${DateFormat.Hm().format(time)}';
}

/// A calendar day for reading, in the active locale: `Sep 22, 2026`, or `Sep 22` when [short].
String formatDateHuman(int epochDays, {bool short = false}) =>
    (short ? DateFormat.MMMd() : DateFormat.yMMMd()).format(
      DateTime.fromMillisecondsSinceEpoch(
        epochDays * Duration.millisecondsPerDay,
        isUtc: true,
      ),
    );

String formatDuration(int milliseconds) {
  final sign = milliseconds < 0 ? '-' : '';
  final absolute = Duration(milliseconds: milliseconds).abs();
  if (absolute.inDays > 0) {
    return '$sign${absolute.inDays}d ${absolute.inHours.remainder(24)}h';
  }
  if (absolute.inHours > 0) {
    return '$sign${absolute.inHours}h ${absolute.inMinutes.remainder(60)}m';
  }
  if (absolute.inMinutes > 0) {
    return '$sign${absolute.inMinutes}m ${absolute.inSeconds.remainder(60)}s';
  }
  return '$sign${absolute.inSeconds}.${absolute.inMilliseconds.remainder(1000).toString().padLeft(3, '0')}s';
}
