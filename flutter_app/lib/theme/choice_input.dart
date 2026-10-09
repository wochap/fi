import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:flutter/material.dart';

/// One pickable option of a [FiChoiceInput].
final class ChoiceOption {
  const ChoiceOption({
    required this.id,
    required this.label,
    this.isNew = false,
  });

  final String id;
  final String label;

  /// An option the record form added: created only when the record is saved, shown with a
  /// "New" tag after the stored options.
  final bool isNew;
}

/// Adds an option labelled with the given text to the field (created when the record is saved)
/// and returns the id the value picks it by.
typedef AddChoiceOption = String Function(String label);

/// The option of [options] whose label equals [text] ignoring case and surrounding spaces.
ChoiceOption? exactChoiceOption(List<ChoiceOption> options, String text) {
  final needle = text.trim().toLowerCase();
  if (needle.isEmpty) return null;
  return options
      .where((option) => option.label.trim().toLowerCase() == needle)
      .firstOrNull;
}

/// What a choice sheet returned: an option id, or null when the user pressed Clear, or
/// [addLabel] when the user chose to add a new option. The sheet itself returns null when
/// dismissed without a pick.
final class ChoicePick {
  const ChoicePick(this.id) : addLabel = null;
  const ChoicePick.add(String label) : id = null, addLabel = label;

  final String? id;
  final String? addLabel;
}

/// Prefix of the ids a Choices sheet returns for options added in it, followed by the label.
const String _addedPrefix = '\u0000add:';

/// Up to this many options show as a [FiSegmented].
const int choiceSegmentedMax = 4;

/// Up to this many options show as a select or picker sheet; more get a search.
const int choiceSelectMax = 10;

/// A choice among [options] whose presentation follows the option count:
///
/// - up to 4: a [FiSegmented] (tapping the selected option again clears it when [allowClear]);
/// - 5–10: a [FiSelect] at 720px and wider, a picker sheet ([showChoicePickerSheet]) below;
/// - more than 10: a search input that filters in place at 720px and wider, a full-height search
///   sheet ([showChoiceSearchSheet]) below.
///
/// [options] are the pickable ones. [heldLabel] is shown when [value] is not among them (a
/// removed option a record still holds, read as "<label> (deleted)").
class FiChoiceInput extends StatelessWidget {
  const FiChoiceInput({
    required this.options,
    required this.onChanged,
    required this.title,
    this.value,
    this.heldLabel,
    this.allowClear = false,
    this.label,
    this.required = false,
    this.errors = const [],
    this.onAdd,
    super.key,
  });

  final List<ChoiceOption> options;
  final String? value;
  final String? heldLabel;

  /// When set, the field allows adding options from the record form: every list gets a search
  /// with an Add row, and a segmented choice a trailing "＋ Add" chip. [options] then end with
  /// the added (new) ones; the layout follows the stored options only.
  final AddChoiceOption? onAdd;

  /// Receives the picked id, or null when cleared.
  final ValueChanged<String?> onChanged;

  /// Heads the phone sheets: the field name.
  final String title;
  final bool allowClear;
  final String? label;
  final bool required;
  final List<String> errors;

  String? get _selectedLabel =>
      options.where((option) => option.id == value).firstOrNull?.label ??
      (value == null ? null : heldLabel);

  /// Picks the option equal to [text] ignoring case, or adds a new one.
  void _addOrPick(String text) {
    final match = exactChoiceOption(options, text);
    final id = match?.id ?? onAdd!(text.trim());
    if (id != value) onChanged(id);
  }

  ChoiceOption? get _selected =>
      options.where((option) => option.id == value).firstOrNull;

