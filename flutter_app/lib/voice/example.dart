import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/engine.dart';

/// A sample sentence for the listening hint, built from up to four of [fields] in form order,
/// for example “Lunch, 12.50, category food, yesterday”, or in Spanish
/// «Almuerzo, 12,50, categoría comida, ayer». Deterministic.
String exampleUtterance(List<VoiceField> fields, {String language = 'en'}) {
  final es = language == 'es';
  final parts = <String>[];
  for (final field in fields) {
    if (parts.length == 4) break;
    final name = field.name.trim().toLowerCase();
    final sample = switch (field.kind) {
      FieldTypeKindDto.text => es ? 'Almuerzo' : 'Lunch',
      FieldTypeKindDto.fixedDecimal => es ? '12,50' : '12.50',
      FieldTypeKindDto.integer => '3',
      FieldTypeKindDto.enum_ ||
      FieldTypeKindDto.enumSet => switch (field.options.firstOrNull) {
        final option? => '$name ${option.label.toLowerCase()}',
        null => null,
      },
      FieldTypeKindDto.date => es ? 'ayer' : 'yesterday',
      FieldTypeKindDto.dateTime =>
        es ? 'ayer al mediodía' : 'yesterday at noon',
      FieldTypeKindDto.boolean => es ? '$name sí' : '$name yes',
      FieldTypeKindDto.duration => es ? '45 minutos' : '45 minutes',
    };
    // Two text samples would both read the same; only the first is used.
    if (sample == null || parts.contains(sample)) continue;
    parts.add(sample);
  }
  return parts.join(', ');
}
