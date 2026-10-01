import 'dart:async';

import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/controllers.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/form_errors.dart';
import 'package:fi/theme/form_surface.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:fi/widgets/query_editor_dialog.dart';
import 'package:fi/widgets/widget_renderers.dart';
import 'package:flutter/material.dart';

/// Enum option id to label, so a category axis can show `Migraine` while the exact value stays
/// the synchronized option identifier.
Map<String, String> enumLabelsFor(CollectionSchemaDto? schema) => {
  for (final field in schema?.fields ?? const <FieldDefinitionDto>[])
    if (field.fieldType.kind == FieldTypeKindDto.enum_)
      for (final option in field.enumOptions)
        if (!option.deleted) option.id: option.label,
};

/// The ordered responsive widget section of a collection screen. It sits above the record list
/// and never replaces it.
final class CollectionDashboard extends StatelessWidget {
  const CollectionDashboard({super.key, required this.controller});

  final CollectionsController controller;

  static const _registry = WidgetRendererRegistry();

  @override
  Widget build(BuildContext context) {
    final definitions = controller.widgetDefinitions;
    final schema = controller.schema;
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: SectionLabel(l.widgetDashboard)),
            if (controller.widgetFailure case final failure?)
              Expanded(
                child: Text(
                  bridgeMessage(context.l10n, failure),
                  style: const TextStyle(fontSize: 12, color: Nocturne.error),
                ),
              ),
            Flexible(
              child: TextButton.icon(
                key: const Key('reorder-widgets'),
                style: TextButton.styleFrom(
                  foregroundColor: Nocturne.muted(.6),
                ),
                onPressed: definitions.length < 2
                    ? null
                    : () => unawaited(showWidgetReorder(context, controller)),
                icon: const Icon(FiIcons.reorder),
                label: Text(l.widgetReorder),
              ),
            ),
            Flexible(
              child: TextButton.icon(
                key: const Key('add-widget'),
                onPressed: () =>
                    unawaited(showWidgetEditor(context, controller)),
                icon: const Icon(FiIcons.add),
                label: Text(l.widgetAdd),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (definitions.isEmpty)
          Text(
            l.widgetEmptyDashboard,
            style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // One breakpoint keeps narrow Android and wide Linux windows usable with the same
              // deterministic order and the same structured sizing hints.
              final wide = constraints.maxWidth >= 720;
              final labels = enumLabelsFor(schema);
              final available = constraints.maxWidth;
              return Wrap(
                spacing: _gap,
                runSpacing: _gap,
                children: [
                  for (final definition in definitions)
                    SizedBox(
                      key: ValueKey('widget-${definition.id}'),
                      width: _tileWidth(
                        definition.layout.size,
                        available,
                        wide,
                      ),
                      height: _tileHeight(definition.layout.size),
                      child: NocturneCard(
                        padding: EdgeInsets.zero,
                        // The glow marks a headline number; charts keep a flat ground.
                        gradient:
                            definition.widgetType == 'core.aggregate-number'
                            ? nocturneGlow()
                            : null,
                        onTap: () => unawaited(
                          showWidgetEditor(context, controller, definition),
                        ),
                        child: _registry.build(
                          WidgetRenderContext(
                            definition: definition,
                            evaluation: controller.evaluationFor(definition.id),
                            enumLabels: labels,
                            summary: _summary(l, definition, schema),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: wide
                        ? _tileWidth(WidgetSizeDto.small, available, true)
                        : available,
                    height: wide ? _tileHeight(WidgetSizeDto.small) : 48,
                    child: DashedSlot(
                      onTap: () =>
                          unawaited(showWidgetEditor(context, controller)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FiIcons.add),
                          const SizedBox(width: 8),
                          Text(l.widgetAdd),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  /// The query in words for the tile's meta line, e.g. `Sum of Amount · all records`.
  String? _summary(
    AppLocalizations l,
    WidgetDefinitionDto definition,
    CollectionSchemaDto? schema,
  ) {
    if (schema == null) return null;
    final query = controller.queryDefinitions
        .where((item) => item.id == definition.queryId)
        .firstOrNull;
    if (query == null) return null;
    final description = describeQuery(l, query, schema);
    return query.query?.filter == null
        ? l.widgetAllRecords(description)
        : description;
  }
}

const double _gap = 12;

/// Three columns on a wide screen: small and medium tiles take one, large two, full the row.
/// A phone stacks full-width tiles with small ones in pairs.
double _tileWidth(WidgetSizeDto size, double available, bool wide) {
  if (!wide) {
    return size == WidgetSizeDto.small ? (available - _gap) / 2 : available;
  }
  final column = (available - 2 * _gap) / 3;
  return switch (size) {
    WidgetSizeDto.small || WidgetSizeDto.medium => column,
    WidgetSizeDto.large => 2 * column + _gap,
    WidgetSizeDto.full => available,
  };
}

double _tileHeight(WidgetSizeDto size) => switch (size) {
  WidgetSizeDto.small => 118,
  WidgetSizeDto.medium => 220,
  WidgetSizeDto.large => 290,
  WidgetSizeDto.full => 330,
};

/// Deterministic reorder of the active widgets.
Future<void> showWidgetReorder(
  BuildContext context,
  CollectionsController controller,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(context.l10n.widgetOrder),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final definitions = [...controller.widgetDefinitions];
            return ReorderableListView.builder(
              itemCount: definitions.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex--;
                final moved = definitions.removeAt(oldIndex);
                definitions.insert(newIndex, moved);
                unawaited(
                  controller.reorderWidgets(
                    definitions.map((item) => item.id).toList(),
                  ),
                );
              },
              itemBuilder: (context, index) => ListTile(
                key: ValueKey(definitions[index].id),
                leading: Text('${index + 1}'),
                title: Text(
                  definitions[index].title.isEmpty
                      ? definitions[index].widgetType
                      : definitions[index].title,
                ),
                subtitle: Text(definitions[index].widgetType),
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(context.l10n.commonDone),
        ),
      ],
    ),
  );
}

/// Guided add/edit flow. It submits typed query and widget definitions and lets Rust validate
/// them before anything is mutated; no SQL and no executable configuration is accepted here.
Future<void> showWidgetEditor(
  BuildContext context,
  CollectionsController controller, [
  WidgetDefinitionDto? existing,
]) async {
  await showFormSurface<void>(
    context,
    builder: (route) =>
        _WidgetEditor(controller: controller, existing: existing),
  );
}

final class _WidgetEditor extends StatefulWidget {
  const _WidgetEditor({required this.controller, this.existing});

  final CollectionsController controller;
  final WidgetDefinitionDto? existing;

  @override
  State<_WidgetEditor> createState() => _WidgetEditorState();
}

final class _WidgetEditorState extends State<_WidgetEditor> {
  late final CollectionsController controller = widget.controller;
  late final WidgetDefinitionDto? existing = widget.existing;
  late final bool supported;
  late WidgetSizeDto size;
  final title = TextEditingController();

  /// The whole query, including the widget type that selects its result shape.
  late QueryBuilderState query;

  // Query source: reuse a saved definition or build a new typed one.
  late bool reuseQuery;
  String? savedQueryId;

  // Presentation, kept separate from the query.
  final suffix = TextEditingController();
  final axisLabel = TextEditingController();
  bool showPoints = false;
  int? barWidth;
  int? pointRadius;

  /// Set by the first Save; blockers stay hidden until then.
  bool attempted = false;

  /// What Rust rejected on the last save, by input key (`title`, `query`) or form slot.
  FormIssues saveIssues = FormIssues.none;

  /// Rust's keys for widget problems, by the input that shows them.
  static const _issueInputs = {
    'title': 'title',
    'widget_title': 'title',
    'query_id': 'query',
  };

  String get widgetType => query.widgetType;

  @override
  void initState() {
    super.initState();
    final initialType =
        existing?.widgetType ??
        (controller.widgetDescriptors.isEmpty
            ? 'core.aggregate-number'
            : controller.widgetDescriptors.first.widgetType);
    query = QueryBuilderState(widgetType: initialType);
    supported = existing == null
        ? true
        : controller.widgetDescriptors.any(
            (descriptor) => descriptor.widgetType == existing!.widgetType,
          );
    size = existing?.layout.size ?? WidgetSizeDto.medium;
    title.text = existing?.title ?? '';
    savedQueryId = existing?.queryId;
    reuseQuery = existing != null;
    final config = existing == null
        ? null
        : WidgetConfig(existing!.configuration.body);
    suffix.text = config?.textAt('suffix') ?? '';
    axisLabel.text = config?.textAt('y_axis_label') ?? '';
    showPoints = config?.booleanAt('show_points') ?? false;
    barWidth = config?.integerAt('bar_width');
    pointRadius = config?.integerAt('point_radius');
  }

  @override
  void dispose() {
    title.dispose();
    suffix.dispose();
    axisLabel.dispose();
    super.dispose();
  }

  /// What still has to be chosen before the form can be submitted, by where it shows: under the
  /// title, under the saved-query selector, or (for the query builder) in the form slot.
  FormIssues get _blockers {
    var issues = FormIssues.none;
    if (title.text.trim().isEmpty) {
      issues = issues.withField('title', context.l10n.widgetTitleRequired);
    }
    if (reuseQuery) {
      if (savedQueryId == null) {
        issues = issues.withField(
          'query',
          context.l10n.widgetSavedQueryRequired,
        );
      }
    } else {
      issues = issues.withForm(query.blocker(context.l10n));
    }
    return issues;
  }

  /// Blockers once the user has tried to save, then Rust's issues from that save.
  FormIssues get _shown {
    if (!attempted) return saveIssues;
    final blockers = _blockers;
    return FormIssues(
      byField: {
        for (final key in {
          ...blockers.byField.keys,
          ...saveIssues.byField.keys,
        })
          key: [...blockers.of(key), ...saveIssues.of(key)],
      },
      form: [...blockers.form, ...saveIssues.form],
    );
  }

  /// Clears Rust's issues for [key] once the input they describe changes.
  void _edited(String key) {
    if (saveIssues.of(key).isNotEmpty) saveIssues = saveIssues.without(key);
  }

  QueryDefinitionDto? get _selectedQuery => controller.queryDefinitions
      .where((item) => item.id == savedQueryId)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final schema = controller.schema;
    final shown = _shown;
    final l = context.l10n;
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: [
        if (supported) ...[
          FiSelect<String>(
            key: const Key('widget-type'),
            value: widgetType,
            label: l.widgetType,
            suffixIcon: const HelpButton(HelpId.widgetType),
            items: [
              for (final descriptor in controller.widgetDescriptors)
                DropdownMenuItem(
                  value: descriptor.widgetType,
                  child: Text(
                    widgetTypeName(l, descriptor.widgetType, descriptor.label),
                  ),
                ),
            ],
            onChanged: (value) => setState(() {
              query = query.copyWith(
                widgetType: value!,
                bucket: value == 'core.scatter-plot' ? null : query.bucket,
              );
            }),
          ),
        ] else ...[
          // An unsupported widget keeps its type; only safe metadata is editable.
          Text(l.widgetTypeValue('${existing?.widgetType}')),
          Text(
            l.widgetUnsupportedNotice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        FiTextInput(
          key: const Key('widget-title'),
          controller: title,
          label: l.widgetTitle,
          required: true,
          errors: shown.fieldLines(context.l10n, 'title'),
          onChanged: (_) => setState(() => _edited('title')),
        ),
        FiSwitchTile(
          key: const Key('reuse-query'),
          contentPadding: EdgeInsets.zero,
          title: Text(l.widgetUseSavedQuery),
          secondary: const HelpButton(HelpId.widgetUseSavedQuery),
          value: reuseQuery,
          onChanged: (value) => setState(() {
            _edited('query');
            reuseQuery = value;
          }),
        ),
        if (reuseQuery) ...[
          FiSelect<String>(
            key: const Key('saved-query'),
            value:
                controller.queryDefinitions.any(
                  (item) => item.id == savedQueryId,
                )
                ? savedQueryId
                : null,
            label: l.widgetSavedQuery,
            required: true,
            errors: shown.fieldLines(context.l10n, 'query'),
            items: [
              for (final query in controller.queryDefinitions)
                DropdownMenuItem(value: query.id, child: Text(query.name)),
            ],
            onChanged: (value) => setState(() {
              _edited('query');
              savedQueryId = value;
            }),
          ),
          if (_selectedQuery case final selected? when schema != null)
            ..._savedQueryActions(schema, selected),
        ] else if (schema != null)
          QueryBuilder(
            schema: schema,
            state: query,
            onChanged: (next) => setState(() => query = next),
          ),
        const Divider(height: 8),
        Text(
          l.widgetPresentation,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (supported)
          ..._presentationFields(l)
        else
          Text(
            l.widgetConfigVersionPreserved(
              '${existing?.configuration.version}',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const Divider(height: 8),
        Text(
          l.widgetSize,
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
        ),
        const SizedBox(height: 5),
        SegmentedButton<WidgetSizeDto>(
          key: const Key('widget-size'),
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(value: WidgetSizeDto.small, label: Text('S')),
            const ButtonSegment(value: WidgetSizeDto.medium, label: Text('M')),
            const ButtonSegment(value: WidgetSizeDto.large, label: Text('L')),
            ButtonSegment(
              value: WidgetSizeDto.full,
              label: Text(l.widgetSizeFull),
            ),
          ],
          selected: {size},
          onSelectionChanged: (value) => setState(() => size = value.single),
        ),
      ],
    );
    // Wide screens get the form beside a live preview of the tile (mock 2d); narrower ones pin
    // a compact preview above the buttons.
    return FormSurface(
      title: existing == null ? l.widgetAdd : l.widgetEdit,
      width: 520,
      body: form,
      aside: _preview(schema),
      pinnedAside: _preview(schema, compact: true),
      showRequiredLegend: true,
      message: shown.form.isEmpty
          ? null
          : FormErrorLines(
              shown.formLines(context.l10n),
              key: const Key('widget-editor-error'),
            ),
      headerActions: [
        if (existing != null)
          FormHeaderAction(
            key: const Key('remove-widget'),
            icon: FiIcons.delete,
            label: l.widgetRemove,
            tooltip: l.widgetRemoveTooltip,
            onPressed: () async {
              // Capture the navigator before the await so no BuildContext crosses the gap.
              final navigator = Navigator.of(context);
              await controller.removeWidget(existing!.id);
              navigator.pop();
            },
          ),
      ],
      primaryKey: const Key('save-widget'),
      primaryLabel: l.commonSave,
      // Save stays enabled; pressing it shows what is missing under the input it belongs to.
      onPrimary: _save,
    );
  }

  /// What the tile will look like: the saved evaluation for an existing widget, the title and
  /// query in words for a new one, and what the chosen size spans. [compact] keeps only the
  /// label and a short tile, for pinning above the buttons on a narrow screen.
  Widget _preview(CollectionSchemaDto? schema, {bool compact = false}) {
    final l = context.l10n;
    final source = reuseQuery
        ? _selectedQuery
        : schema == null || query.blocker(l) != null
        ? null
        : query.toDefinition(
            schema,
            title.text.trim(),
            0,
            decimalSeparator: decimalSeparatorOf(context),
          );
    final summary = source == null || schema == null
        ? null
        : describeQuery(l, source, schema);
    final definition = existing;
    final heading = title.text.trim().isEmpty
        ? l.widgetUntitled
        : title.text.trim();
    final evaluation = definition == null
        ? null
        : controller.evaluationFor(definition.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(l.widgetPreview),
        SizedBox(height: compact ? 6 : 10),
        SizedBox(
          height: compact ? 118 : _tileHeight(size).clamp(118, 220),
          child: NocturneCard(
            padding: EdgeInsets.zero,
            gradient: widgetType == 'core.aggregate-number'
                ? nocturneGlow()
                : null,
            child: definition != null && evaluation != null && supported
                ? CollectionDashboard._registry.build(
                    WidgetRenderContext(
                      definition: definition,
                      evaluation: evaluation,
                      enumLabels: enumLabelsFor(schema),
                      summary: summary,
                    ),
                  )
                : WidgetTile(
                    title: heading,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Icon(
                              _typeIcon(widgetType),
                              size: 32,
                              color: Nocturne.muted(.35),
                            ),
                          ),
                        ),
                        Text(
                          summary ?? l.widgetChooseData,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Nocturne.muted(.5),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 10),
          Text(switch (size) {
            WidgetSizeDto.small => l.widgetSizeSmallHint,
            WidgetSizeDto.medium => l.widgetSizeMediumHint,
            WidgetSizeDto.large => l.widgetSizeLargeHint,
            WidgetSizeDto.full => l.widgetSizeFullHint,
          }, style: TextStyle(fontSize: 12, color: Nocturne.muted(.5))),
        ],
      ],
    );
  }

  /// The selected saved query in words, plus the two ways to change it. Editing in place reaches
  /// every widget using the query, so the alternative sits beside it rather than behind a menu.
  List<Widget> _savedQueryActions(
    CollectionSchemaDto schema,
    QueryDefinitionDto selected,
  ) {
    final used = widgetsUsingQuery(controller, selected.id);
    final l = context.l10n;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          describeQuery(l, selected, schema),
          key: const Key('saved-query-summary'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      Text(
        l.queryUsedBy(used),
        key: const Key('saved-query-usage'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      // Wraps so both fit in a phone sheet.
      Wrap(
        children: [
          TextButton(
            key: const Key('edit-saved-query'),
            onPressed: () =>
                unawaited(_editSavedQuery(schema, selected, asNew: false)),
            child: Text(l.queryEditThis),
          ),
          TextButton(
            key: const Key('save-query-as-new'),
            onPressed: () =>
                unawaited(_editSavedQuery(schema, selected, asNew: true)),
            child: Text(l.querySaveAsNew),
          ),
        ],
      ),
    ];
  }

  Future<void> _editSavedQuery(
    CollectionSchemaDto schema,
    QueryDefinitionDto selected, {
    required bool asNew,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (dialog) => QueryEditorDialog(
        schema: schema,
        heading: asNew
            ? context.l10n.querySaveAsNewTitle
            : context.l10n.queryEditTitle,
        initialName: asNew
            ? context.l10n.queryCopyName(selected.name)
            : selected.name,
        initialState: QueryBuilderState.fromDefinition(
          selected,
          schema,
          decimalSeparator: decimalSeparatorOf(context),
        ),
        // Saving as new starts from the same contents but must not inherit the id.
        existing: asNew ? null : selected,
        order: controller.queryDefinitions.length,
        referencingWidgets: asNew
            ? 0
            : widgetsUsingQuery(controller, selected.id),
        onSave: (definition) async {
          if (asNew) {
            final id = await controller.createQueryDefinition(definition);
            if (mounted) setState(() => savedQueryId = id);
          } else {
            await controller.updateQueryDefinition(definition);
          }
        },
      ),
    );
    if (mounted) setState(() {});
  }

  List<Widget> _presentationFields(AppLocalizations l) => switch (widgetType) {
    'core.aggregate-number' => [
      FiTextInput(
        key: const Key('config-suffix'),
        controller: suffix,
        label: l.widgetUnitSuffix,
        suffixIcon: const HelpButton(HelpId.widgetUnitSuffix),
        helperText: l.widgetUnitSuffixHelper,
      ),
    ],
    'core.line-chart' => [
      FiSwitchTile(
        key: const Key('config-show-points'),
        contentPadding: EdgeInsets.zero,
        title: Text(l.widgetShowPoints),
        secondary: const HelpButton(HelpId.widgetShowPoints),
        value: showPoints,
        onChanged: (value) => setState(() => showPoints = value),
      ),
      FiTextInput(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        label: l.widgetYAxisLabel,
        suffixIcon: const HelpButton(HelpId.widgetAxisLabel),
      ),
    ],
    'core.bar-chart' => [
      FiTextInput(
        key: const Key('config-bar-width'),
        initialValue: barWidth?.toString() ?? '',
        keyboardType: TextInputType.number,
        label: l.widgetBarWidth,
        suffixIcon: const HelpButton(HelpId.widgetBarWidth),
        onChanged: (value) => setState(() => barWidth = int.tryParse(value)),
      ),
      FiTextInput(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        label: l.widgetYAxisLabel,
        suffixIcon: const HelpButton(HelpId.widgetAxisLabel),
      ),
    ],
    'core.scatter-plot' => [
      FiTextInput(
        key: const Key('config-point-radius'),
        initialValue: pointRadius?.toString() ?? '',
        keyboardType: TextInputType.number,
        label: l.widgetPointRadius,
        suffixIcon: const HelpButton(HelpId.widgetPointRadius),
        onChanged: (value) => setState(() => pointRadius = int.tryParse(value)),
      ),
      FiTextInput(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        label: l.widgetYAxisLabel,
        suffixIcon: const HelpButton(HelpId.widgetAxisLabel),
      ),
    ],
    _ => const [],
  };

  Future<void> _save() async {
    final schema = controller.schema;
    if (schema == null) return;
    setState(() {
      attempted = true;
      saveIssues = FormIssues.none;
    });
    if (!_blockers.isEmpty) return;
    try {
      final queryId = reuseQuery
          ? savedQueryId!
          : await controller.createQueryDefinition(
              query.toDefinition(
                schema,
                title.text.trim().isEmpty
                    ? context.l10n.queryDefaultName
                    : title.text.trim(),
                controller.queryDefinitions.length,
                decimalSeparator: decimalSeparatorOf(context),
              ),
            );
      // Omitting configuration for an unsupported widget leaves its opaque value untouched.
      final configuration = supported ? _configuration() : null;
      if (existing == null) {
        await controller.createWidget(
          WidgetDefinitionDto(
            id: '',
            collectionId: schema.id,
            widgetType: widgetType,
            queryId: queryId,
            title: title.text.trim(),
            configuration: configuration ?? _emptyConfiguration(),
            layout: WidgetLayoutDto(
              version: 1,
              size: size,
              hints: _emptyStructuredMap(),
            ),
            order: controller.widgetDefinitions.length,
            deleted: false,
          ),
        );
      } else {
        await controller.updateWidget(
          WidgetUpdateDto(
            id: existing!.id,
            collectionId: schema.id,
            title: title.text.trim(),
            queryId: queryId,
            configuration: configuration,
            layout: WidgetLayoutDto(
              version: existing!.layout.version,
              size: size,
              hints: existing!.layout.hints,
            ),
            order: existing!.order,
          ),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) {
        setState(
          () => saveIssues = FormIssues.from(failure).keyed(_issueInputs),
        );
      }
    }
  }

  WidgetConfigurationDto _configuration() => WidgetConfigurationDto(
    version: 1,
    body: _structuredMap(switch (widgetType) {
      'core.aggregate-number' => {
        if (suffix.text.trim().isNotEmpty) 'suffix': _text(suffix.text.trim()),
      },
      'core.line-chart' => {
        'show_points': _boolean(showPoints),
        if (axisLabel.text.trim().isNotEmpty)
          'y_axis_label': _text(axisLabel.text.trim()),
      },
      'core.bar-chart' => {
        if (barWidth != null) 'bar_width': _integer(barWidth!),
        if (axisLabel.text.trim().isNotEmpty)
          'y_axis_label': _text(axisLabel.text.trim()),
      },
      'core.scatter-plot' => {
        if (pointRadius != null) 'point_radius': _integer(pointRadius!),
        if (axisLabel.text.trim().isNotEmpty)
          'y_axis_label': _text(axisLabel.text.trim()),
      },
      _ => const {},
    }),
  );

  WidgetConfigurationDto _emptyConfiguration() =>
      WidgetConfigurationDto(version: 1, body: _emptyStructuredMap());
}

/// The localized name of a known widget type; [fallback] (the core's label) otherwise.
String widgetTypeName(AppLocalizations l, String widgetType, String fallback) =>
    switch (widgetType) {
      'core.aggregate-number' => l.widgetTypeAggregateNumber,
      'core.line-chart' => l.widgetTypeLineChart,
      'core.bar-chart' => l.widgetTypeBarChart,
      'core.scatter-plot' => l.widgetTypeScatterPlot,
      _ => fallback,
    };

IconData _typeIcon(String widgetType) => switch (widgetType) {
  'core.aggregate-number' => FiIcons.number,
  'core.line-chart' => FiIcons.lineChart,
  'core.bar-chart' => FiIcons.barChart,
  'core.scatter-plot' => FiIcons.scatterChart,
  _ => FiIcons.widget,
};

StructuredValueDto _emptyStructuredMap() => _structuredMap(const {});

StructuredValueDto _structuredMap(Map<String, StructuredValueDto> entries) =>
    StructuredValueDto(
      kind: StructuredValueKindDto.map,
      items: const [],
      entries: [
        for (final entry in entries.entries)
          StructuredEntryDto(key: entry.key, value: entry.value),
      ],
    );

StructuredValueDto _text(String value) => StructuredValueDto(
  kind: StructuredValueKindDto.text,
  textValue: value,
  items: const [],
  entries: const [],
);

StructuredValueDto _boolean(bool value) => StructuredValueDto(
  kind: StructuredValueKindDto.boolean,
  booleanValue: value,
  items: const [],
  entries: const [],
);

StructuredValueDto _integer(int value) => StructuredValueDto(
  kind: StructuredValueKindDto.integer,
  integerValue: value,
  items: const [],
  entries: const [],
);