  @override
  Widget build(BuildContext context) {
    if (onAdd != null) return _adding(context);
    final phone = Nocturne.isPhone(context);
    final held = value != null && !options.any((option) => option.id == value);
    if (options.length <= choiceSegmentedMax && options.isNotEmpty) {
      final segmented = FiSegmented<String>(
        segments: [
          for (final option in options) FiSegment(option.id, option.label),
        ],
        value: value,
        allowClear: allowClear,
        label: label,
        required: required,
        errors: errors,
        onChanged: onChanged,
      );
      if (!held) return segmented;
      // The held removed option is not a segment; it is named under the control.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          segmented,
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedLabel ?? '',
                    key: const Key('choice-held'),
                    style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
                  ),
                ),
                if (allowClear)
                  ClearMark(
                    key: const Key('input-clear'),
                    onPressed: () => onChanged(null),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (options.length <= choiceSelectMax && !phone) {
      return FiSelect<String>(
        value: value,
        label: label,
        hint: context.l10n.themeChoose,
        required: required,
        errors: errors,
        onClear: allowClear ? () => onChanged(null) : null,
        items: [
          if (held)
            DropdownMenuItem<String>(
              value: value,
              enabled: false,
              child: Text(_selectedLabel ?? ''),
            ),
          for (final option in options)
            DropdownMenuItem(value: option.id, child: Text(option.label)),
        ],
        onChanged: (picked) {
          if (picked != null && picked != value) onChanged(picked);
        },
      );
    }
    if (!phone) {
      return _ChoiceSearchField(
        options: options,
        selectedLabel: _selectedLabel,
        label: label,
        required: required,
        errors: errors,
        allowClear: allowClear && value != null,
        onChanged: onChanged,
      );
    }
    return _ChoiceSheetField(
      selectedLabel: _selectedLabel,
      label: label,
      required: required,
      errors: errors,
      hint: options.length <= choiceSelectMax
          ? context.l10n.themeChoose
          : context.l10n.themeSearchOptions(options.length),
      search: options.length > choiceSelectMax,
      onClear: allowClear && value != null ? () => onChanged(null) : null,
      onOpen: () async {
        final sheet = options.length <= choiceSelectMax
            ? showChoicePickerSheet(
                context,
                title: title,
                options: options,
                selected: value,
                allowClear: allowClear,
              )
            : showChoiceSearchSheet(
                context,
                title: title,
                options: options,
                selected: value,
                allowClear: allowClear,
              );
        final pick = await sheet;
        if (pick != null && pick.id != value) onChanged(pick.id);
      },
    );
  }
}

extension on FiChoiceInput {
  /// The control when options can be added: the layout follows the stored options only.
  Widget _adding(BuildContext context) {
    final phone = Nocturne.isPhone(context);
    final stored = [
      for (final option in options)
        if (!option.isNew) option,
    ];
    final added = [
      for (final option in options)
        if (option.isNew) option,
    ];
    final held = value != null && !options.any((option) => option.id == value);
    if (stored.length <= choiceSegmentedMax) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          if (stored.isNotEmpty)
            FiSegmented<String>(
              segments: [
                for (final option in stored) FiSegment(option.id, option.label),
              ],
              value: value,
              allowClear: allowClear,
              label: label,
              required: this.required,
              errors: errors,
              onChanged: onChanged,
            ),
          if (held)
            Text(
              _selectedLabelOrHeld ?? '',
              key: const Key('choice-held'),
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final option in added)
                ChoicesToggleChip(
                  key: ValueKey('choice-chip-${option.id}'),
                  label: option.label,
                  isNew: true,
                  selected: option.id == value,
                  onTap: () => onChanged(option.id == value ? null : option.id),
                ),
              AddOptionChip(onSubmit: _addOrPick),
            ],
          ),
          if (stored.isEmpty && errors.isNotEmpty) FieldErrorLines(errors),
        ],
      );
    }
    final selected = _selected;
    if (!phone) {
      return _ChoiceSearchField(
        options: options,
        selectedLabel: _selectedLabelOrHeld,
        selectedIsNew: selected?.isNew ?? false,
        label: label,
        required: this.required,
        errors: errors,
        allowClear: allowClear && value != null,
        onChanged: onChanged,
        onAdd: _addOrPick,
      );
    }
    return _ChoiceSheetField(
      selectedLabel: _selectedLabelOrHeld,
      selectedIsNew: selected?.isNew ?? false,
      label: label,
      required: this.required,
      errors: errors,
      hint: context.l10n.themeSearchOptions(stored.length),
      search: true,
      onClear: allowClear && value != null ? () => onChanged(null) : null,
      onOpen: () async {
        final pick = await showChoiceSearchSheet(
          context,
          title: title,
          options: options,
          selected: value,
          allowClear: allowClear,
          allowAdd: true,
        );
        if (pick == null) return;
        if (pick.addLabel case final text?) {
          _addOrPick(text);
        } else if (pick.id != value) {
          onChanged(pick.id);
        }
      },
    );
  }

  String? get _selectedLabelOrHeld =>
      options.where((option) => option.id == value).firstOrNull?.label ??
      (value == null ? null : heldLabel);
}

/// The trailing "＋ Add" chip of a segmented choice or toggle chips: tapping it opens a small
/// input in place; submitting a non-empty text calls [onSubmit] with it.
class AddOptionChip extends StatefulWidget {
  const AddOptionChip({required this.onSubmit, super.key});

  final ValueChanged<String> onSubmit;

  @override
  State<AddOptionChip> createState() => _AddOptionChipState();
}

