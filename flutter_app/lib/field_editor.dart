import 'package:clock/clock.dart';
import 'package:fi/controllers.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The schema field editor (mocks 5b, 5c, 7g, 7h): name, a 4×2 type grid, option chips for the
/// type, a settings block per chip that is on, the Choice options, and the default. One body,
/// hosted as an inline panel in the desktop schema sheet or as a pushed phone screen.

/// Where a [FieldEditorBody] is shown.
enum FieldEditorHost {
  /// An inline panel in the desktop schema sheet, with Cancel and the save action below it.
  panel,

  /// A full phone screen ([FieldEditorScreen]) with the save action pinned full width.
  screen,
}

/// An option chip of the field editor. Each applies to some types only ([_chipsFor]).
enum _Chip {
  required('Required', 'chip-required', HelpId.fieldRequired),
  multiline('Multiline', 'chip-multiline', HelpId.fieldMultiline),
  lengthLimits('Length limits', 'chip-length', HelpId.fieldMinMaxLength),
  range('Range', 'chip-range', HelpId.fieldMinMax),
  slider('Show as slider', 'field-slider', HelpId.fieldSlider),
  dateRange('Date range', 'chip-date-range', HelpId.fieldMinMax),
  defaultValue('Default value', 'chip-default', HelpId.fieldDefault);

  const _Chip(this.label, this.key, this.help);

  final String label;
  final String key;
  final HelpId help;
}

List<_Chip> _chipsFor(FieldTypeKindDto kind) => [
  _Chip.required,
  if (kind == FieldTypeKindDto.text) ...[_Chip.multiline, _Chip.lengthLimits],
  if (kind == FieldTypeKindDto.integer ||
      kind == FieldTypeKindDto.fixedDecimal ||
      kind == FieldTypeKindDto.duration)
    _Chip.range,
  if (kind == FieldTypeKindDto.integer) _Chip.slider,
  if (kind == FieldTypeKindDto.date || kind == FieldTypeKindDto.dateTime)
    _Chip.dateRange,
  _Chip.defaultValue,
];

/// The field types in grid order: two rows of four.
const _typeGrid = [
  FieldTypeKindDto.text,
  FieldTypeKindDto.integer,
  FieldTypeKindDto.fixedDecimal,
  FieldTypeKindDto.boolean,
  FieldTypeKindDto.date,
  FieldTypeKindDto.dateTime,
  FieldTypeKindDto.duration,
  FieldTypeKindDto.enum_,
];

/// A field's kind and its main settings in a few words, for the schema sheet's rows: "Integer ·
/// 5–30", "Text · multiline", "Decimal · 2 dp", and for a Choice field its option labels in order.
String fieldSummary(FieldDefinitionDto field) {
  final kind = field.fieldType.kind;
  final label = fieldKindLabel(kind);
  final min = field.validation.minInteger;
  final max = field.validation.maxInteger;
  final detail = switch (kind) {
    FieldTypeKindDto.enum_ => () {
      final options = FieldRendererRegistry.activeOptions(field);
      return options.isEmpty
          ? null
          : options.map((option) => option.label).join(', ');
    }(),
    FieldTypeKindDto.text when field.display.multiline => 'multiline',
    FieldTypeKindDto.fixedDecimal => '${field.fieldType.scale ?? 0} dp',
    FieldTypeKindDto.integer when min != null && max != null => '$min–$max',
    _ => null,
  };
  return detail == null ? label : '$label · $detail';
}

/// A text of [label] characters count constraint, such as "4–8".
String _lengthRange(int? min, int? max) => switch ((min, max)) {
  (final min?, final max?) => '$min–$max',
  (final min?, null) => 'at least $min',
  (null, final max?) => 'at most $max',
  _ => '',
};

/// One Choice option as the field editor holds it until Save. [id] is the stored ID, or one made
/// by [tempOptionId] for an option this editor added.
final class _DraftOption {
  _DraftOption(this.id, String label)
    : label = TextEditingController(text: label);
  final String id;
  final TextEditingController label;
}

int _optionOrder(EnumOptionDto left, EnumOptionDto right) {
  final order = left.order.compareTo(right.order);
  return order == 0 ? left.id.compareTo(right.id) : order;
}

FieldValueDto? _valueOf(RecordDto record, String fieldId) {
  for (final item in record.values) {
    if (item.fieldId == fieldId) return item.value;
  }
  return null;
}

/// Today in the device's local calendar, as a timezone-free epoch day.
int _localEpochDay() {
  final now = clock.now();
  return DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
}

