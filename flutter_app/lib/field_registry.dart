import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';

export 'package:fi/exact_format.dart' show formatScaled, parseScaled;

typedef FieldValueChanged = void Function(FieldValueDto value);

final class FieldRendererRegistry {
  const FieldRendererRegistry();

  Widget editor(
    FieldDefinitionDto field,
    FieldValueDto? initial,
    FieldValueChanged onChanged,
  ) => _FieldEditor(
    key: ValueKey(field.id),
    field: field,
    initial: initial,
    onChanged: onChanged,
  );

  Widget display(FieldDefinitionDto field, FieldValueDto? value) {
    if (value == null) return const Text('—');
    final text = switch (value.kind) {
      FieldValueKindDto.null_ => '—',
      FieldValueKindDto.text => value.textValue ?? '—',
      FieldValueKindDto.enum_ =>
        field.enumOptions
                .where(
                  (option) => option.id == value.textValue && !option.deleted,
                )
                .map((option) => option.label)
                .firstOrNull ??
            '—',
      FieldValueKindDto.fixedDecimal => formatScaled(
        value.integerValue ?? 0,
        field.fieldType.scale ?? 0,
      ),
      FieldValueKindDto.boolean => value.booleanValue == true ? 'Yes' : 'No',
      FieldValueKindDto.date => _dateFromDays(
        value.integerValue ?? 0,
      ).toIso8601String().split('T').first,
      FieldValueKindDto.dateTime => DateTime.fromMillisecondsSinceEpoch(
        value.integerValue ?? 0,
        isUtc: true,
      ).toLocal().toString(),
      FieldValueKindDto.duration => '${value.integerValue ?? 0} ms',
      FieldValueKindDto.integer => '${value.integerValue ?? 0}',
    };
    return Text(
      text,
      maxLines: field.display.multiline ? null : 1,
      overflow: field.display.multiline ? null : TextOverflow.ellipsis,
    );
  }
}

final class _FieldEditor extends StatefulWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.initial,
    required this.onChanged,
  });
  final FieldDefinitionDto field;
  final FieldValueDto? initial;
  final FieldValueChanged onChanged;
  @override
  State<_FieldEditor> createState() => _FieldEditorState();
}