class _AddOptionChipState extends State<AddOptionChip> {
  final TextEditingController _text = TextEditingController();
  var _editing = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
    setState(() {
      _editing = false;
      _text.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (!_editing) {
      return ChoicesToggleChip(
        key: const Key('choice-add-chip'),
        label: l.choiceAddChip,
        leading: FiIcons.add,
        selected: false,
        onTap: () => setState(() => _editing = true),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          child: FiTextInput(
            key: const Key('choice-add-input'),
            controller: _text,
            autofocus: true,
            size: InputSize.small,
            hint: l.choiceNewOptionHint,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
        ),
        FiIconButton(
          key: const Key('choice-add-confirm'),
          icon: FiIcons.check,
          tooltip: l.choiceAddChip,
          color: Nocturne.accent,
          onPressed: _submit,
        ),
        FiIconButton(
          key: const Key('choice-add-cancel'),
          icon: FiIcons.close,
          tooltip: l.commonCancel,
          color: Nocturne.muted(.65),
          onPressed: () => setState(() {
            _editing = false;
            _text.clear();
          }),
        ),
      ],
    );
  }
}

/// The last row of a list that can add an option: "＋ Add “text”".
class _AddRow extends StatelessWidget {
  const _AddRow({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: const Key('choice-add-row'),
    borderRadius: BorderRadius.circular(Nocturne.radius),
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          spacing: 10,
          children: [
            const Icon(FiIcons.add, size: 18, color: Nocturne.accent300),
            Expanded(
              child: Text(
                context.l10n.choiceAddOption(text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, color: Nocturne.accent300),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The "New" tag on an option added from the record form.
class NewOptionTag extends StatelessWidget {
  const NewOptionTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Tag(context.l10n.choiceNewTag, key: const Key('choice-new-tag'));
}

/// The phone field that opens a choice sheet: read-only, showing the selected label.
class _ChoiceSheetField extends StatefulWidget {
  const _ChoiceSheetField({
    required this.selectedLabel,
    this.selectedIsNew = false,
    required this.label,
    required this.required,
    required this.errors,
    required this.hint,
    required this.search,
    required this.onClear,
    required this.onOpen,
  });

  final String? selectedLabel;
  final bool selectedIsNew;
  final String? label;
  final bool required;
  final List<String> errors;
  final String hint;
  final bool search;
  final VoidCallback? onClear;
  final VoidCallback onOpen;

  @override
  State<_ChoiceSheetField> createState() => _ChoiceSheetFieldState();
}

class _ChoiceSheetFieldState extends State<_ChoiceSheetField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.selectedLabel ?? '',
  );

  @override
  void didUpdateWidget(_ChoiceSheetField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.selectedLabel ?? '';
    if (_text.text != text) _text.text = text;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FiTextInput(
    controller: _text,
    readOnly: true,
    onTap: widget.onOpen,
    label: widget.label,
    hint: widget.hint,
    required: widget.required,
    errors: widget.errors,
    prefixIcon: widget.search ? const Icon(FiIcons.search, size: 18) : null,
    onClear: widget.onClear,
    suffixIcon: Padding(
      padding: const EdgeInsets.only(left: 4, right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (widget.selectedIsNew) const NewOptionTag(),
          const Icon(FiIcons.expand, size: 18),
        ],
      ),
    ),
  );
}

/// Text spans for [label] with every case-insensitive occurrence of [query] highlighted.
List<TextSpan> highlightMatches(String label, String query) {
  if (query.isEmpty) return [TextSpan(text: label)];
  final spans = <TextSpan>[];
  final lower = label.toLowerCase();
  final needle = query.toLowerCase();
  var start = 0;
  while (true) {
    final index = lower.indexOf(needle, start);
    if (index < 0) break;
    if (index > start) spans.add(TextSpan(text: label.substring(start, index)));
    spans.add(
      TextSpan(
        text: label.substring(index, index + needle.length),
        style: const TextStyle(
          color: Nocturne.accent300,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    start = index + needle.length;
  }
  if (start < label.length) spans.add(TextSpan(text: label.substring(start)));
  return spans;
}

List<ChoiceOption> _matching(List<ChoiceOption> options, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return options;
  return [
    for (final option in options)
      if (option.label.toLowerCase().contains(needle)) option,
  ];
}

/// The desktop search input for more than 10 options: type to filter, pick from the list that
/// opens under the box.
class _ChoiceSearchField extends StatefulWidget {
  const _ChoiceSearchField({
    required this.options,
    required this.selectedLabel,
    required this.label,
    required this.required,
    required this.errors,
    required this.allowClear,
    required this.onChanged,
    this.selectedIsNew = false,
    this.onAdd,
  });

  final List<ChoiceOption> options;
  final String? selectedLabel;
  final bool selectedIsNew;

  /// When set, the list ends with "＋ Add “text”" while no option equals the typed text
  /// ignoring case; picking it calls this with the text.
  final ValueChanged<String>? onAdd;
  final String? label;
  final bool required;
  final List<String> errors;
  final bool allowClear;
  final ValueChanged<String?> onChanged;

  @override
  State<_ChoiceSearchField> createState() => _ChoiceSearchFieldState();
}

class _ChoiceSearchFieldState extends State<_ChoiceSearchField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.selectedLabel ?? '',
  );
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_ChoiceSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _text.text != (widget.selectedLabel ?? '')) {
      _text.text = widget.selectedLabel ?? '';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<ChoiceOption>(
    textEditingController: _text,
    focusNode: _focus,
    displayStringForOption: (option) => option.label,
    optionsBuilder: (value) {
      // The box shows the picked label; the full list opens until the user types.
      if (value.text == widget.selectedLabel) return widget.options;
      final matches = _matching(widget.options, value.text);
      final text = value.text.trim();
      if (widget.onAdd != null &&
          text.isNotEmpty &&
          exactChoiceOption(widget.options, text) == null) {
        return [
          ...matches,
          ChoiceOption(id: '$_addedPrefix$text', label: text),
        ];
      }
      return matches;
    },
    onSelected: (option) {
      if (option.id.startsWith(_addedPrefix)) {
        widget.onAdd!(option.label);
      } else {
        widget.onChanged(option.id);
      }
    },
    fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
        TextFieldTapRegion(
          child: _SearchBox(
            controller: controller,
            focusNode: focusNode,
            label: widget.label,
            hint: context.l10n.themeTypeToSearchOptions(widget.options.length),
            required: widget.required,
            errors: widget.errors,
            onClear: widget.allowClear ? () => widget.onChanged(null) : null,
            onSubmitted: onSubmitted,
            selectedIsNew: widget.selectedIsNew,
          ),
        ),
    optionsViewBuilder: (context, onSelected, matches) {
      final query = _text.text == widget.selectedLabel ? '' : _text.text;
      return Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          color: Nocturne.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280, maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    children: [
                      for (final option in matches)
                        if (option.id.startsWith(_addedPrefix))
                          _AddRow(
                            text: option.label,
                            onTap: () => onSelected(option),
                          )
                        else
                          InkWell(
                            key: ValueKey('choice-row-${option.id}'),
                            onTap: () => onSelected(option),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                spacing: 6,
                                children: [
                                  Flexible(
                                    child: Text.rich(
                                      TextSpan(
                                        children: highlightMatches(
                                          option.label,
                                          query,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (option.isNew) const NewOptionTag(),
                                  if (widget.onAdd != null &&
                                      exactChoiceOption([option], query) !=
                                          null)
                                    Tag.neutral(context.l10n.choiceExistingTag),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Text(
                    context.l10n.themeMatchesFooter(
                      matches
                          .where(
                            (option) => !option.id.startsWith(_addedPrefix),
                          )
                          .length,
                      widget.options.length,
                    ),
                    style: TextStyle(fontSize: 11, color: Nocturne.muted(.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.hint,
    required this.required,
    required this.errors,
    required this.onClear,
    required this.onSubmitted,
    this.selectedIsNew = false,
  });

  final bool selectedIsNew;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String? label;
  final String hint;
  final bool required;
  final List<String> errors;
  final VoidCallback? onClear;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) => FiTextInput(
    controller: controller,
    focusNode: focusNode,
    label: label,
    hint: hint,
    required: required,
    errors: errors,
    prefixIcon: const Icon(FiIcons.search, size: 18),
    suffixIcon: selectedIsNew
        ? const Padding(
            padding: EdgeInsets.only(right: 10),
            child: NewOptionTag(),
          )
        : null,
    onClear: onClear,
    onSubmitted: (_) => onSubmitted(),
  );
}

/// The phone picker for 5–10 options: a bottom sheet titled [title] with Clear (when
/// [allowClear]) and one row per option, the selected one checked. Returns the pick, or null when
/// dismissed.
Future<ChoicePick?> showChoicePickerSheet(
  BuildContext context, {
  required String title,
  required List<ChoiceOption> options,
  String? selected,
  bool allowClear = false,
}) => showModalBottomSheet<ChoicePick>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => BottomSheetInsets(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (allowClear)
                TextButton(
                  key: const Key('choice-sheet-clear'),
                  onPressed: () =>
                      Navigator.pop(context, const ChoicePick(null)),
                  child: Text(context.l10n.commonClear),
                ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            children: [
              for (final option in options)
                _ChoiceRow(
                  option: option,
                  selected: option.id == selected,
                  onTap: () => Navigator.pop(context, ChoicePick(option.id)),
                ),
            ],
          ),
        ),
      ],
    ),
  ),
);

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.option,
    required this.selected,
    required this.onTap,
    this.query = '',
    this.existing = false,
  });

  final ChoiceOption option;
  final bool selected;
  final VoidCallback onTap;
  final String query;

  /// Marks the option that equals the typed text, offered instead of adding a new one.
  final bool existing;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('choice-row-${option.id}'),
    borderRadius: BorderRadius.circular(Nocturne.radius),
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: highlightMatches(option.label, query)),
                style: TextStyle(
                  fontSize: 15,
                  color: selected ? Nocturne.accent200 : null,
                ),
              ),
            ),
            if (option.isNew) ...[
              const SizedBox(width: 6),
              const NewOptionTag(),
            ],
            if (existing) ...[
              const SizedBox(width: 6),
              Tag.neutral(
                context.l10n.choiceExistingTag,
                key: const Key('choice-existing-tag'),
              ),
            ],
            if (selected)
              const Icon(
                FiIcons.check,
                key: Key('choice-selected'),
                size: 18,
                color: Nocturne.accent,
              ),
          ],
        ),
      ),
    ),
  );
}

