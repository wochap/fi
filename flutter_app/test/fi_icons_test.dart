import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

void main() {
  test('every field type has its own Phosphor glyph', () {
    const expected = {
      FieldTypeKindDto.text: PhosphorIconsRegular.textAa,
      FieldTypeKindDto.integer: PhosphorIconsRegular.hash,
      FieldTypeKindDto.fixedDecimal: PhosphorIconsRegular.percent,
      FieldTypeKindDto.boolean: PhosphorIconsRegular.toggleLeft,
      FieldTypeKindDto.date: PhosphorIconsRegular.calendarBlank,
      FieldTypeKindDto.dateTime: PhosphorIconsRegular.calendarCheck,
      FieldTypeKindDto.duration: PhosphorIconsRegular.timer,
      FieldTypeKindDto.enum_: PhosphorIconsRegular.listBullets,
    };
    for (final kind in FieldTypeKindDto.values) {
      expect(fieldTypeIcon(kind), expected[kind], reason: kind.name);
    }
    final glyphs = FieldTypeKindDto.values.map(fieldTypeIcon).toSet();
    expect(glyphs, hasLength(8));
  });
}
