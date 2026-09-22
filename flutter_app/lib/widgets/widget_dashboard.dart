import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Dashboard', style: theme.textTheme.titleSmall),
              ),
              if (controller.widgetErrorMessage case final message?)
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              TextButton.icon(
                key: const Key('reorder-widgets'),
                onPressed: definitions.length < 2
                    ? null
                    : () => unawaited(showWidgetReorder(context, controller)),
                icon: const Icon(Icons.swap_vert),
                label: const Text('Reorder'),
              ),
              FilledButton.tonalIcon(
                key: const Key('add-widget'),
                onPressed: () =>
                    unawaited(showWidgetEditor(context, controller)),
                icon: const Icon(Icons.add_chart),
                label: const Text('Add widget'),
              ),
            ],
          ),
          if (definitions.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'No widgets yet. Add one to summarize this collection.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                // One breakpoint keeps narrow Android and wide Linux windows usable with the same
                // deterministic order and the same structured sizing hints.
                final wide = constraints.maxWidth >= 720;
                final labels = enumLabelsFor(controller.schema);
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final definition in definitions)
                      SizedBox(
                        key: ValueKey('widget-${definition.id}'),
                        width: _tileWidth(
                          definition.layout.size,
                          constraints.maxWidth,
                          wide,
                        ),
                        height: _tileHeight(definition.layout.size),
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => unawaited(
                              showWidgetEditor(context, controller, definition),
                            ),
                            child: _registry.build(
                              WidgetRenderContext(
                                definition: definition,
                                evaluation: controller.evaluationFor(
                                  definition.id,
                                ),
                                enumLabels: labels,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

double _tileWidth(WidgetSizeDto size, double available, bool wide) =>
    switch (size) {
      WidgetSizeDto.small => wide ? available / 4 - 9 : available / 2 - 6,
      WidgetSizeDto.medium => wide ? available / 2 - 6 : available,
      WidgetSizeDto.large => wide ? available * 3 / 4 - 3 : available,
      WidgetSizeDto.full => available,
    };

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
      title: const Text('Widget order'),
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
          child: const Text('Done'),
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
  await showDialog<void>(
    context: context,
    builder: (dialog) =>
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

  String? error;

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

  /// What still has to be chosen before the form can be submitted.
  String? get _blocker {
    if (title.text.trim().isEmpty) return 'Give the widget a title.';
    if (reuseQuery) {
      return savedQueryId == null ? 'Choose a saved query.' : null;
    }
    return query.blocker;
  }

  QueryDefinitionDto? get _selectedQuery => controller.queryDefinitions
      .where((item) => item.id == savedQueryId)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final schema = controller.schema;
    return AlertDialog(
      title: Text(existing == null ? 'Add widget' : 'Edit widget'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (supported) ...[
                DropdownButtonFormField<String>(
                  key: const Key('widget-type'),
                  initialValue: widgetType,
                  decoration: labelWithHelp('Widget type', HelpId.widgetType),
                  items: [
                    for (final descriptor in controller.widgetDescriptors)
                      DropdownMenuItem(
                        value: descriptor.widgetType,
                        child: Text(descriptor.label),
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
                Text('Widget type: ${existing?.widgetType}'),
                Text(
                  'This build cannot render this widget. Title, query, size, and order stay '
                  'editable and its configuration is preserved untouched.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              TextField(
                key: const Key('widget-title'),
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                key: const Key('reuse-query'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use a saved query'),
                secondary: const HelpButton(HelpId.widgetUseSavedQuery),
                value: reuseQuery,
                onChanged: (value) => setState(() => reuseQuery = value),
              ),
              if (reuseQuery) ...[
                DropdownButtonFormField<String>(
                  key: const Key('saved-query'),
                  initialValue:
                      controller.queryDefinitions.any(
                        (item) => item.id == savedQueryId,
                      )
                      ? savedQueryId
                      : null,
                  decoration: const InputDecoration(labelText: 'Saved query'),
                  items: [
                    for (final query in controller.queryDefinitions)
                      DropdownMenuItem(
                        value: query.id,
                        child: Text(query.name),
                      ),
                  ],
                  onChanged: (value) => setState(() => savedQueryId = value),
                ),
                if (_selectedQuery case final selected? when schema != null)
                  ..._savedQueryActions(schema, selected),
              ] else if (schema != null)
                QueryBuilder(
                  schema: schema,
                  state: query,
                  onChanged: (next) => setState(() => query = next),
                ),
              const Divider(height: 28),
              Text(
                'Presentation',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (supported)
                ..._presentationFields()
              else
                Text(
                  'Configuration version ${existing?.configuration.version} is preserved as is.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const Divider(height: 28),
              DropdownButtonFormField<WidgetSizeDto>(
                key: const Key('widget-size'),
                initialValue: size,
                decoration: const InputDecoration(labelText: 'Size'),
                items: const [
                  DropdownMenuItem(
                    value: WidgetSizeDto.small,
                    child: Text('Small'),
                  ),
                  DropdownMenuItem(
                    value: WidgetSizeDto.medium,
                    child: Text('Medium'),
                  ),
                  DropdownMenuItem(
                    value: WidgetSizeDto.large,
                    child: Text('Large'),
                  ),
                  DropdownMenuItem(
                    value: WidgetSizeDto.full,
                    child: Text('Full'),
                  ),
                ],
                onChanged: (value) => setState(() => size = value ?? size),
              ),
              if (error case final message?)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    message,
                    key: const Key('widget-editor-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            key: const Key('remove-widget'),
            onPressed: () async {
              // Capture the navigator before the await so no BuildContext crosses the gap.
              final navigator = Navigator.of(context);
              await controller.removeWidget(existing!.id);
              navigator.pop();
            },
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-widget'),
          onPressed: _blocker == null ? _save : null,
          child: const Text('Save'),
        ),
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
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          describeQuery(selected, schema),
          key: const Key('saved-query-summary'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      Text(
        switch (used) {
          0 => 'Used by no widgets',
          1 => 'Used by 1 widget',
          _ => 'Used by $used widgets',
        },
        key: const Key('saved-query-usage'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Row(
        children: [
          TextButton(
            key: const Key('edit-saved-query'),
            onPressed: () =>
                unawaited(_editSavedQuery(schema, selected, asNew: false)),
            child: const Text('Edit this query'),
          ),
          TextButton(
            key: const Key('save-query-as-new'),
            onPressed: () =>
                unawaited(_editSavedQuery(schema, selected, asNew: true)),
            child: const Text('Save as new'),
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
        heading: asNew ? 'Save as new query' : 'Edit query',
        initialName: asNew ? '${selected.name} copy' : selected.name,
        initialState: QueryBuilderState.fromDefinition(selected, schema),
        // Saving as new starts from the same contents but must not inherit the id.
        existing: asNew ? null : selected,
        order: controller.queryDefinitions.length,
        referencingWidgets: asNew ? 0 : widgetsUsingQuery(controller, selected.id),
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

  List<Widget> _presentationFields() => switch (widgetType) {
    'core.aggregate-number' => [
      TextField(
        key: const Key('config-suffix'),
        controller: suffix,
        decoration: labelWithHelp(
          'Unit suffix (optional)',
          HelpId.widgetUnitSuffix,
          helperText: 'Shown after the exact value, for example "EUR".',
        ),
      ),
    ],
    'core.line-chart' => [
      SwitchListTile(
        key: const Key('config-show-points'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Show points'),
        secondary: const HelpButton(HelpId.widgetShowPoints),
        value: showPoints,
        onChanged: (value) => setState(() => showPoints = value),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: labelWithHelp(
          'Y axis label (optional)',
          HelpId.widgetAxisLabel,
        ),
      ),
    ],
    'core.bar-chart' => [
      TextFormField(
        key: const Key('config-bar-width'),
        initialValue: barWidth?.toString() ?? '',
        keyboardType: TextInputType.number,
        decoration: labelWithHelp(
          'Bar width (optional)',
          HelpId.widgetBarWidth,
        ),
        onChanged: (value) => setState(() => barWidth = int.tryParse(value)),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: labelWithHelp(
          'Y axis label (optional)',
          HelpId.widgetAxisLabel,
        ),
      ),
    ],
    'core.scatter-plot' => [
      TextFormField(
        key: const Key('config-point-radius'),
        initialValue: pointRadius?.toString() ?? '',
        keyboardType: TextInputType.number,
        decoration: labelWithHelp(
          'Point radius (optional)',
          HelpId.widgetPointRadius,
        ),
        onChanged: (value) => setState(() => pointRadius = int.tryParse(value)),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: labelWithHelp(
          'Y axis label (optional)',
          HelpId.widgetAxisLabel,
        ),
      ),
    ],
    _ => const [],
  };

  Future<void> _save() async {
    final schema = controller.schema;
    if (schema == null) return;
    try {
      final queryId = reuseQuery
          ? savedQueryId!
          : await controller.createQueryDefinition(
              query.toDefinition(
                schema,
                title.text.trim().isEmpty ? 'Widget query' : title.text.trim(),
                controller.queryDefinitions.length,
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
      if (mounted) setState(() => error = bridgeMessage(failure));
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