/// The phone search for more than 10 options: a full-height sheet with a back action, [title]
/// and the option count, Clear (when [allowClear]), a search box, highlighted matches and
/// "N of M match". Picking returns to the form. Returns null when dismissed.
Future<ChoicePick?> showChoiceSearchSheet(
  BuildContext context, {
  required String title,
  required List<ChoiceOption> options,
  String? selected,
  bool allowClear = false,
  bool allowAdd = false,
}) => showModalBottomSheet<ChoicePick>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  showDragHandle: false,
  builder: (context) => _ChoiceSearchSheet(
    title: title,
    options: options,
    selected: selected,
    allowClear: allowClear,
    allowAdd: allowAdd,
  ),
);

class _ChoiceSearchSheet extends StatefulWidget {
  const _ChoiceSearchSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.allowClear,
    this.allowAdd = false,
  });

  final String title;
  final List<ChoiceOption> options;
  final String? selected;
  final bool allowClear;

  /// Ends the list with "＋ Add “text”" while no option equals the typed text ignoring case.
  final bool allowAdd;

  @override
  State<_ChoiceSearchSheet> createState() => _ChoiceSearchSheetState();
}

class _ChoiceSearchSheetState extends State<_ChoiceSearchSheet> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim();
    final matches = _matching(widget.options, query);
    final exact = widget.allowAdd
        ? exactChoiceOption(widget.options, query)
        : null;
    return SizedBox(
      key: const Key('choice-search-sheet'),
      height: MediaQuery.sizeOf(context).height,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
              child: Row(
                children: [
                  FiIconButton(
                    icon: FiIcons.back,
                    tooltip: context.l10n.commonBack,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${widget.options.length} options',
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.allowClear)
                    TextButton(
                      key: const Key('choice-sheet-clear'),
                      onPressed: () =>
                          Navigator.pop(context, const ChoicePick(null)),
                      child: Text(context.l10n.commonClear),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: FiTextInput(
                key: const Key('choice-search'),
                controller: _query,
                autofocus: true,
                hint: context.l10n.themeSearch,
                prefixIcon: const Icon(FiIcons.search, size: 18),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final option in matches)
                    _ChoiceRow(
                      option: option,
                      query: query,
                      existing: exact?.id == option.id,
                      selected: option.id == widget.selected,
                      onTap: () =>
                          Navigator.pop(context, ChoicePick(option.id)),
                    ),
                  if (widget.allowAdd && query.isNotEmpty && exact == null)
                    _AddRow(
                      text: query,
                      onTap: () =>
                          Navigator.pop(context, ChoicePick.add(query)),
                    ),
                ],
              ),
            ),
            if (query.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Text(
                  '${matches.length} of ${widget.options.length} match',
                  key: const Key('choice-match-count'),
                  style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A set of options among [options] (a Choices field), presented by the option count with the
/// same thresholds as [FiChoiceInput]:
///
/// - up to 4: wrapping toggle chips, each showing a check when on;
/// - 5–10: a field showing the picked labels, or "N picked" when they don't fit, that opens a
///   sheet titled [title] with one checkbox row per option and Done ([showChoicesSheet]);
/// - more than 10: the same field and sheet, with a search input in the sheet.
///
/// [options] are the pickable ones. [value] may hold ids that are not among them (removed options
/// a record still holds); [heldLabels] names those, read as "<label> (deleted)". Such a member can
/// be unpicked but is never offered again. [onChanged] receives the ids in option order.
class FiChoicesInput extends StatelessWidget {
  const FiChoicesInput({
    required this.options,
    required this.value,
    required this.onChanged,
    required this.title,
    this.heldLabels = const {},
    this.allowClear = false,
    this.label,
    this.required = false,
    this.errors = const [],
    this.onAdd,
    super.key,
  });

  final List<ChoiceOption> options;
  final List<String> value;
  final Map<String, String> heldLabels;

  /// When set, the field allows adding options from the record form: toggle chips end with a
  /// "＋ Add" chip and the sheet always has a search with an Add row. [options] then end with
  /// the added (new) ones; the layout follows the stored options only.
  final AddChoiceOption? onAdd;
  final ValueChanged<List<String>> onChanged;
  final String title;
  final bool allowClear;
  final String? label;
  final bool required;
  final List<String> errors;

  /// The removed members [value] holds, with their labels.
  List<ChoiceOption> get _held => [
    for (final id in value)
      if (!options.any((option) => option.id == id))
        ChoiceOption(id: id, label: heldLabels[id] ?? id),
  ];

  /// [ids] ordered as the options are, held removed members last.
  List<String> _ordered(Set<String> ids) {
    final known = {
      for (final option in options) option.id,
      for (final held in _held) held.id,
    };
    return [
      for (final option in options)
        if (ids.contains(option.id)) option.id,
      for (final held in _held)
        if (ids.contains(held.id)) held.id,
      // Options added just now are not in [options] until the parent rebuilds.
      for (final id in ids)
        if (!known.contains(id)) id,
    ];
  }

  List<String> get _pickedLabels {
    final picked = value.toSet();
    return [
      for (final option in [...options, ..._held])
        if (picked.contains(option.id)) option.label,
    ];
  }

  void _toggle(String id) {
    final next = value.toSet();
    if (!next.remove(id)) next.add(id);
    onChanged(_ordered(next));
  }

  /// The id picking [text]: the option equal to it ignoring case, or a newly added one.
  String _addOrMatch(String text) =>
      exactChoiceOption(options, text)?.id ?? onAdd!(text.trim());

  @override
  Widget build(BuildContext context) {
    final error = errors.isNotEmpty;
    final Widget control;
    final storedCount = options.where((option) => !option.isNew).length;
    final search = storedCount > choiceSelectMax || onAdd != null;
    if (storedCount <= choiceSegmentedMax) {
      final picked = value.toSet();
      control = Wrap(
        key: const Key('choices-chips'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in [...options, ..._held])
            ChoicesToggleChip(
              key: ValueKey('choices-chip-${option.id}'),
              label: option.label,
              isNew: option.isNew,
              selected: picked.contains(option.id),
              error: error,
              onTap: () => _toggle(option.id),
            ),
          if (onAdd != null)
            AddOptionChip(
              onSubmit: (text) {
                final id = _addOrMatch(text);
                if (!value.contains(id)) onChanged(_ordered({...value, id}));
              },
            ),
        ],
      );
    } else {
      control = _ChoicesSheetField(
        pickedLabels: _pickedLabels,
        hasNew: options.any(
          (option) => option.isNew && value.contains(option.id),
        ),
        hint: search
            ? context.l10n.themeSearchOptions(storedCount)
            : context.l10n.themeChoose,
        search: search,
        errors: errors,
        onClear: allowClear && value.isNotEmpty
            ? () => onChanged(const [])
            : null,
        onOpen: () async {
          final picked = await showChoicesSheet(
            context,
            title: title,
            options: options,
            held: _held,
            selected: value,
            search: search,
            allowAdd: onAdd != null,
          );
          if (picked == null) return;
          final ids = <String>{
            for (final id in picked)
              id.startsWith(_addedPrefix)
                  ? _addOrMatch(id.substring(_addedPrefix.length))
                  : id,
          };
          onChanged(_ordered(ids));
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label case final label?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: DefaultTextStyle.merge(
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
              child: required ? requiredLabel(label) : Text(label),
            ),
          ),
        control,
        if (error && storedCount <= choiceSegmentedMax) FieldErrorLines(errors),
      ],
    );
  }
}

/// A toggle chip of [FiChoicesInput]: a check when on, a 44px target on a phone.
class ChoicesToggleChip extends StatelessWidget {
  const ChoicesToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.error = false,
    this.isNew = false,
    this.leading,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool error;

  /// Shows the "New" tag after the label: an option added from the record form.
  final bool isNew;

  /// An icon before the label when not selected (the "＋ Add" chip).
  final IconData? leading;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? Nocturne.accent900 : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? Nocturne.accent700
                : error
                ? Nocturne.accent
                : Nocturne.divider,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: Nocturne.isPhone(context) ? Nocturne.touchTarget : 32,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(
                      FiIcons.check,
                      key: Key('choices-chip-check'),
                      size: 14,
                      color: Nocturne.accent200,
                    ),
                    const SizedBox(width: 6),
                  ] else if (leading case final icon?) ...[
                    Icon(icon, size: 14, color: Nocturne.accent300),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? Nocturne.accent100
                            : leading != null
                            ? Nocturne.accent300
                            : Nocturne.muted(.75),
                      ),
                    ),
                  ),
                  if (isNew) ...[
                    const SizedBox(width: 6),
                    const NewOptionTag(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The field of a [FiChoicesInput] with more than 4 options: read-only, showing the picked labels
/// joined by commas, or "N picked" when they don't fit its width.
class _ChoicesSheetField extends StatefulWidget {
  const _ChoicesSheetField({
    required this.pickedLabels,
    this.hasNew = false,
    required this.hint,
    required this.search,
    required this.errors,
    required this.onClear,
    required this.onOpen,
  });

  final List<String> pickedLabels;

  /// Some picked option is new: the field shows the "New" tag.
  final bool hasNew;
  final String hint;
  final bool search;
  final List<String> errors;
  final VoidCallback? onClear;
  final VoidCallback onOpen;

  @override
  State<_ChoicesSheetField> createState() => _ChoicesSheetFieldState();
}

class _ChoicesSheetFieldState extends State<_ChoicesSheetField> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// The joined labels when they fit in [width] at the input's text size, else "N picked".
  String _summary(BuildContext context, double width) {
    final labels = widget.pickedLabels;
    if (labels.isEmpty) return '';
    final joined = labels.join(', ');
    final painter = TextPainter(
      text: TextSpan(
        text: joined,
        style: DefaultTextStyle.of(
          context,
        ).style.merge(const TextStyle(fontSize: 14)),
      ),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final fits = painter.width <= width;
    painter.dispose();
    return fits ? joined : context.l10n.themeChoicesPicked(labels.length);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Room for the padding, the clear mark and the caret.
      final room = constraints.maxWidth - (widget.search ? 140 : 110);
      final text = _summary(context, room);
      if (_text.text != text) _text.text = text;
      return FiTextInput(
        key: const Key('choices-field'),
        controller: _text,
        readOnly: true,
        onTap: widget.onOpen,
        hint: widget.hint,
        errors: widget.errors,
        prefixIcon: widget.search ? const Icon(FiIcons.search, size: 18) : null,
        onClear: widget.onClear,
        suffixIcon: Padding(
          padding: const EdgeInsets.only(left: 4, right: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              if (widget.hasNew) const NewOptionTag(),
              const Icon(FiIcons.expand, size: 18),
            ],
          ),
        ),
      );
    },
  );
}

