import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';

export 'package:fi/exact_format.dart' show formatScaled, parseScaled;

/// The word a person reads for a field kind, wherever a kind is shown or chosen.
///
/// The generated identifiers (`enum_`, `fixedDecimal`, `dateTime`) are Dart spellings, not labels.
String fieldKindLabel(FieldTypeKindDto kind) => switch (kind) {
  FieldTypeKindDto.text => 'Text',
  FieldTypeKindDto.integer => 'Integer',
  FieldTypeKindDto.fixedDecimal => 'Decimal',
  FieldTypeKindDto.boolean => 'Boolean',
  FieldTypeKindDto.date => 'Date',
  FieldTypeKindDto.dateTime => 'Date & time',
  FieldTypeKindDto.duration => 'Duration',
  FieldTypeKindDto.enum_ => 'Choice',
};

typedef FieldValueChanged = void Function(FieldValueDto value);

final class FieldRendererRegistry {
  const FieldRendererRegistry();

  /// [errorText], when supplied, is the projected diagnostic for this field, so a record opened
  /// from the list shows which value is missing rather than only that something is.
  ///
  /// [label] replaces the field name, and [allowClear] adds the "no value at all" state that a
  /// record does not need but schema metadata does: a default and a range bound are each optional
  /// even on a required field. With it, a boolean becomes a three-way choice and a date gains a
  /// clear action, because neither a switch nor a filled picker can otherwise say "unset".
  Widget editor(
    FieldDefinitionDto field,
    FieldValueDto? initial,
    FieldValueChanged onChanged, {
    String? errorText,
    String? label,
    bool allowClear = false,
  }) => _FieldEditor(
    key: ValueKey(field.id),
    field: field,
    initial: initial,
    onChanged: onChanged,
    errorText: errorText,
    label: label,
    allowClear: allowClear,
  );

  /// A stored value as text. [human] reads dates as `Sep 22, 2026 · 14:05` for tables and lists,
  /// [short] drops the year; without it the value keeps the sortable form editors use.
  /// Returns null when there is no value.
  String? displayText(
    FieldDefinitionDto field,
    FieldValueDto? value, {
    bool human = false,
    bool short = false,
  }) {
    if (value == null || value.kind == FieldValueKindDto.null_) return null;
    if (human) {
      switch (value.kind) {
        case FieldValueKindDto.dateTime:
          return formatDateTimeHuman(value.integerValue ?? 0, short: short);
        case FieldValueKindDto.date:
          return formatDateHuman(value.integerValue ?? 0, short: short);
        case FieldValueKindDto.duration:
          return formatDuration(value.integerValue ?? 0);
        default:
      }
    }
    final text = _text(field, value);
    return text == '—' ? null : text;
  }

  Widget display(FieldDefinitionDto field, FieldValueDto? value) {
    if (value == null) return const Text('—');
    final text = _text(field, value);
    return Text(
      text,
      maxLines: field.display.multiline ? null : 1,
      overflow: field.display.multiline ? null : TextOverflow.ellipsis,
    );
  }

  String _text(FieldDefinitionDto field, FieldValueDto value) {
    return switch (value.kind) {
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
  }
}

final class _FieldEditor extends StatefulWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.initial,
    required this.onChanged,
    this.errorText,
    this.label,
    this.allowClear = false,
  });
  final FieldDefinitionDto field;
  final FieldValueDto? initial;
  final FieldValueChanged onChanged;
  final String? errorText;
  final String? label;
  final bool allowClear;
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

  String get _label => widget.label ?? widget.field.name;

  /// Reports "no value", which [_FieldEditor.allowClear] callers read as leaving the slot unset.
  void _clear() {
    text.clear();
    widget.onChanged(const FieldValueDto(kind: FieldValueKindDto.null_));
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    if (field.fieldType.kind == FieldTypeKindDto.boolean) {
      if (widget.allowClear) {
        // Three states, because a switch cannot say "no value".
        return DropdownButtonFormField<bool?>(
          initialValue: widget.initial?.kind == FieldValueKindDto.boolean
              ? widget.initial!.booleanValue
              : null,
          decoration: InputDecoration(
            labelText: _label,
            errorText: widget.errorText,
          ),
          items: const [
            DropdownMenuItem<bool?>(value: null, child: Text('None')),
            DropdownMenuItem<bool?>(value: true, child: Text('True')),
            DropdownMenuItem<bool?>(value: false, child: Text('False')),
          ],
          onChanged: (value) => widget.onChanged(
            value == null
                ? const FieldValueDto(kind: FieldValueKindDto.null_)
                : FieldValueDto(
                    kind: FieldValueKindDto.boolean,
                    booleanValue: value,
                  ),
          ),
        );
      }
      return SwitchListTile(
        title: Text(_label),
        subtitle: widget.errorText == null
            ? null
            : Text(
                widget.errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
        decoration: InputDecoration(
          labelText: _label,
          errorText: widget.errorText,
        ),
        items: [
          if (widget.allowClear)
            const DropdownMenuItem<String>(value: null, child: Text('None')),
          ...active.map(
            (option) =>
                DropdownMenuItem(value: option.id, child: Text(option.label)),
          ),
        ],
        onChanged: (value) {
          if (value == null) {
            if (widget.allowClear) _clear();
            return;
          }
          text.text = value;
          widget.onChanged(
            FieldValueDto(kind: FieldValueKindDto.enum_, textValue: value),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.date) {
      return TextFormField(
        controller: text,
        readOnly: true,
        decoration: InputDecoration(
          labelText: _label,
          errorText: widget.errorText,
          suffixIcon: widget.allowClear && text.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(_clear),
                )
              : const Icon(Icons.calendar_today),
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
          setState(() => text.text = utc.toIso8601String().split('T').first);
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
          labelText: _label,
          errorText: widget.errorText,
          suffixIcon: widget.allowClear && text.text.isNotEmpty
              ? IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(_clear),
                )
              : const Icon(Icons.event),
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
          setState(() => text.text = selected.toString());
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
        labelText: _label,
        errorText: widget.errorText,
        helperText: _unitHelp(field.fieldType.kind, field.fieldType.scale),
      ),
      onChanged: (raw) {
        if (raw.isEmpty && (widget.allowClear || !field.required_)) {
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

String? _unitHelp(FieldTypeKindDto kind, int? scale) => switch (kind) {
  FieldTypeKindDto.date => 'UTC epoch days',
  FieldTypeKindDto.dateTime => 'UTC epoch milliseconds',
  FieldTypeKindDto.duration => 'Signed milliseconds',
  // The scale is the contract for what the typed digits mean, so it is stated where they are typed.
  FieldTypeKindDto.fixedDecimal => 'Exact to $scale decimal places',
  _ => null,
};
DateTime _dateFromDays(int days) => DateTime.fromMillisecondsSinceEpoch(
  days * Duration.millisecondsPerDay,
  isUtc: true,
);
