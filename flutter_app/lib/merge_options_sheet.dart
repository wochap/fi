import 'package:fi/controllers.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/form_surface.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// The option ids [record] holds in [fieldId]: a Choice value or the members of a Choices value.
List<String> heldOptions(RecordDto record, String fieldId) {
  for (final item in record.values) {
    if (item.fieldId != fieldId) continue;
    return switch (item.value.kind) {
      FieldValueKindDto.enum_ => [?item.value.textValue],
      FieldValueKindDto.enumSet => item.value.listValue,
      _ => const [],
    };
  }
  return const [];
}

/// Opens the merge sheet (mock schema-merge-options) for [field] with [checked] pre-checked and
/// [keep] kept. Submits the merge on confirm and closes; a rejected merge keeps the sheet open
/// with the typed error.
Future<void> showMergeOptionsSheet(
  BuildContext context, {
  required CollectionsController controller,
  required FieldDefinitionDto field,
  required Set<String> checked,
  required String keep,
}) => showFormSurface<void>(
  context,
  builder: (_) => _MergeOptionsSheet(
    controller: controller,
    field: field,
    checked: checked,
    keep: keep,
  ),
);

class _MergeOptionsSheet extends StatefulWidget {
  const _MergeOptionsSheet({
    required this.controller,
    required this.field,
    required this.checked,
    required this.keep,
  });

  final CollectionsController controller;
  final FieldDefinitionDto field;
  final Set<String> checked;
  final String keep;

  @override
  State<_MergeOptionsSheet> createState() => _MergeOptionsSheetState();
}

class _MergeOptionsSheetState extends State<_MergeOptionsSheet> {
  late final checked = {...widget.checked};
  late var keep = widget.keep;
  var issues = FormIssues.none;
  var busy = false;

  late final active = [
    for (final option in widget.field.enumOptions)
      if (!option.deleted) option,
  ]..sort((left, right) => left.order.compareTo(right.order));

  late final held = [
    for (final record in widget.controller.records)
      heldOptions(record, widget.field.id).toSet(),
  ];

  int _count(String id) => held.where((ids) => ids.contains(id)).length;

  String _label(String id) =>
      active.firstWhere((option) => option.id == id).label;

  void _toggle(String id) => setState(() {
    if (!checked.remove(id)) {
      checked.add(id);
      if (!checked.contains(keep)) keep = id;
    } else if (keep == id && checked.isNotEmpty) {
      keep = checked.first;
    }
  });

  Future<void> _merge() async {
    setState(() => busy = true);
    try {
      await widget.controller.mergeEnumOptions(widget.field.id, keep, [
        for (final id in checked)
          if (id != keep) id,
      ]);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          issues = FormIssues.from(failure);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final choices = widget.field.fieldType.kind == FieldTypeKindDto.enumSet;
    final using = held.where((ids) => ids.any(checked.contains)).length;
    final both = held
        .where((ids) => ids.where(checked.contains).length > 1)
        .length;
    final keptLabel = checked.contains(keep) ? _label(keep) : '';
    final muted = TextStyle(fontSize: 12, color: Nocturne.muted(.55));
    return FormSurface(
      title: l.mergeOptionsTitle,
      contextLabel: l.mergeOptionsSubtitle(
        widget.field.name,
        choices ? l.fieldTypeChoices : l.fieldTypeChoice,
      ),
      showContextInDialog: true,
      primaryLabel: l.fieldEditorMerge,
      primaryKey: const Key('merge-confirm'),
      onPrimary: checked.length >= 2 && !busy ? _merge : null,
      errors: issues.formLines(l),
      body: Column(
        key: const Key('merge-options-sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionLabel(l.mergeOptionsToMerge),
          for (final option in active)
            CheckboxListTile(
              key: ValueKey('merge-check-${option.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: checked.contains(option.id),
              onChanged: busy ? null : (_) => _toggle(option.id),
              title: Text(option.label),
              secondary: Text(
                l.mergeOptionsRecords(_count(option.id)),
                style: muted,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: SectionLabel(l.mergeOptionsKeep),
          ),
          RadioGroup<String>(
            groupValue: keep,
            onChanged: (value) {
              if (value != null && !busy) setState(() => keep = value);
            },
            child: Column(
              children: [
                for (final option in active)
                  if (checked.contains(option.id))
                    RadioListTile<String>(
                      key: ValueKey('merge-keep-${option.id}'),
                      contentPadding: EdgeInsets.zero,
                      value: option.id,
                      title: Text(option.label),
                      subtitle: option.id == keep
                          ? Text(l.mergeOptionsLabelStays, style: muted)
                          : null,
                    ),
              ],
            ),
          ),
          if (checked.length >= 2) ...[
            const SizedBox(height: 8),
            Text(
              l.mergeOptionsWillUse(using, keptLabel),
              key: const Key('merge-will-use'),
            ),
            if (choices && both > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.mergeOptionsHadBoth(both, keptLabel),
                  key: const Key('merge-had-both'),
                  style: muted,
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              spacing: 6,
              children: [
                Icon(FiIcons.warning, size: 14, color: Nocturne.muted(.55)),
                Text(l.mergeOptionsCantUndo, style: muted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