/// The checkbox sheet of a [FiChoicesInput]: [title] over "N picked", one checkbox row per
/// option, removed members ([held]) while they stay picked, a search input when [search], and
/// Done. Returns the picked ids on Done, or null when dismissed.
Future<List<String>?> showChoicesSheet(
  BuildContext context, {
  required String title,
  required List<ChoiceOption> options,
  required List<String> selected,
  List<ChoiceOption> held = const [],
  bool search = false,
  bool allowAdd = false,
}) => showModalBottomSheet<List<String>>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => _ChoicesSheet(
    title: title,
    options: options,
    held: held,
    selected: selected,
    search: search || allowAdd,
    allowAdd: allowAdd,
  ),
);

class _ChoicesSheet extends StatefulWidget {
  const _ChoicesSheet({
    required this.title,
    required this.options,
    required this.held,
    required this.selected,
    required this.search,
    this.allowAdd = false,
  });

  final String title;
  final List<ChoiceOption> options;
  final List<ChoiceOption> held;
  final List<String> selected;
  final bool search;

  /// Ends the list with "＋ Add “text”" while no option equals the typed text ignoring case.
  /// An added option is picked at once and returned as an id starting with [_addedPrefix].
  final bool allowAdd;

  @override
  State<_ChoicesSheet> createState() => _ChoicesSheetState();
}

