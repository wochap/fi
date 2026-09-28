import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:flutter/material.dart';

/// One pickable option of a [FiChoiceInput].
final class ChoiceOption {
  const ChoiceOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// What a choice sheet returned: an option id, or null when the user pressed Clear. The sheet
/// itself returns null when dismissed without a pick.
final class ChoicePick {
  const ChoicePick(this.id);

  final String? id;
}

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
    super.key,
  });

  final List<ChoiceOption> options;
  final String? value;
  final String? heldLabel;

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

  @override
  Widget build(BuildContext context) {
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
        hint: 'Choose…',
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
          ? 'Choose…'
          : 'Search ${options.length} options',
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

/// The phone field that opens a choice sheet: read-only, showing the selected label.
class _ChoiceSheetField extends StatefulWidget {
  const _ChoiceSheetField({
    required this.selectedLabel,
    required this.label,
    required this.required,
    required this.errors,
    required this.hint,
    required this.search,
    required this.onClear,
    required this.onOpen,
  });

  final String? selectedLabel;
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
    suffixIcon: const Padding(
      padding: EdgeInsets.only(left: 4, right: 10),
      child: Icon(FiIcons.expand, size: 18),
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
  });

  final List<ChoiceOption> options;
  final String? selectedLabel;
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
    optionsBuilder: (value) =>
        // The box shows the picked label; the full list opens until the user types.
        value.text == widget.selectedLabel
        ? widget.options
        : _matching(widget.options, value.text),
    onSelected: (option) => widget.onChanged(option.id),
    fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
        TextFieldTapRegion(
          child: _SearchBox(
            controller: controller,
            focusNode: focusNode,
            label: widget.label,
            hint: 'Type to search ${widget.options.length} options',
            required: widget.required,
            errors: widget.errors,
            onClear: widget.allowClear ? () => widget.onChanged(null) : null,
            onSubmitted: onSubmitted,
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
                        InkWell(
                          onTap: () => onSelected(option),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text.rich(
                              TextSpan(
                                children: highlightMatches(option.label, query),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Text(
                    '${matches.length} of ${widget.options.length} · ↑↓ to move, '
                    'Enter to pick',
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
  });

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
                  child: const Text('Clear'),
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
  });

  final ChoiceOption option;
  final bool selected;
  final VoidCallback onTap;
  final String query;

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
  ),
);

class _ChoiceSearchSheet extends StatefulWidget {
  const _ChoiceSearchSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.allowClear,
  });

  final String title;
  final List<ChoiceOption> options;
  final String? selected;
  final bool allowClear;

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
                    tooltip: 'Back',
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
                      child: const Text('Clear'),
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
                hint: 'Search',
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
                      selected: option.id == widget.selected,
                      onTap: () =>
                          Navigator.pop(context, ChoicePick(option.id)),
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
