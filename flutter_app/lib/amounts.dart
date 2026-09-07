import 'package:intl/intl.dart';

int parseMinorUnits(String input, String locale) {
  final symbols = NumberFormat.decimalPattern(locale).symbols;
  var normalized = input.trim().replaceAll('\u00a0', '').replaceAll(' ', '');
  if (symbols.GROUP_SEP.isNotEmpty) {
    normalized = normalized.replaceAll(symbols.GROUP_SEP, '');
  }
  if (symbols.DECIMAL_SEP != '.') {
    normalized = normalized.replaceAll(symbols.DECIMAL_SEP, '.');
  }
  final match = RegExp(
    r'^([+-]?)(\d+)(?:\.(\d{1,2}))?$',
  ).firstMatch(normalized);
  if (match == null) {
    throw const FormatException(
      'Enter an amount with at most two decimal places.',
    );
  }
  final whole = int.parse(match.group(2)!);
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  final value = whole * 100 + int.parse(fraction.isEmpty ? '0' : fraction);
  return match.group(1) == '-' ? -value : value;
}

String formatMinorUnits(int amountMinor, String locale) =>
    NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: 2,
    ).format(amountMinor / 100).trim();