/// A chip of the field editor: a check when on, and a 44px target on a phone.
class FieldOptionChip extends StatelessWidget {
  const FieldOptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;

  /// Null shows the chip disabled.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final radius = BorderRadius.circular(16);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Material(
          color: selected ? Nocturne.accent900 : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: selected ? Nocturne.accent700 : Nocturne.divider,
            ),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: Nocturne.isPhone(context)
                    ? Nocturne.touchTarget
                    : 32,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      const Icon(
                        FiIcons.check,
                        size: 14,
                        color: Nocturne.accent200,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? Nocturne.accent100
                            : Nocturne.muted(.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A chip's settings under the chips: its name, a ✕ that turns the chip off, and the settings.
class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({
    required this.chip,
    required this.onClose,
    required this.child,
  });

  final _Chip chip;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('block-${chip.key}'),
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 14),
    decoration: BoxDecoration(
      color: Nocturne.bg,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: Border.all(color: Nocturne.neutral800),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: SectionLabel(chip.label)),
            HelpButton(chip.help),
            FiIconButton(
              key: Key('close-${chip.key}'),
              icon: FiIcons.close,
              size: 14,
              tooltip: 'Turn off ${chip.label}',
              onPressed: onClose,
            ),
          ],
        ),
        Padding(padding: const EdgeInsets.only(right: 8), child: child),
      ],
    ),
  );
}

class FieldEditorBody extends StatefulWidget {
  const FieldEditorBody({
    required this.controller,
    required this.onClosed,
    this.existing,
    this.host = FieldEditorHost.panel,
    super.key,
  });

  final CollectionsController controller;
  final FieldDefinitionDto? existing;

  /// Called after a save or on Cancel.
  final VoidCallback onClosed;
  final FieldEditorHost host;

  @override
  State<FieldEditorBody> createState() => _FieldEditorBodyState();
}

class _FieldEditorBodyState extends State<FieldEditorBody> {
  CollectionsController get controller => widget.controller;
  FieldDefinitionDto? get existing => widget.existing;

  late final name = TextEditingController(text: existing?.name);
  late var kind = existing?.fieldType.kind ?? FieldTypeKindDto.text;
  late var required = existing?.required_ ?? false;
  late var multiline = existing?.display.multiline ?? false;
  late var slider = existing?.display.slider ?? false;
  late final sliderStep = TextEditingController(
    text: existing?.display.sliderStep?.toString() ?? '',
  );
  late var scale = existing?.fieldType.scale ?? 2;
  // Range bounds are compared against the stored integer, which is epoch days for a Date, epoch
  // milliseconds for a DateTime, and the scaled representation for a FixedDecimal. Holding them
  // as integers lets the same typed control that edits a record edit the bound.
  late int? minimum = existing?.validation.minInteger;
  late int? maximum = existing?.validation.maxInteger;
  late final minLength = TextEditingController(
    text: existing?.validation.minLength?.toString() ?? '',
  );
  late final maxLength = TextEditingController(
    text: existing?.validation.maxLength?.toString() ?? '',
  );
  late FieldValueDto? defaultValue =
      existing?.defaultValue?.kind == FieldValueKindDto.null_
      ? null
      : existing?.defaultValue;

  /// A Date default of "Day of creation ± N days" rather than a fixed date.
  late var relative =
      existing?.defaultRelativeDays != null ||
      (existing == null || existing?.defaultValue == null);
  late var relativeNegative = (existing?.defaultRelativeDays ?? 0) < 0;
  late final relativeDays = TextEditingController(
    text: existing?.defaultRelativeDays?.abs().toString() ?? '',
  );

  /// The chips whose settings block is open. Required and Multiline have no settings.
  late final open = <_Chip>{
    if (minLength.text.isNotEmpty || maxLength.text.isNotEmpty)
      _Chip.lengthLimits,
    if (minimum != null || maximum != null)
      _isDateKind(kind) ? _Chip.dateRange : _Chip.range,
    if (slider) _Chip.slider,
    if (defaultValue != null || existing?.defaultRelativeDays != null)
      _Chip.defaultValue,
  };

  // Choice options are held here until Save, so a new field can get options and a default in
  // the same step and Cancel leaves the stored options untouched.
  late final options = [
    for (final option in [
      ...?existing?.enumOptions.where((option) => !option.deleted),
    ]..sort(_optionOrder))
      _DraftOption(option.id, option.label),
  ];
  var addedOptions = 0;
  late final order = existing?.order ?? controller.schema?.fields.length ?? 0;
  // Survives a failed save, so retrying updates what the first attempt already created.
  final session = FieldSaveSession();
  var issues = FormIssues.none;

