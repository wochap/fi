import 'package:clock/clock.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/choice_input.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

export 'package:fi/exact_format.dart' show formatScaled, parseScaled;

/// The word a person reads for a field kind, wherever a kind is shown or chosen.
///
/// The generated identifiers (`enum_`, `fixedDecimal`, `dateTime`) are Dart spellings, not labels.
String fieldKindLabel(AppLocalizations l, FieldTypeKindDto kind) =>
    switch (kind) {
      FieldTypeKindDto.text => l.fieldTypeText,
      FieldTypeKindDto.integer => l.fieldTypeInteger,
      FieldTypeKindDto.fixedDecimal => l.fieldTypeDecimal,
      FieldTypeKindDto.boolean => l.fieldTypeBoolean,
      FieldTypeKindDto.date => l.fieldTypeDate,
      FieldTypeKindDto.dateTime => l.fieldTypeDateTime,
      FieldTypeKindDto.duration => l.fieldTypeDuration,
      FieldTypeKindDto.enum_ => l.fieldTypeChoice,
      FieldTypeKindDto.enumSet => l.fieldTypeChoices,
    };

typedef FieldValueChanged = void Function(FieldValueDto value);

final class FieldRendererRegistry {
  const FieldRendererRegistry();

  /// Whether a record editor for [field] marks it required: required and without a default,
  /// because a default already satisfies it. Callers use it to decide on the form's legend.
  static bool marksRequired(FieldDefinitionDto field) =>
      field.required_ &&
      field.defaultValue == null &&
      field.defaultRelativeDays == null;

  /// [field]'s options that can be picked, in order: removed options are not offered.
  static List<EnumOptionDto> activeOptions(FieldDefinitionDto field) =>
      field.enumOptions.where((option) => !option.deleted).toList()
        ..sort((a, b) {
          final order = a.order.compareTo(b.order);
          return order == 0 ? a.id.compareTo(b.id) : order;
        });

  /// The label a Choice value reads as: the option's label, with " (deleted)" for a removed
  /// option a record still holds. Null for an unknown option.
  static String? optionLabel(FieldDefinitionDto field, String? optionId) {
    final option = field.enumOptions
        .where((option) => option.id == optionId)
        .firstOrNull;
    if (option == null) return null;
    return option.deleted ? '${option.label} (deleted)' : option.label;
  }

