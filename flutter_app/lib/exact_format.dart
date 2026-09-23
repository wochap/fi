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

  /// The exact human-readable representation.
  String get label;

  /// The value as a drawing coordinate. The only place a double appears.
  double get coordinate;

  bool get isNumeric;
}

final class ExactMissing extends ExactValue {
  const ExactMissing();
  @override
  String get label => '—';
  @override
  double get coordinate => 0;
  @override
  bool get isNumeric => false;
}

final class ExactText extends ExactValue {
  const ExactText(this.label);
  @override
  final String label;
  @override
  double get coordinate => 0;
  @override
  bool get isNumeric => false;
}

final class ExactBoolean extends ExactValue {
  const ExactBoolean(this.value);
  final bool value;
  @override
  String get label => value ? 'Yes' : 'No';
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
  String get label => formatScaled(representation, scale);

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
  String get label => switch (formatter) {
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
String formatScaled(int representation, int scale) {
  final negative = representation < 0;
  final digits = BigInt.from(
    representation,
  ).abs().toString().padLeft(scale + 1, '0');
  final value = scale == 0
      ? digits
      : '${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
  return negative ? '-$value' : value;
}

/// Parses a decimal string into an exact scaled integer, rejecting precision the scale cannot hold.
int? parseScaled(String input, int scale) {
  final match = RegExp(r'^([+-]?)([0-9]+)(?:\.([0-9]*))?$').firstMatch(input);
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

String formatDateTime(int epochMs) => DateFormat(
  'yyyy-MM-dd HH:mm',
).format(DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true));

/// A record timestamp for reading rather than editing: `Sep 22, 2026 · 14:05` in local time, or
/// `Sep 22 · 14:05` when [short]. Editors keep [formatDateTime]'s sortable form.
String formatDateTimeHuman(int epochMs, {bool short = false}) => DateFormat(
  short ? 'MMM d · HH:mm' : 'MMM d, y · HH:mm',
).format(DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true).toLocal());

/// A calendar day for reading: `Sep 22, 2026`, or `Sep 22` when [short].
String formatDateHuman(int epochDays, {bool short = false}) =>
    DateFormat(short ? 'MMM d' : 'MMM d, y').format(
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