  /// Rust's keys for field-definition problems, by the input that shows them. Anything else
  /// lands in the slot above the buttons.
  static const _issueInputs = {
    'name': 'name',
    'field_name': 'name',
    'default': 'default',
    'scale': 'scale',
    'numeric_range': 'maximum',
    'length_range': 'max-length',
    'slider_step': 'slider-step',
  };

  static bool _isDateKind(FieldTypeKindDto kind) =>
      kind == FieldTypeKindDto.date || kind == FieldTypeKindDto.dateTime;

  bool get _relativeDefault =>
      kind == FieldTypeKindDto.date &&
      open.contains(_Chip.defaultValue) &&
      relative;

  int get _signedRelativeDays {
    final days = int.tryParse(relativeDays.text) ?? 0;
    return relativeNegative ? -days : days;
  }

  /// A slider needs a whole-number track, so only an Integer with both bounds can offer one.
  bool get _sliderAvailable =>
      kind == FieldTypeKindDto.integer && minimum != null && maximum != null;

  /// Turns the slider off once it can no longer apply, so a later bound does not revive it.
  void _dropUnavailableSlider() {
    if (!_sliderAvailable) _turnSliderOff();
  }

  void _turnSliderOff() {
    slider = false;
    open.remove(_Chip.slider);
    sliderStep.clear();
    issues = issues.without('slider-step');
  }

  /// The step to submit; null while the slider is off or the input is empty (step 1).
  int? get _submittedStep =>
      slider && _sliderAvailable ? int.tryParse(sliderStep.text) : null;

  /// Mirrors Rust's slider step rule so the common mistake is caught under the input.
  String? _sliderStepIssue() {
    if (!slider || !_sliderAvailable || sliderStep.text.isEmpty) return null;
    final step = int.tryParse(sliderStep.text);
    if (step == null || step <= 0) {
      return 'Step must be a positive whole number';
    }
    if ((maximum! - minimum!) % step != 0) {
      return 'Step must divide the range from minimum to maximum exactly';
    }
    return null;
  }

  /// Drops the shown issues for [input] once it changes, since they describe the old value.
  void _edited(String input) {
    if (issues.of(input).isNotEmpty) issues = issues.without(input);
  }

  List<EnumOptionDto> draftOptions() => [
    for (final (index, option) in options.indexed)
      EnumOptionDto(
        id: option.id,
        label: option.label.text,
        order: index,
        deleted: false,
      ),
  ];

  @override
  void dispose() {
    name.dispose();
    sliderStep.dispose();
    minLength.dispose();
    maxLength.dispose();
    relativeDays.dispose();
    super.dispose();
  }

  /// Chooses the type of a new field. Default and bounds are typed by the kind, so they cannot
  /// survive it, and neither can the chips of another type.
  void _setKind(FieldTypeKindDto value) {
    if (value == kind) return;
    kind = value;
    defaultValue = null;
    relative = true;
    relativeDays.clear();
    relativeNegative = false;
    if (kind != FieldTypeKindDto.enum_) options.clear();
    minimum = null;
    maximum = null;
    _turnSliderOff();
    if (kind != FieldTypeKindDto.text) {
      multiline = false;
      minLength.clear();
      maxLength.clear();
    }
    open.removeWhere((chip) => !_chipsFor(kind).contains(chip));
    open.removeAll([_Chip.range, _Chip.dateRange]);
  }

  bool _chipOn(_Chip chip) => switch (chip) {
    _Chip.required => required,
    _Chip.multiline => multiline,
    _Chip.slider => slider && _sliderAvailable,
    _ => open.contains(chip),
  };

  void _toggle(_Chip chip) {
    if (_chipOn(chip)) {
      _turnOff(chip);
      return;
    }
    switch (chip) {
      case _Chip.required:
        required = true;
      case _Chip.multiline:
        multiline = true;
      case _Chip.slider:
        slider = true;
        open.add(chip);
      default:
        open.add(chip);
    }
  }

