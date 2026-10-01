import 'package:fi/exact_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

// 2026-09-22 as an epoch day.
final _day =
    DateTime.utc(2026, 9, 22).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

void main() {
  setUpAll(() => initializeDateFormatting());
  tearDown(() => Intl.defaultLocale = null);

  test('English dates keep the short month form', () {
    Intl.defaultLocale = 'en';
    expect(formatDateHuman(_day), 'Sep 22, 2026');
    expect(formatDateHuman(_day, short: true), 'Sep 22');
  });

  test('Spanish dates use Spanish month names', () {
    Intl.defaultLocale = 'es';
    expect(formatDateHuman(_day), contains('sept'));
  });

  test('fixed decimals accept and emit the locale separator', () {
    expect(parseScaled('12,50', 2, decimalSeparator: ','), 1250);
    expect(parseScaled('12.50', 2, decimalSeparator: ','), 1250);
    expect(formatScaled(1250, 2, decimalSeparator: ','), '12,50');
    expect(formatScaled(1250, 2), '12.50');
    expect(parseScaled('12,50', 2), isNull);
  });
}
