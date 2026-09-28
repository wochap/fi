import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/engine.dart';

/// A sample sentence for the listening hint, built from up to four of [fields] in form order,
/// for example “Lunch, 12.50, category food, yesterday”. Deterministic.
String exampleUtterance(List<VoiceField> fields) {
  final parts = <String>[];
  for (final field in fields) {
    if (parts.length == 4) break;
    final name = field.name.trim().toLowerCase();
    final sample = switch (field.kind) {
      FieldTypeKindDto.text => 'Lunch',
      FieldTypeKindDto.fixedDecimal => '12.50',
      FieldTypeKindDto.integer => '3',
      FieldTypeKindDto.enum_ => switch (field.options.firstOrNull) {
        final option? => '$name ${option.label.toLowerCase()}',
        null => null,
      },
      FieldTypeKindDto.date => 'yesterday',
      FieldTypeKindDto.dateTime => 'yesterday at noon',
      FieldTypeKindDto.boolean => '$name yes',
      FieldTypeKindDto.duration => '45 minutes',
    };
    // Two text samples would both read "Lunch"; only the first is used.
    if (sample == null || parts.contains(sample)) continue;
    parts.add(sample);
  }
  return parts.join(', ');
}