  /// Turns [chip] off and clears the settings it held.
  void _turnOff(_Chip chip) {
    switch (chip) {
      case _Chip.required:
        required = false;
      case _Chip.multiline:
        multiline = false;
      case _Chip.lengthLimits:
        minLength.clear();
        maxLength.clear();
        _edited('max-length');
      case _Chip.range || _Chip.dateRange:
        minimum = null;
        maximum = null;
        _edited('maximum');
        _dropUnavailableSlider();
      case _Chip.slider:
        _turnSliderOff();
      case _Chip.defaultValue:
        defaultValue = null;
        relative = true;
        relativeDays.clear();
        relativeNegative = false;
        _edited('default');
    }
    open.remove(chip);
  }

  /// How many active records would be marked invalid by this field as it currently stands.
  ///
  /// The projected record list is already loaded in full for the collection, so this is a read of
  /// what is on screen rather than another trip through the bridge. It is a disclosure, not a
  /// guard: Rust accepts the command either way. A relative default counts as a default.
  int _missingRequiredCount() {
    if (!required || defaultValue != null || _relativeDefault) return 0;
    // A brand new field has an id no record can hold a value for yet.
    final existing = this.existing;
    if (existing == null) return controller.records.length;
    return controller.records
        .where((record) => _valueOf(record, existing.id) == null)
        .length;
  }

  /// The line under the default while it does not fit the other settings; the save action is
  /// disabled while there is one. Rust stays authoritative; this only mirrors its length and
  /// range rules.
  String? get _defaultIssue {
    if (!open.contains(_Chip.defaultValue)) return null;
    final value = defaultValue;
    if (kind == FieldTypeKindDto.text && value?.textValue != null) {
      final min = int.tryParse(minLength.text);
      final max = int.tryParse(maxLength.text);
      final length = value!.textValue!.characters.length;
      if ((min != null && length < min) || (max != null && length > max)) {
        return switch ((min, max)) {
          (final min?, final max?) when min == max =>
            'Default must be exactly $min characters.',
          (final min?, final max?) => 'Default must be $min–$max characters.',
          (final min?, null) => 'Default must be at least $min characters.',
          (null, final max?) => 'Default must be at most $max characters.',
          _ => null,
        };
      }
    }
    final number = _relativeDefault
        ? _localEpochDay() + _signedRelativeDays
        : value?.integerValue;
    if (number != null && (minimum != null || maximum != null)) {
      if ((minimum != null && number < minimum!) ||
          (maximum != null && number > maximum!)) {
        final low = _boundText(minimum);
        final high = _boundText(maximum);
        return switch ((low, high)) {
          (final low?, final high?) =>
            'Default must be between $low and $high.',
          (final low?, null) => 'Default must be at least $low.',
          (null, final high?) => 'Default must be at most $high.',
          _ => null,
        };
      }
    }
    return null;
  }

  /// A bound as the user reads it, in the field's own type.
  String? _boundText(int? bound) {
    if (bound == null) return null;
    return const FieldRendererRegistry().displayText(
      _slotField('bound', ''),
      _boundValue(bound, kind, scale),
    );
  }