  /// The labels a Choices value reads as, in option order (removed options read
  /// "<label> (deleted)"); unknown ids are left out.
  static List<String> optionLabels(
    FieldDefinitionDto field,
    FieldValueDto? value,
  ) {
    if (value == null || value.kind != FieldValueKindDto.enumSet) {
      return const [];
    }
    final held = value.listValue.toSet();
    final ordered = [...field.enumOptions]
      ..sort((a, b) {
        final order = a.order.compareTo(b.order);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    return [
      for (final option in ordered)
        if (held.contains(option.id))
          option.deleted ? '${option.label} (deleted)' : option.label,
    ];
  }

  /// [errors] are this field's issues, shown below the input one per line (for example the
  /// projected diagnostic, so a record opened from the list shows which value is at fault).
  /// A field that [marksRequired] gets an `*` after its label unless [allowClear] is set.
  ///
  /// [label] replaces the field name, and [allowClear] adds the "no value at all" state that a
  /// record does not need but schema metadata does: a default and a range bound are each optional
  /// even on a required field. With it, a boolean becomes a three-way choice and a date gains a
  /// clear action, because neither a switch nor a filled picker can otherwise say "unset".
  ///
  /// [quickFill] adds "Today" to a date and "Now" to a date and time. Only record values ask for
  /// it: in a schema default or range bound it would freeze the moment the schema was edited.
  ///
  /// [showLabel] off leaves the name out of the input, for a form that draws the label beside or
  /// above the control ([RecordFormBody]).
  ///
  /// Every control clears only where the value is optional: a record field that is not
  /// required, or any schema slot ([allowClear]).
  ///
  /// [dictation] puts the field dictation mic in a Text input's trailing slot (after the clear
  /// mark), with its listening or processing row over the value; other kinds ignore it.
  ///
  /// [onAddOption] lets a Choice or Choices record value add an option to the field (only when
  /// the field allows it): it receives the label and returns the draft-local key the value picks
  /// it by. [pendingOptions] are the options already added for this field, shown after the
  /// stored ones with a "New" tag.
  Widget editor(
    FieldDefinitionDto field,
    FieldValueDto? initial,
    FieldValueChanged onChanged, {
    List<String> errors = const [],
    String? label,
    bool allowClear = false,
    bool quickFill = false,
    bool showLabel = true,
    TextDictationSlot? dictation,
    List<PendingOptionDto> pendingOptions = const [],
    AddChoiceOption? onAddOption,
    Key? key,
  }) => _FieldEditor(
    key: key ?? ValueKey(field.id),
    field: field,
    initial: initial,
    onChanged: onChanged,
    errors: errors,
    label: label,
    allowClear: allowClear,
    quickFill: quickFill,
    showLabel: showLabel,
    dictation: field.fieldType.kind == FieldTypeKindDto.text ? dictation : null,
    pendingOptions: pendingOptions,
    onAddOption: field.allowOptionsFromRecords ? onAddOption : null,
  );

  /// A stored value as text. [human] reads dates as `Sep 22, 2026 · 14:05` for tables and lists,
  /// [short] drops the year; without it the value keeps the sortable form editors use.
  /// Returns null when there is no value.
  String? displayText(
    FieldDefinitionDto field,
    FieldValueDto? value, {
    bool human = false,
    bool short = false,
    AppLocalizations? l,
    String decimalSeparator = '.',
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
    final text = _text(
      field,
      value,
      l ?? lookupAppLocalizations(const Locale('en')),
      decimalSeparator,
    );
    return text == '—' ? null : text;
  }

  Widget display(FieldDefinitionDto field, FieldValueDto? value) {
    if (value == null) return const Text('—');
    return Builder(
      builder: (context) => Text(
        _text(field, value, context.l10n, decimalSeparatorOf(context)),
        maxLines: field.display.multiline ? null : 1,
        overflow: field.display.multiline ? null : TextOverflow.ellipsis,
      ),
    );
  }

  String _text(
    FieldDefinitionDto field,
    FieldValueDto value,
    AppLocalizations l,
    String decimalSeparator,
  ) {
    return switch (value.kind) {
      FieldValueKindDto.null_ => '—',
      FieldValueKindDto.text => value.textValue ?? '—',
      FieldValueKindDto.enum_ =>
        FieldRendererRegistry.optionLabel(field, value.textValue) ?? '—',
      FieldValueKindDto.enumSet => () {
        final labels = FieldRendererRegistry.optionLabels(field, value);
        return labels.isEmpty ? '—' : labels.join(', ');
      }(),
      FieldValueKindDto.fixedDecimal => formatScaled(
        value.integerValue ?? 0,
        field.fieldType.scale ?? 0,
        decimalSeparator: decimalSeparator,
      ),
      FieldValueKindDto.boolean =>
        value.booleanValue == true ? l.commonYes : l.commonNo,
      FieldValueKindDto.date => _dateFromDays(
        value.integerValue ?? 0,
      ).toIso8601String().split('T').first,
      FieldValueKindDto.dateTime => RecordDateZone.of(
        value.integerValue ?? 0,
      ).toString(),
      FieldValueKindDto.duration => '${value.integerValue ?? 0} ms',
      FieldValueKindDto.integer => '${value.integerValue ?? 0}',
    };
  }
}

/// What a Text input shows for field dictation: the [mic], and while a turn runs the [overlay]
/// over the value, which is then read-only.
typedef TextDictationSlot = ({Widget mic, Widget? overlay});

final class _FieldEditor extends StatefulWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.initial,
    required this.onChanged,
    this.errors = const [],
    this.label,
    this.allowClear = false,
    this.quickFill = false,
    this.showLabel = true,
    this.dictation,
    this.pendingOptions = const [],
    this.onAddOption,
  });
  final FieldDefinitionDto field;
  final FieldValueDto? initial;
  final FieldValueChanged onChanged;
  final List<String> errors;
  final String? label;
  final bool allowClear;
  final bool quickFill;
  final bool showLabel;
  final TextDictationSlot? dictation;
  final List<PendingOptionDto> pendingOptions;
  final AddChoiceOption? onAddOption;
  @override
  State<_FieldEditor> createState() => _FieldEditorState();
}

