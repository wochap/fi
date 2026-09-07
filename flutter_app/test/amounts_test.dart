import 'package:fi/amounts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses locale-safe amounts into exact minor units', () {
    expect(parseMinorUnits('1,234.56', 'en_US'), 123456);
    expect(parseMinorUnits('-1.234,56', 'de_DE'), -123456);
    expect(parseMinorUnits('+4,5', 'de_DE'), 450);
    expect(
      () => parseMinorUnits('1.234', 'en_US'),
      throwsA(isA<FormatException>()),
    );
  });
}