  Future<bool> _confirmInvalidating(int missing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('required-confirmation'),
        title: const Text('Make this field required?'),
        content: Text(
          '$missing ${missing == 1 ? 'record has' : 'records have'} no value for this field. '
          '${missing == 1 ? 'It' : 'They'} will be marked invalid until you fill the field in. '
          'Nothing is deleted.',
        ),
        actions: [
          TextButton(
            key: const Key('required-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('required-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Make required'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _save() async {
    final stepIssue = _sliderStepIssue();
    if (stepIssue != null) {
      setState(
        () => issues = FormIssues.none.withField('slider-step', stepIssue),
      );
      return;
    }
    final missing = _missingRequiredCount();
    // Rust no longer refuses this, so the disclosure has to happen here, before the
    // command is sent and with the count the user is about to invalidate.
    if (missing > 0 && !await _confirmInvalidating(missing)) return;
    try {
      final hasDefault = open.contains(_Chip.defaultValue);
      final dto = FieldDefinitionDto(
        id: existing?.id ?? '',
        name: name.text,
        fieldType: FieldTypeDto(
          kind: kind,
          scale: kind == FieldTypeKindDto.fixedDecimal ? scale : null,
        ),
        required_: required,
        defaultValue: hasDefault && !_relativeDefault ? defaultValue : null,
        defaultRelativeDays: _relativeDefault ? _signedRelativeDays : null,
        validation: ValidationMetadataDto(
          minInteger: minimum,
          maxInteger: maximum,
          minLength: int.tryParse(minLength.text),
          maxLength: int.tryParse(maxLength.text),
        ),
        display: DisplayMetadataDto(
          multiline: multiline,
          slider: slider && _sliderAvailable,
          sliderStep: _submittedStep,
        ),
        order: order,
        deleted: false,
        // Options travel separately; the controller keeps the stored ones here.
        enumOptions: const [],
      );
      await controller.saveFieldWithOptions(
        dto,
        draftOptions(),
        session: session,
      );
      if (mounted) widget.onClosed();
    } catch (failure) {
      if (mounted) {
        setState(() => issues = FormIssues.from(failure).keyed(_issueInputs));
      }
    }
  }

  /// Asks before deleting an option that active records hold, since they keep it.
  Future<void> _removeOption(_DraftOption option) async {
    final used = controller.records
        .where(
          (record) =>
              existing != null &&
              _valueOf(record, existing!.id)?.textValue == option.id,
        )
        .length;
    if (used > 0) {
      final label = option.label.text;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('option-delete-confirmation'),
          title: Text('Delete “$label”?'),
          content: Text(
            '$used ${used == 1 ? 'record uses' : 'records use'} this option and '
            '${used == 1 ? 'keeps' : 'keep'} it, shown as “$label (deleted)”. '
            "It can't be picked for new records.",
          ),
          actions: [
            TextButton(
              key: const Key('option-delete-cancel'),
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('option-delete-confirm'),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      options.remove(option);
      if (defaultValue?.textValue == option.id) defaultValue = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.host == FieldEditorHost.panel && existing == null)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                Icon(FiIcons.addCircle, size: 18, color: Nocturne.accent),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New field',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Nocturne.accent200,
                    ),
                  ),
                ),
              ],
            ),
          ),
        FiTextInput(
          key: const Key('field-name'),
          controller: name,
          autofocus: existing == null && widget.host == FieldEditorHost.panel,
          label: 'Name',
          required: true,
          hint: 'e.g. note',
          errors: issues.of('name'),
          onChanged: (_) => setState(() => _edited('name')),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 16, bottom: 8),
          child: SectionLabel('Type'),
        ),
        _typeGridView(),
        if (kind == FieldTypeKindDto.fixedDecimal)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: FiTextInput(
              initialValue: '$scale',
              keyboardType: TextInputType.number,
              label: 'Decimal scale',
              suffixIcon: const HelpButton(HelpId.fieldDecimalScale),
              errors: issues.of('scale'),
              // The scale decides what the stored integer means, so a change to it
              // cannot leave a default or a bound behind reading as something else.
              onChanged: (value) => setState(() {
                _edited('scale');
                scale = int.tryParse(value) ?? 255;
                defaultValue = null;
                minimum = null;
                maximum = null;
              }),
            ),
          ),
        if (kind == FieldTypeKindDto.enum_) ..._optionsEditor(),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final chip in _chipsFor(kind))
                FieldOptionChip(
                  key: Key(chip.key),
                  label: chip.label,
                  selected: _chipOn(chip),
                  onTap: chip == _Chip.slider && !_sliderAvailable
                      ? null
                      : () => setState(() => _toggle(chip)),
                ),
            ],
          ),
        ),
        if (kind == FieldTypeKindDto.integer && !_sliderAvailable)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Show as slider needs a range with both ends.',
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.5)),
            ),
          ),
        ?_requiredWarning(),
        for (final chip in _chipsFor(kind))
          if (open.contains(chip)) ?_block(chip),
        if (issues.form.isNotEmpty)
          Padding(
            key: const Key('field-editor-errors'),
            padding: const EdgeInsets.only(top: 14),
            child: FormErrorLines(issues.form),
          ),
      ],
    );
    final saveLabel = existing == null ? 'Add field' : 'Save field';
    final canSave = _defaultIssue == null;
    if (widget.host == FieldEditorHost.screen) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: form,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
            child: FilledButton(
              key: const Key('field-save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: canSave ? _save : null,
              child: Text(saveLabel),
            ),
          ),
        ],
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: Nocturne.accent700),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          form,
          const SizedBox(height: 18),
          Row(
            children: [
              if (existing case final field?)
                FiIconButton(
                  key: const Key('field-delete'),
                  icon: FiIcons.delete,
                  tooltip: 'Delete field',
                  color: Nocturne.muted(.6),
                  onPressed: () async {
                    await controller.removeField(field.id);
                    widget.onClosed();
                  },
                ),
              const Spacer(),
              TextButton(
                onPressed: widget.onClosed,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('field-save'),
                onPressed: canSave ? _save : null,
                child: Text(saveLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeGridView() {
    final phone = Nocturne.isPhone(context);
    Widget tile(FieldTypeKindDto value) {
      final selected = value == kind;
      final enabled = existing == null || selected;
      return Expanded(
        child: Opacity(
          opacity: enabled ? 1 : .4,
          child: Semantics(
            button: true,
            selected: selected,
            enabled: enabled,
            child: Material(
              color: selected ? Nocturne.accent900 : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Nocturne.radius),
                side: BorderSide(
                  color: selected ? Nocturne.accent : Nocturne.divider,
                ),
              ),
              child: InkWell(
                key: Key('type-${value.name}'),
                borderRadius: BorderRadius.circular(Nocturne.radius),
                // The type is fixed once the field exists.
                onTap: existing == null
                    ? () => setState(() => _setKind(value))
                    : null,
                child: SizedBox(
                  height: phone ? 60 : 56,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 4,
                    children: [
                      Icon(
                        fieldTypeIcon(value),
                        size: 18,
                        color: selected
                            ? Nocturne.accent200
                            : Nocturne.muted(.6),
                      ),
                      Text(
                        fieldKindLabel(value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? Nocturne.accent100
                              : Nocturne.muted(.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget row(Iterable<FieldTypeKindDto> kinds) =>
        Row(spacing: 6, children: [for (final value in kinds) tile(value)]);
    return Column(
      key: const Key('type-grid'),
      spacing: 6,
      children: [row(_typeGrid.take(4)), row(_typeGrid.skip(4))],
    );
  }

  Widget? _requiredWarning() {
    final missing = _missingRequiredCount();
    if (missing == 0) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        key: const Key('required-warning'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(FiIcons.warning, size: 16, color: Nocturne.accent300),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$missing ${missing == 1 ? 'record has' : 'records have'} no value for '
              'this field and will be marked invalid until you fill them in. '
              'Add a default to avoid this.',
              style: const TextStyle(fontSize: 12, color: Nocturne.accent300),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _block(_Chip chip) {
    Widget block(Widget child) => _SettingsBlock(
      chip: chip,
      onClose: () => setState(() => _turnOff(chip)),
      child: child,
    );
    switch (chip) {
      case _Chip.required || _Chip.multiline:
        return null;
      case _Chip.lengthLimits:
        return block(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Expanded(
                child: FiTextInput(
                  key: const Key('field-min-length'),
                  controller: minLength,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  label: 'Min characters',
                  onChanged: (_) => setState(() => _edited('max-length')),
                ),
              ),
              Expanded(
                child: FiTextInput(
                  key: const Key('field-max-length'),
                  controller: maxLength,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  label: 'Max characters',
                  errors: issues.of('max-length'),
                  onChanged: (_) => setState(() => _edited('max-length')),
                ),
              ),
            ],
          ),
        );
      case _Chip.range || _Chip.dateRange:
        final dates = chip == _Chip.dateRange;
        return block(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Expanded(
                child: _slot(
                  'field-minimum',
                  dates ? 'Earliest' : 'Minimum',
                  _boundValue(minimum, kind, scale),
                  (value) => setState(() {
                    _edited('maximum');
                    minimum = value?.integerValue;
                    _dropUnavailableSlider();
                  }),
                ),
              ),
              Expanded(
                child: _slot(
                  'field-maximum',
                  dates ? 'Latest' : 'Maximum',
                  _boundValue(maximum, kind, scale),
                  (value) => setState(() {
                    _edited('maximum');
                    maximum = value?.integerValue;
                    _dropUnavailableSlider();
                  }),
                  errors: issues.of('maximum'),
                ),
              ),
            ],
          ),
        );
      case _Chip.slider:
        if (!_sliderAvailable) return null;
        return block(
          FiTextInput(
            key: const Key('field-slider-step'),
            controller: sliderStep,
            label: 'Step (optional)',
            hint: '1',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            errors: issues.of('slider-step'),
            onChanged: (_) => setState(() => _edited('slider-step')),
          ),
        );
      case _Chip.defaultValue:
        return block(_defaultBlock());
    }
  }

  Widget _defaultBlock() {
    final issue = _defaultIssue;
    final relativeEditor = kind == FieldTypeKindDto.date;
    final Widget fixed = _slot(
      'field-default',
      relativeEditor ? 'Date' : 'Default',
      defaultValue,
      (value) => setState(() {
        _edited('default');
        defaultValue = value;
      }),
      errors: issues.of('default'),
      enumOptions: draftOptions(),
      revision: [
        for (final option in options) '${option.id}=${option.label.text}',
      ].join('|'),
    );
    final text = kind == FieldTypeKindDto.text;
    final min = int.tryParse(minLength.text);
    final max = int.tryParse(maxLength.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (relativeEditor)
          FiSegmented<bool>(
            key: const Key('default-mode'),
            segments: const [
              FiSegment(true, 'Day of creation'),
              FiSegment(false, 'Fixed date'),
            ],
            value: relative,
            onChanged: (value) => setState(() {
              if (value == null) return;
              relative = value;
              _edited('default');
            }),
          ),
        if (relativeEditor && relative)
          Row(
            spacing: 10,
            children: [
              SizedBox(
                width: 76,
                child: FiSegmented<bool>(
                  key: const Key('default-sign'),
                  segments: const [FiSegment(false, '+'), FiSegment(true, '−')],
                  value: relativeNegative,
                  onChanged: (value) => setState(() {
                    if (value != null) relativeNegative = value;
                  }),
                ),
              ),
              SizedBox(
                width: 80,
                child: FiTextInput(
                  key: const Key('default-days'),
                  controller: relativeDays,
                  hint: '0',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() => _edited('default')),
                ),
              ),
              Text('days', style: TextStyle(color: Nocturne.muted(.6))),
              Expanded(
                child: Text(
                  '→ ${formatDateHuman(_localEpochDay() + _signedRelativeDays)}',
                  key: const Key('default-preview'),
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Nocturne.accent200,
                    fontFeatures: Nocturne.tabular,
                  ),
                ),
              ),
            ],
          )
        else
          fixed,
        if (text && (min != null || max != null))
          Text(
            '${defaultValue?.textValue?.characters.length ?? 0} / '
            '${_lengthRange(min, max)}',
            key: const Key('default-counter'),
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 12,
              color: issue == null ? Nocturne.muted(.55) : fieldErrorColor,
              fontFeatures: Nocturne.tabular,
            ),
          ),
        if (issue != null)
          FieldErrorMessage([issue], key: const Key('default-issue')),
      ],
    );
  }

  /// A metadata slot of the field's own type: see [_metadataInput].
  Widget _slot(
    String slot,
    String label,
    FieldValueDto? value,
    ValueChanged<FieldValueDto?> onChanged, {
    List<String> errors = const [],
    List<EnumOptionDto>? enumOptions,
    String revision = '',
  }) => _metadataInput(
    slot: slot,
    label: label,
    kind: kind,
    scale: scale,
    enumOptions: enumOptions ?? existing?.enumOptions ?? const [],
    value: value,
    onChanged: onChanged,
    errors: errors,
    revision: revision,
  );

  FieldDefinitionDto _slotField(String slot, String label) =>
      _draftField(slot, label, kind, scale, const []);

  /// The Options section of a Choice field: one row per option in the order it will be saved,
  /// each with a drag handle, its label, and a delete action; then the note on deleted options.
  List<Widget> _optionsEditor() {
    final removed = existing?.enumOptions.where((option) => option.deleted);
    final example = removed?.lastOrNull?.label ?? 'option';
    return [
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: SectionLabel('Options · ${options.length}'),
      ),
      ReorderableListView(
        key: const Key('field-options'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorder: (from, to) => setState(() {
          options.insert(to > from ? to - 1 : to, options.removeAt(from));
        }),
        children: [
          for (final (index, option) in options.indexed)
            Padding(
              key: ValueKey(option.id),
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        FiIcons.dragHandle,
                        color: Nocturne.muted(.45),
                      ),
                    ),
                  ),
                  Expanded(
                    child: FiTextInput(
                      key: ValueKey('option-label-${option.id}'),
                      controller: option.label,
                      // A freshly added row is where the user is about to type.
                      autofocus:
                          isTempOptionId(option.id) &&
                          option.label.text.isEmpty,
                      hint: 'Option label',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  FiIconButton(
                    key: ValueKey('remove-option-${option.id}'),
                    tooltip: 'Delete option',
                    icon: FiIcons.delete,
                    color: Nocturne.muted(.55),
                    onPressed: () => _removeOption(option),
                  ),
                ],
              ),
            ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('add-option'),
          onPressed: () => setState(
            () => options.add(_DraftOption(tempOptionId(++addedOptions), '')),
          ),
          icon: const Icon(FiIcons.add),
          label: const Text('Add option'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Records that already use a deleted option keep it. It shows as '
          "“$example (deleted)” and can't be picked for new records.",
          key: const Key('deleted-option-note'),
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
        ),
      ),
    ];
  }
}

/// The draft definition a metadata slot is edited through: only what the renderer needs.
FieldDefinitionDto _draftField(
  String slot,
  String label,
  FieldTypeKindDto kind,
  int scale,
  List<EnumOptionDto> enumOptions,
) => FieldDefinitionDto(
  id: slot,
  name: label,
  fieldType: FieldTypeDto(
    kind: kind,
    scale: kind == FieldTypeKindDto.fixedDecimal ? scale : null,
  ),
  // Never required: the slot itself is optional whatever the field demands of records.
  required_: false,
  validation: const ValidationMetadataDto(),
  display: const DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
  ),
  order: 0,
  deleted: false,
  enumOptions: enumOptions,
);

/// A schema-metadata slot edited with the very control that edits a record of that type.
///
/// A default and a range bound are values of the field's own type, so typing an epoch day or a
/// scaled integer by hand was never the right ask. [slot] keys the control so switching type or
/// scale rebuilds it empty rather than leaving digits that now mean something else. [revision]
/// does the same when the Choice options held in the editor change, so the dropdown never keeps
/// an option that is gone.
Widget _metadataInput({
  required String slot,
  required String label,
  required FieldTypeKindDto kind,
  required int scale,
  required List<EnumOptionDto> enumOptions,
  required FieldValueDto? value,
  required ValueChanged<FieldValueDto?> onChanged,
  List<String> errors = const [],
  String revision = '',
}) => KeyedSubtree(
  key: ValueKey('$slot-$kind-$scale-$revision'),
  child: const FieldRendererRegistry().editor(
    _draftField(slot, label, kind, scale, enumOptions),
    value,
    (typed) => onChanged(typed.kind == FieldValueKindDto.null_ ? null : typed),
    key: Key(slot),
    label: label,
    allowClear: true,
    errors: errors,
  ),
);

/// A stored range bound as a typed value of the field's own kind, so the bound is edited with a
/// date picker or a decimal box rather than as the raw integer it is compared as.
FieldValueDto? _boundValue(int? bound, FieldTypeKindDto kind, int scale) {
  if (bound == null) return null;
  return FieldValueDto(
    kind: switch (kind) {
      FieldTypeKindDto.integer => FieldValueKindDto.integer,
      FieldTypeKindDto.fixedDecimal => FieldValueKindDto.fixedDecimal,
      FieldTypeKindDto.date => FieldValueKindDto.date,
      FieldTypeKindDto.dateTime => FieldValueKindDto.dateTime,
      FieldTypeKindDto.duration => FieldValueKindDto.duration,
      // Text, boolean, and enum carry no numeric range; the control is not rendered for them.
      _ => FieldValueKindDto.null_,
    },
    integerValue: bound,
  );
}

/// A field opened as its own phone screen (mocks 7g, 7h): back, the field name (or "New field")
/// over "Field in `collection`", a ⋮ holding Delete field for an existing field, and the
/// [FieldEditorBody] with its full-width Save field / Add field.
class FieldEditorScreen extends StatelessWidget {
  const FieldEditorScreen({
    required this.controller,
    required this.collectionName,
    this.existing,
    super.key,
  });

  final CollectionsController controller;
  final String collectionName;
  final FieldDefinitionDto? existing;

  @override
  Widget build(BuildContext context) {
    final existing = this.existing;
    return Scaffold(
      key: const Key('field-editor-screen'),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
              child: Row(
                children: [
                  FiIconButton(
                    icon: FiIcons.back,
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          existing?.name ?? 'New field',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          'Field in $collectionName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (existing != null)
                    PopupMenuButton<void>(
                      key: const Key('field-menu'),
                      tooltip: 'More',
                      icon: const Icon(FiIcons.more, size: 20),
                      itemBuilder: (_) => [
                        PopupMenuItem<void>(
                          key: const Key('field-delete'),
                          onTap: () async {
                            await controller.removeField(existing.id);
                            if (context.mounted) Navigator.pop(context);
                          },
                          child: const Row(
                            children: [
                              Icon(FiIcons.delete, size: 18),
                              SizedBox(width: 12),
                              Text('Delete field'),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Expanded(
              child: FieldEditorBody(
                controller: controller,
                existing: existing,
                host: FieldEditorHost.screen,
                onClosed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