final class _FieldEditorState extends State<_FieldEditor> {
  late final TextEditingController text;
  late bool boolean;
  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    boolean = value?.booleanValue ?? false;
    text = TextEditingController(
      text: switch (widget.field.fieldType.kind) {
        FieldTypeKindDto.fixedDecimal =>
          value == null
              ? ''
              : formatScaled(
                  value.integerValue ?? 0,
                  widget.field.fieldType.scale ?? 0,
                ),
        FieldTypeKindDto.text ||
        FieldTypeKindDto.enum_ => value?.textValue ?? '',
        FieldTypeKindDto.date =>
          value == null
              ? ''
              : _dateFromDays(
                  value.integerValue ?? 0,
                ).toIso8601String().split('T').first,
        FieldTypeKindDto.dateTime =>
          value == null
              ? ''
              : DateTime.fromMillisecondsSinceEpoch(
                  value.integerValue ?? 0,
                  isUtc: true,
                ).toLocal().toString(),
        _ => value?.integerValue?.toString() ?? '',
      },
    );
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    if (field.fieldType.kind == FieldTypeKindDto.boolean) {
      return SwitchListTile(
        title: Text(field.name),
        value: boolean,
        onChanged: (value) {
          setState(() => boolean = value);
          widget.onChanged(
            FieldValueDto(kind: FieldValueKindDto.boolean, booleanValue: value),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.enum_) {
      final active =
          field.enumOptions.where((option) => !option.deleted).toList()
            ..sort((a, b) {
              final order = a.order.compareTo(b.order);
              return order == 0 ? a.id.compareTo(b.id) : order;
            });
      return DropdownButtonFormField<String>(
        initialValue: active.any((option) => option.id == text.text)
            ? text.text
            : null,
        decoration: InputDecoration(labelText: field.name),
        items: active
            .map(
              (option) =>
                  DropdownMenuItem(value: option.id, child: Text(option.label)),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) {
            widget.onChanged(
              FieldValueDto(kind: FieldValueKindDto.enum_, textValue: value),
            );
          }
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.date) {
      return TextFormField(
        controller: text,
        readOnly: true,
        decoration: InputDecoration(
          labelText: field.name,
          suffixIcon: const Icon(Icons.calendar_today),
        ),
        onTap: () async {
          final initial = widget.initial?.integerValue == null
              ? DateTime.now()
              : _dateFromDays(widget.initial!.integerValue!);
          final selected = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: DateTime.utc(1),
            lastDate: DateTime.utc(9999, 12, 31),
          );
          if (selected == null) return;
          final utc = DateTime.utc(selected.year, selected.month, selected.day);
          text.text = utc.toIso8601String().split('T').first;
          widget.onChanged(
            FieldValueDto(
              kind: FieldValueKindDto.date,
              integerValue:
                  utc.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay,
            ),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.dateTime) {
      return TextFormField(
        controller: text,
        readOnly: true,
        decoration: InputDecoration(
          labelText: field.name,
          suffixIcon: const Icon(Icons.event),
        ),
        onTap: () async {
          final initial = widget.initial?.integerValue == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(
                  widget.initial!.integerValue!,
                  isUtc: true,
                ).toLocal();
          final day = await showDatePicker(
            context: context,
            initialDate: initial,
            firstDate: DateTime(1),
            lastDate: DateTime(9999, 12, 31),
          );
          if (day == null || !context.mounted) return;
          final time = await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(initial),
          );
          if (time == null) return;
          final selected = DateTime(
            day.year,
            day.month,
            day.day,
            time.hour,
            time.minute,
          );
          text.text = selected.toString();
          widget.onChanged(
            FieldValueDto(
              kind: FieldValueKindDto.dateTime,
              integerValue: selected.toUtc().millisecondsSinceEpoch,
            ),
          );
        },
      );
    }
    return TextFormField(
      controller: text,
      minLines: field.display.multiline ? 3 : 1,
      maxLines: field.display.multiline ? 6 : 1,
      keyboardType: field.fieldType.kind == FieldTypeKindDto.text
          ? TextInputType.text
          : const TextInputType.numberWithOptions(signed: true, decimal: true),
      decoration: InputDecoration(
        labelText: field.name,
        helperText: _unitHelp(field.fieldType.kind),
      ),
      onChanged: (raw) {
        if (raw.isEmpty && !field.required_) {
          widget.onChanged(const FieldValueDto(kind: FieldValueKindDto.null_));
          return;
        }
        final value = switch (field.fieldType.kind) {
          FieldTypeKindDto.text => FieldValueDto(
            kind: FieldValueKindDto.text,
            textValue: raw,
          ),
          FieldTypeKindDto.integer => FieldValueDto(
            kind: FieldValueKindDto.integer,
            integerValue: int.tryParse(raw),
          ),
          FieldTypeKindDto.fixedDecimal => FieldValueDto(
            kind: FieldValueKindDto.fixedDecimal,
            integerValue: parseScaled(raw, field.fieldType.scale ?? 0),
          ),
          FieldTypeKindDto.date => FieldValueDto(
            kind: FieldValueKindDto.date,
            integerValue: int.tryParse(raw),
          ),
          FieldTypeKindDto.dateTime => FieldValueDto(
            kind: FieldValueKindDto.dateTime,
            integerValue: int.tryParse(raw),
          ),
          FieldTypeKindDto.duration => FieldValueDto(
            kind: FieldValueKindDto.duration,
            integerValue: int.tryParse(raw),
          ),
          _ => null,
        };
        if (value != null) widget.onChanged(value);
      },
    );
  }
}

String? _unitHelp(FieldTypeKindDto kind) => switch (kind) {
  FieldTypeKindDto.date => 'UTC epoch days',
  FieldTypeKindDto.dateTime => 'UTC epoch milliseconds',
  FieldTypeKindDto.duration => 'Signed milliseconds',
  _ => null,
};
DateTime _dateFromDays(int days) => DateTime.fromMillisecondsSinceEpoch(
  days * Duration.millisecondsPerDay,
  isUtc: true,
);