class _ChoicesSheetState extends State<_ChoicesSheet> {
  late final Set<String> _picked = widget.selected.toSet();
  final TextEditingController _query = TextEditingController();

  /// Options added in this sheet, picked until unpicked.
  final List<ChoiceOption> _added = [];

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim();
    // A removed member is listed only while it stays picked: once unpicked it is gone.
    final held = [
      for (final option in widget.held)
        if (_picked.contains(option.id)) option,
    ];
    final added = [
      for (final option in _added)
        if (_picked.contains(option.id)) option,
    ];
    final all = [...widget.options, ...added, ...held];
    final matches = _matching(all, query);
    final exact = widget.allowAdd ? exactChoiceOption(all, query) : null;
    return BottomSheetInsets(
      child: ConstrainedBox(
        key: const Key('choices-sheet'),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          context.l10n.themeChoicesPicked(_picked.length),
                          key: const Key('choices-sheet-count'),
                          style: TextStyle(
                            fontSize: 12,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: const Key('choices-sheet-done'),
                    onPressed: () => Navigator.pop(context, [
                      for (final option in [
                        ...widget.options,
                        ..._added,
                        ...widget.held,
                      ])
                        if (_picked.contains(option.id)) option.id,
                    ]),
                    child: Text(context.l10n.commonDone),
                  ),
                ],
              ),
            ),
            if (widget.search)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: FiTextInput(
                  key: const Key('choices-search'),
                  controller: _query,
                  hint: context.l10n.themeSearchOptions(
                    widget.options.where((option) => !option.isNew).length,
                  ),
                  prefixIcon: const Icon(FiIcons.search, size: 18),
                  onClear: query.isEmpty
                      ? null
                      : () => setState(() => _query.clear()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                children: [
                  for (final option in matches)
                    InkWell(
                      key: ValueKey('choices-row-${option.id}'),
                      borderRadius: BorderRadius.circular(Nocturne.radius),
                      onTap: () => setState(() {
                        if (!_picked.remove(option.id)) _picked.add(option.id);
                      }),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _picked.contains(option.id),
                              onChanged: (_) => setState(() {
                                if (!_picked.remove(option.id)) {
                                  _picked.add(option.id);
                                }
                              }),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: highlightMatches(
                                    option.label,
                                    query,
                                  ),
                                ),
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                            if (option.isNew) ...[
                              const SizedBox(width: 6),
                              const NewOptionTag(),
                            ],
                            if (exact?.id == option.id) ...[
                              const SizedBox(width: 6),
                              Tag.neutral(
                                context.l10n.choiceExistingTag,
                                key: const Key('choice-existing-tag'),
                              ),
                            ],
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                    ),
                  if (widget.allowAdd && query.isNotEmpty && exact == null)
                    _AddRow(
                      text: query,
                      onTap: () => setState(() {
                        final option = ChoiceOption(
                          id: '$_addedPrefix$query',
                          label: query,
                          isNew: true,
                        );
                        _added.add(option);
                        _picked.add(option.id);
                        _query.clear();
                      }),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A Choices value in a record list: one small tag per picked label in option order, the tags
/// that don't fit the width collapsed into one "+N" tag.
class ChoicesTagRow extends StatelessWidget {
  const ChoicesTagRow(this.labels, {super.key});

  final List<String> labels;

  static const double _gap = 4;
  static const TextStyle _style = TextStyle(fontSize: 11, letterSpacing: .22);

  static double _tagWidth(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + 20;
    painter.dispose();
    return width;
  }

  /// How many of [labels] fit in [maxWidth], leaving room for the "+N" tag when some don't.
  static int fitting(
    BuildContext context,
    List<String> labels,
    double maxWidth,
  ) {
    final widths = [for (final label in labels) _tagWidth(context, label)];
    var used = 0.0;
    for (var index = 0; index < labels.length; index++) {
      final next = used + (index == 0 ? 0 : _gap) + widths[index];
      final rest = labels.length - index - 1;
      final more = rest == 0
          ? 0
          : _gap + _tagWidth(context, context.l10n.recordsMoreTags(rest));
      if (next + more > maxWidth) return index;
      used = next;
    }
    return labels.length;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final shown = constraints.maxWidth.isFinite
          ? fitting(context, labels, constraints.maxWidth)
          : labels.length;
      final hidden = labels.length - shown;
      return ClipRect(
        child: Row(
          key: const Key('choices-tags'),
          spacing: _gap,
          children: [
            for (final label in labels.take(shown))
              Tag.neutral(label, key: ValueKey('choices-tag-$label')),
            if (hidden > 0)
              Tag.outline(
                context.l10n.recordsMoreTags(hidden),
                key: const Key('choices-tag-more'),
              ),
          ],
        ),
      );
    },
  );
}