const _null = FieldValueDto(kind: FieldValueKindDto.null_);

final class _FieldEditorState extends State<_FieldEditor> {
  final TextEditingController text = TextEditingController();
  var _textReady = false;
  late bool boolean;
  bool? optionalBoolean;
  int? sliderValue;
  int? durationValue;
  String? choice;
  List<String> choices = const [];
  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    boolean = value?.booleanValue ?? false;
    optionalBoolean = value?.kind == FieldValueKindDto.boolean
        ? value?.booleanValue
        : null;
    sliderValue = value?.kind == FieldValueKindDto.integer
        ? value?.integerValue
        : null;
    durationValue = value?.kind == FieldValueKindDto.duration
        ? value?.integerValue
        : null;
    choice = value?.kind == FieldValueKindDto.enum_ ? value?.textValue : null;
    choices = value?.kind == FieldValueKindDto.enumSet
        ? value!.listValue
        : const [];
  }

  /// The initial text needs the locale's decimal separator, so it is set once dependencies exist.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_textReady) return;
    _textReady = true;
    final value = widget.initial;
    text.text = switch (widget.field.fieldType.kind) {
      FieldTypeKindDto.fixedDecimal =>
        value == null || value.integerValue == null
            ? ''
            : formatScaled(
                value.integerValue!,
                widget.field.fieldType.scale ?? 0,
                decimalSeparator: decimalSeparatorOf(context),
              ),
      FieldTypeKindDto.text || FieldTypeKindDto.enum_ => value?.textValue ?? '',
      FieldTypeKindDto.date =>
        value?.integerValue == null
            ? ''
            : _dateFromDays(
                value!.integerValue!,
              ).toIso8601String().split('T').first,
      FieldTypeKindDto.dateTime =>
        value?.integerValue == null ? '' : formatDateTime(value!.integerValue!),
      _ => value?.integerValue?.toString() ?? '',
    };
  }

  /// The stored active options, then the options added from the record form for this field.
  List<ChoiceOption> _choiceOptions(List<EnumOptionDto> active) => [
    for (final option in active)
      ChoiceOption(id: option.id, label: option.label),
    if (widget.onAddOption != null)
      for (final pending in widget.pendingOptions)
        if (pending.fieldId == widget.field.id)
          ChoiceOption(id: pending.key, label: pending.label, isNew: true),
  ];

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  String get _label => widget.label ?? widget.field.name;

  String? get _inputLabel => widget.showLabel ? _label : null;

  bool get _required =>
      !widget.allowClear && FieldRendererRegistry.marksRequired(widget.field);

  /// Whether the value may be emptied: any schema slot, or a record value that is optional.
  bool get _canClear => widget.allowClear || !widget.field.required_;

  /// Reports "no value", which [_FieldEditor.allowClear] callers read as leaving the slot unset.
  void _clear() => widget.onChanged(_null);

  /// Fills a local calendar day, from the picker or "Today", as a timezone-free epoch day.
  void _setDate(DateTime local) {
    final utc = DateTime.utc(local.year, local.month, local.day);
    setState(() => text.text = utc.toIso8601String().split('T').first);
    widget.onChanged(
      FieldValueDto(
        kind: FieldValueKindDto.date,
        integerValue: utc.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay,
      ),
    );
  }

  /// Fills a local minute, from the picker or "Now", as UTC epoch milliseconds.
  void _setDateTime(DateTime local) {
    final minute = DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
    final epochMs = minute.toUtc().millisecondsSinceEpoch;
    setState(() => text.text = formatDateTime(epochMs));
    widget.onChanged(
      FieldValueDto(kind: FieldValueKindDto.dateTime, integerValue: epochMs),
    );
  }

  Key _quickKey(String action) =>
      ValueKey('field-${widget.field.id}-${action.toLowerCase()}');

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final field = widget.field;
    if (field.fieldType.kind == FieldTypeKindDto.boolean) {
      if (widget.allowClear) {
        // Three states, because a switch cannot say "no value".
        return FiSelect<bool?>(
          value: widget.initial?.kind == FieldValueKindDto.boolean
              ? widget.initial!.booleanValue
              : null,
          label: _inputLabel,
          required: _required,
          errors: widget.errors,
          items: [
            DropdownMenuItem<bool?>(value: null, child: Text(l.commonNone)),
            DropdownMenuItem<bool?>(value: true, child: Text(l.inputTrue)),
            DropdownMenuItem<bool?>(value: false, child: Text(l.inputFalse)),
          ],
          onChanged: (value) => widget.onChanged(
            value == null
                ? _null
                : FieldValueDto(
                    kind: FieldValueKindDto.boolean,
                    booleanValue: value,
                  ),
          ),
        );
      }
      if (!field.required_) {
        // Yes, No or not set.
        return FiSegmented<bool>(
          segments: [
            FiSegment(true, l.commonYes),
            FiSegment(false, l.commonNo),
          ],
          value: optionalBoolean,
          allowClear: true,
          label: _inputLabel,
          errors: widget.errors,
          onChanged: (value) {
            setState(() => optionalBoolean = value);
            widget.onChanged(
              value == null
                  ? _null
                  : FieldValueDto(
                      kind: FieldValueKindDto.boolean,
                      booleanValue: value,
                    ),
            );
          },
        );
      }
      void toggle(bool value) {
        setState(() => boolean = value);
        widget.onChanged(
          FieldValueDto(kind: FieldValueKindDto.boolean, booleanValue: value),
        );
      }

      if (!widget.showLabel) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: Nocturne.inputHeight(context, InputSize.normal),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FiSwitch(value: boolean, onChanged: toggle),
              ),
            ),
            if (widget.errors.isNotEmpty) FieldErrorLines(widget.errors),
          ],
        );
      }
      return FiSwitchTile(
        title: _required ? requiredLabel(_label) : Text(_label),
        subtitle: widget.errors.isEmpty ? null : FieldErrorLines(widget.errors),
        value: boolean,
        onChanged: toggle,
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.enum_) {
      final active = FieldRendererRegistry.activeOptions(field);
      if (widget.allowClear) {
        // A schema default: chosen by label, with an explicit None.
        return FiSelect<String>(
          value: active.any((option) => option.id == choice) ? choice : null,
          label: _inputLabel,
          required: _required,
          errors: widget.errors,
          items: [
            DropdownMenuItem<String>(value: null, child: Text(l.commonNone)),
            ...active.map(
              (option) =>
                  DropdownMenuItem(value: option.id, child: Text(option.label)),
            ),
          ],
          onChanged: (value) {
            setState(() => choice = value);
            widget.onChanged(
              value == null
                  ? _null
                  : FieldValueDto(
                      kind: FieldValueKindDto.enum_,
                      textValue: value,
                    ),
            );
          },
        );
      }
      return FiChoiceInput(
        title: _label,
        label: _inputLabel,
        required: _required,
        errors: widget.errors,
        allowClear: _canClear,
        options: _choiceOptions(active),
        onAdd: widget.onAddOption,
        value: choice,
        heldLabel: FieldRendererRegistry.optionLabel(field, choice),
        onChanged: (value) {
          setState(() => choice = value);
          widget.onChanged(
            value == null
                ? _null
                : FieldValueDto(
                    kind: FieldValueKindDto.enum_,
                    textValue: value,
                  ),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.enumSet) {
      final active = FieldRendererRegistry.activeOptions(field);
      return FiChoicesInput(
        title: _label,
        label: _inputLabel,
        required: _required,
        errors: widget.errors,
        allowClear: _canClear,
        options: _choiceOptions(active),
        onAdd: widget.onAddOption,
        value: choices,
        heldLabels: {
          for (final id in choices)
            id: ?FieldRendererRegistry.optionLabel(field, id),
        },
        onChanged: (value) {
          setState(() => choices = value);
          widget.onChanged(
            value.isEmpty
                ? _null
                : FieldValueDto(
                    kind: FieldValueKindDto.enumSet,
                    listValue: value,
                  ),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.date) {
      return FiPickerInput(
        controller: text,
        label: _inputLabel,
        hint: Nocturne.isPhone(context) ? l.inputPickDate : 'YYYY-MM-DD',
        required: _required,
        errors: widget.errors,
        icon: FiIcons.date,
        quickAction: widget.quickFill ? l.inputToday : null,
        quickActionKey: _quickKey('Today'),
        onQuickAction: () => _setDate(clock.now()),
        onClear: _canClear ? _clear : null,
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
          _setDate(selected);
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.dateTime) {
      return FiPickerInput(
        controller: text,
        label: _inputLabel,
        hint: Nocturne.isPhone(context)
            ? l.inputPickDateTime
            : 'YYYY-MM-DD HH:MM',
        required: _required,
        errors: widget.errors,
        icon: FiIcons.dateTime,
        quickAction: widget.quickFill ? l.inputNow : null,
        quickActionKey: _quickKey('Now'),
        onQuickAction: () => _setDateTime(clock.now()),
        onClear: _canClear ? _clear : null,
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
          _setDateTime(
            DateTime(day.year, day.month, day.day, time.hour, time.minute),
          );
        },
      );
    }
    if (field.fieldType.kind == FieldTypeKindDto.duration) {
      return FiDurationInput(
        value: durationValue,
        label: _inputLabel,
        required: _required,
        allowClear: _canClear,
        errors: widget.errors,
        onChanged: (value) {
          durationValue = value;
          widget.onChanged(
            value == null
                ? _null
                : FieldValueDto(
                    kind: FieldValueKindDto.duration,
                    integerValue: value,
                  ),
          );
        },
      );
    }
    final minimum = field.validation.minInteger;
    final maximum = field.validation.maxInteger;
    if (field.fieldType.kind == FieldTypeKindDto.integer &&
        field.display.slider &&
        minimum != null &&
        maximum != null &&
        minimum <= maximum) {
      final step = field.display.sliderStep ?? 1;
      return FiSlider(
        min: minimum,
        max: maximum,
        // An off-range step from an older or malformed definition falls back to whole numbers.
        step: step > 0 && (maximum - minimum) % step == 0 ? step : 1,
        value: sliderValue,
        label: _inputLabel,
        // A required value never offers the clear mark, even when a default fills it.
        required: !_canClear,
        errors: widget.errors,
        allowClear: widget.allowClear,
        onChanged: (value) {
          setState(() => sliderValue = value);
          widget.onChanged(
            value == null
                ? _null
                : FieldValueDto(
                    kind: FieldValueKindDto.integer,
                    integerValue: value,
                  ),
          );
        },
      );
    }
    final multiline =
        field.fieldType.kind == FieldTypeKindDto.text &&
        field.display.multiline;
    final decimal = field.fieldType.kind == FieldTypeKindDto.fixedDecimal;
    final scale = field.fieldType.scale ?? 0;
    return FiTextInput(
      controller: text,
      maxLines: multiline ? 6 : 1,
      keyboardType: field.fieldType.kind != FieldTypeKindDto.text
          ? const TextInputType.numberWithOptions(signed: true, decimal: true)
          : multiline
          ? TextInputType.multiline
          : TextInputType.text,
      label: _inputLabel,
      hint: decimal
          ? formatScaled(
              0,
              scale,
              decimalSeparator: decimalSeparatorOf(context),
            )
          : widget.showLabel
          ? null
          : l.inputEmpty,
      required: _required,
      errors: widget.errors,
      // The scale is the contract for what the typed digits mean, so it is stated where they
      // are typed.
      suffixIcon: decimal
          ? Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '$scale dp',
                key: const Key('decimal-scale'),
                style: TextStyle(
                  fontSize: 12,
                  color: context.nocturne.muted(.55),
                ),
              ),
            )
          : null,
      onClear: _canClear ? _clear : null,
      trailingAction: widget.dictation?.mic,
      overlay: widget.dictation?.overlay,
      readOnly: widget.dictation?.overlay != null,
      onChanged: (raw) {
        if (raw.isEmpty && _canClear) {
          widget.onChanged(_null);
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
            integerValue: parseScaled(
              raw,
              scale,
              decimalSeparator: decimalSeparatorOf(context),
            ),
          ),
          _ => null,
        };
        if (value != null) widget.onChanged(value);
      },
    );
  }
}

DateTime _dateFromDays(int days) => DateTime.fromMillisecondsSinceEpoch(
  days * Duration.millisecondsPerDay,
  isUtc: true,
);
