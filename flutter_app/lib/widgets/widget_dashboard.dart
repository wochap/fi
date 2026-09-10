import 'dart:async';

import 'package:fi/controllers.dart';
import 'package:fi/exact_format.dart';
import 'package:fi/src/rust/api/models.dart';
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
  late String widgetType;
  late WidgetSizeDto size;
  final title = TextEditingController();

  // Query source: reuse a saved definition or build a new typed one.
  late bool reuseQuery;
  String? savedQueryId;
  AggregationKindDto aggregation = AggregationKindDto.count;
  String? operandFieldId;
  String? categoryFieldId;
  String? seriesXFieldId;
  String? seriesYFieldId;
  BucketPeriodDto? bucket;
  int outputScale = 2;
  RoundingPolicyDto rounding = RoundingPolicyDto.halfEven;

  // Optional filter.
  String? filterFieldId;
  ComparisonOperatorDto filterOperator = ComparisonOperatorDto.equal;
  final filterValue = TextEditingController();

  // Presentation, kept separate from the query.
  final suffix = TextEditingController();
  final axisLabel = TextEditingController();
  bool showPoints = false;
  int? barWidth;
  int? pointRadius;

  String? error;

  @override
  void initState() {
    super.initState();
    widgetType =
        existing?.widgetType ??
        (controller.widgetDescriptors.isEmpty
            ? 'core.aggregate-number'
            : controller.widgetDescriptors.first.widgetType);
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
    filterValue.dispose();
    suffix.dispose();
    axisLabel.dispose();
    super.dispose();
  }

  List<FieldDefinitionDto> get _fields => [
    ...(controller.schema?.fields ?? const []).where((field) => !field.deleted),
  ];

  List<FieldDefinitionDto> _fieldsWhere(bool Function(FieldTypeKindDto) test) =>
      _fields.where((field) => test(field.fieldType.kind)).toList();

  List<FieldDefinitionDto> get _numericFields => _fieldsWhere(
    (kind) =>
        kind == FieldTypeKindDto.integer ||
        kind == FieldTypeKindDto.fixedDecimal ||
        kind == FieldTypeKindDto.duration,
  );

  List<FieldDefinitionDto> get _timeFields => _fieldsWhere(
    (kind) =>
        kind == FieldTypeKindDto.date || kind == FieldTypeKindDto.dateTime,
  );

  List<FieldDefinitionDto> get _categoryFields => _fieldsWhere(
    (kind) =>
        kind == FieldTypeKindDto.enum_ ||
        kind == FieldTypeKindDto.text ||
        kind == FieldTypeKindDto.boolean ||
        kind == FieldTypeKindDto.date ||
        kind == FieldTypeKindDto.dateTime,
  );

  List<FieldDefinitionDto> get _plotFields => _fieldsWhere(
    (kind) =>
        kind == FieldTypeKindDto.integer ||
        kind == FieldTypeKindDto.fixedDecimal ||
        kind == FieldTypeKindDto.duration ||
        kind == FieldTypeKindDto.date ||
        kind == FieldTypeKindDto.dateTime,
  );

  bool get _isChart => widgetType != 'core.aggregate-number';
  bool get _isScatter => widgetType == 'core.scatter-plot';
  bool get _needsAggregation =>
      widgetType == 'core.aggregate-number' ||
      widgetType == 'core.bar-chart' ||
      (widgetType == 'core.line-chart' && bucket != null);
  bool get _needsSeries =>
      _isChart &&
      !(_isScatter ? false : bucket != null) &&
      (widgetType == 'core.scatter-plot' || widgetType == 'core.line-chart');

  /// What still has to be chosen before the form can be submitted.
  String? get _blocker {
    if (title.text.trim().isEmpty) return 'Give the widget a title.';
    if (reuseQuery) {
      return savedQueryId == null ? 'Choose a saved query.' : null;
    }
    if (_needsAggregation) {
      if (aggregation != AggregationKindDto.count && operandFieldId == null) {
        return 'Choose the field to aggregate.';
      }
      if (widgetType != 'core.aggregate-number' && categoryFieldId == null) {
        return 'Choose the category or period field.';
      }
    }
    if (_needsSeries && (seriesXFieldId == null || seriesYFieldId == null)) {
      return 'Choose both axes.';
    }
    if (widgetType == 'core.bar-chart' &&
        bucket == null &&
        categoryFieldId == null) {
      return 'Choose the category field.';
    }
    if (filterFieldId != null && filterValue.text.trim().isEmpty) {
      return 'Enter the filter value or clear the filter.';
    }
    return null;
  }

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
                  decoration: const InputDecoration(labelText: 'Widget type'),
                  items: [
                    for (final descriptor in controller.widgetDescriptors)
                      DropdownMenuItem(
                        value: descriptor.widgetType,
                        child: Text(descriptor.label),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    widgetType = value!;
                    if (value == 'core.scatter-plot') bucket = null;
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
                value: reuseQuery,
                onChanged: (value) => setState(() => reuseQuery = value),
              ),
              if (reuseQuery)
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
                )
              else if (schema != null)
                ..._queryBuilder(schema),
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

  List<Widget> _queryBuilder(CollectionSchemaDto schema) => [
    Text('Query', style: Theme.of(context).textTheme.titleSmall),
    if (_needsAggregation) ...[
      DropdownButtonFormField<AggregationKindDto>(
        key: const Key('aggregation'),
        initialValue: aggregation,
        decoration: const InputDecoration(labelText: 'Aggregation'),
        items: const [
          DropdownMenuItem(
            value: AggregationKindDto.count,
            child: Text('Count'),
          ),
          DropdownMenuItem(value: AggregationKindDto.sum, child: Text('Sum')),
          DropdownMenuItem(
            value: AggregationKindDto.average,
            child: Text('Average'),
          ),
          DropdownMenuItem(value: AggregationKindDto.min, child: Text('Min')),
          DropdownMenuItem(value: AggregationKindDto.max, child: Text('Max')),
        ],
        onChanged: (value) => setState(() {
          aggregation = value ?? aggregation;
          if (aggregation == AggregationKindDto.count) operandFieldId = null;
        }),
      ),
      if (aggregation != AggregationKindDto.count)
        _fieldDropdown(
          // Keyed by the aggregation so switching back to Count clears the displayed operand
          // instead of leaving a stale choice the form state no longer holds.
          key: ValueKey('operand-field-$aggregation'),
          label: 'Field to aggregate',
          fields: _numericFields,
          value: operandFieldId,
          onChanged: (value) => setState(() => operandFieldId = value),
        ),
      // An exact numeric policy is mandatory for Average so no implicit rounding is invented.
      if (aggregation == AggregationKindDto.average) ...[
        TextFormField(
          key: const Key('output-scale'),
          initialValue: '$outputScale',
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Output scale'),
          onChanged: (value) =>
              setState(() => outputScale = int.tryParse(value) ?? outputScale),
        ),
        DropdownButtonFormField<RoundingPolicyDto>(
          key: const Key('rounding'),
          initialValue: rounding,
          decoration: const InputDecoration(labelText: 'Rounding policy'),
          items: const [
            DropdownMenuItem(
              value: RoundingPolicyDto.halfEven,
              child: Text('Half to even'),
            ),
            DropdownMenuItem(
              value: RoundingPolicyDto.rejectInexact,
              child: Text('Reject inexact'),
            ),
          ],
          onChanged: (value) => setState(() => rounding = value ?? rounding),
        ),
      ],
    ],
    if (_isChart && !_isScatter) ...[
      _fieldDropdown(
        // Keyed by the bucket choice: switching buckets swaps the allowed field kinds, so the
        // previous selection must not linger on screen.
        key: ValueKey('category-field-$bucket'),
        label: bucket == null ? 'Category field' : 'Period field',
        fields: bucket == null ? _categoryFields : _timeFields,
        value: categoryFieldId,
        onChanged: (value) => setState(() => categoryFieldId = value),
      ),
      if (!_isScatter)
        DropdownButtonFormField<BucketPeriodDto?>(
          key: const Key('bucket-period'),
          initialValue: bucket,
          decoration: const InputDecoration(labelText: 'Time bucket'),
          items: const [
            DropdownMenuItem(value: null, child: Text('None')),
            DropdownMenuItem(value: BucketPeriodDto.day, child: Text('Day')),
            DropdownMenuItem(value: BucketPeriodDto.week, child: Text('Week')),
            DropdownMenuItem(
              value: BucketPeriodDto.month,
              child: Text('Month'),
            ),
            DropdownMenuItem(value: BucketPeriodDto.year, child: Text('Year')),
          ],
          onChanged: widgetType == 'core.scatter-plot'
              ? null
              : (value) => setState(() {
                  bucket = value;
                  if (value != null) categoryFieldId = null;
                }),
        ),
    ],
    if (_needsSeries) ...[
      _fieldDropdown(
        key: const Key('series-x'),
        label: 'X axis',
        fields: _plotFields,
        value: seriesXFieldId,
        onChanged: (value) => setState(() => seriesXFieldId = value),
      ),
      _fieldDropdown(
        key: const Key('series-y'),
        label: 'Y axis',
        fields: _numericFields,
        value: seriesYFieldId,
        onChanged: (value) => setState(() => seriesYFieldId = value),
      ),
    ],
    const Divider(height: 20),
    _fieldDropdown(
      key: const Key('filter-field'),
      label: 'Filter field (optional)',
      fields: _fields,
      value: filterFieldId,
      allowClear: true,
      onChanged: (value) => setState(() => filterFieldId = value),
    ),
    if (filterFieldId != null) ...[
      DropdownButtonFormField<ComparisonOperatorDto>(
        key: const Key('filter-operator'),
        initialValue: filterOperator,
        decoration: const InputDecoration(labelText: 'Filter operator'),
        items: const [
          DropdownMenuItem(
            value: ComparisonOperatorDto.equal,
            child: Text('equals'),
          ),
          DropdownMenuItem(
            value: ComparisonOperatorDto.notEqual,
            child: Text('is not'),
          ),
          DropdownMenuItem(
            value: ComparisonOperatorDto.greaterThan,
            child: Text('greater than'),
          ),
          DropdownMenuItem(
            value: ComparisonOperatorDto.greaterThanOrEqual,
            child: Text('at least'),
          ),
          DropdownMenuItem(
            value: ComparisonOperatorDto.lessThan,
            child: Text('less than'),
          ),
          DropdownMenuItem(
            value: ComparisonOperatorDto.lessThanOrEqual,
            child: Text('at most'),
          ),
        ],
        onChanged: (value) =>
            setState(() => filterOperator = value ?? filterOperator),
      ),
      TextField(
        key: const Key('filter-value'),
        controller: filterValue,
        decoration: const InputDecoration(labelText: 'Filter value'),
        onChanged: (_) => setState(() {}),
      ),
    ],
  ];

  List<Widget> _presentationFields() => switch (widgetType) {
    'core.aggregate-number' => [
      TextField(
        key: const Key('config-suffix'),
        controller: suffix,
        decoration: const InputDecoration(
          labelText: 'Unit suffix (optional)',
          helperText: 'Shown after the exact value, for example "EUR".',
        ),
      ),
    ],
    'core.line-chart' => [
      SwitchListTile(
        key: const Key('config-show-points'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Show points'),
        value: showPoints,
        onChanged: (value) => setState(() => showPoints = value),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: const InputDecoration(labelText: 'Y axis label (optional)'),
      ),
    ],
    'core.bar-chart' => [
      TextFormField(
        key: const Key('config-bar-width'),
        initialValue: barWidth?.toString() ?? '',
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Bar width (optional)'),
        onChanged: (value) => setState(() => barWidth = int.tryParse(value)),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: const InputDecoration(labelText: 'Y axis label (optional)'),
      ),
    ],
    'core.scatter-plot' => [
      TextFormField(
        key: const Key('config-point-radius'),
        initialValue: pointRadius?.toString() ?? '',
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Point radius (optional)'),
        onChanged: (value) => setState(() => pointRadius = int.tryParse(value)),
      ),
      TextField(
        key: const Key('config-axis-label'),
        controller: axisLabel,
        decoration: const InputDecoration(labelText: 'Y axis label (optional)'),
      ),
    ],
    _ => const [],
  };

  Widget _fieldDropdown({
    required Key key,
    required String label,
    required List<FieldDefinitionDto> fields,
    required String? value,
    required ValueChanged<String?> onChanged,
    bool allowClear = false,
  }) {
    final current = fields.any((field) => field.id == value) ? value : null;
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: current,
      decoration: InputDecoration(labelText: label),
      items: [
        if (allowClear)
          const DropdownMenuItem<String>(value: null, child: Text('None')),
        for (final field in fields)
          DropdownMenuItem(value: field.id, child: Text(field.name)),
      ],
      onChanged: onChanged,
    );
  }

  Future<void> _save() async {
    final schema = controller.schema;
    if (schema == null) return;
    try {
      final queryId = reuseQuery
          ? savedQueryId!
          : await controller.createQueryDefinition(_queryDefinition(schema));
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

  QueryDefinitionDto _queryDefinition(CollectionSchemaDto schema) =>
      QueryDefinitionDto(
        id: '',
        collectionId: schema.id,
        name: title.text.trim().isEmpty ? 'Widget query' : title.text.trim(),
        queryVersion: 1,
        query: CollectionQueryDto(
          collectionId: schema.id,
          filter: _filter(),
          grouping: bucket == null || categoryFieldId == null
              ? null
              : GroupingDto(
                  expression: _fieldExpression(categoryFieldId!),
                  period: bucket!,
                ),
          shape: _shape(),
          sorting: _sorting(),
          calendar: const CalendarPolicyDto(
            timezone: 'UTC',
            weekStart: WeekStartDto.monday,
          ),
        ),
        order: controller.queryDefinitions.length,
        deleted: false,
      );

  QueryShapeDto _shape() => switch (widgetType) {
    'core.scatter-plot' => QueryShapeDto(
      kind: QueryShapeKindDto.series,
      x: _fieldExpression(seriesXFieldId!),
      y: _fieldExpression(seriesYFieldId!),
      fields: const [],
    ),
    'core.line-chart' =>
      bucket != null
          ? QueryShapeDto(
              kind: QueryShapeKindDto.categorySeries,
              category: _fieldExpression(categoryFieldId!),
              aggregation: _aggregation(),
              fields: const [],
            )
          : QueryShapeDto(
              kind: QueryShapeKindDto.series,
              x: _fieldExpression(seriesXFieldId!),
              y: _fieldExpression(seriesYFieldId!),
              fields: const [],
            ),
    'core.bar-chart' => QueryShapeDto(
      kind: QueryShapeKindDto.categorySeries,
      category: _fieldExpression(categoryFieldId!),
      aggregation: _aggregation(),
      fields: const [],
    ),
    _ => QueryShapeDto(
      kind: QueryShapeKindDto.scalar,
      aggregation: _aggregation(),
      fields: const [],
    ),
  };

  List<SortClauseDto> _sorting() {
    // A Series is plotted exactly in the order the query returns, so chronological charts need
    // an explicit ascending sort on the X expression.
    final x = switch (widgetType) {
      'core.scatter-plot' => seriesXFieldId,
      'core.line-chart' => bucket == null ? seriesXFieldId : null,
      _ => null,
    };
    if (x == null) return const [];
    return [
      SortClauseDto(
        expression: _fieldExpression(x),
        direction: SortDirectionDto.ascending,
        nullOrder: NullOrderDto.last,
      ),
    ];
  }

  AggregationDto _aggregation() => switch (aggregation) {
    AggregationKindDto.count => const AggregationDto(
      kind: AggregationKindDto.count,
    ),
    AggregationKindDto.sum => AggregationDto(
      kind: AggregationKindDto.sum,
      expression: _fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.min => AggregationDto(
      kind: AggregationKindDto.min,
      expression: _fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.max => AggregationDto(
      kind: AggregationKindDto.max,
      expression: _fieldExpression(operandFieldId!),
    ),
    AggregationKindDto.average => AggregationDto(
      kind: AggregationKindDto.average,
      expression: _fieldExpression(operandFieldId!),
      outputScale: outputScale,
      rounding: rounding,
    ),
  };

  ExpressionDto? _filter() {
    final fieldId = filterFieldId;
    if (fieldId == null) return null;
    final field = _fields.firstWhere((item) => item.id == fieldId);
    final constant = _constant(field);
    if (constant == null) return null;
    return ExpressionDto(
      root: 2,
      nodes: [
        ExpressionNodeDto(
          kind: ExpressionKindDto.field,
          field: FieldReferenceDto(
            kind: FieldReferenceKindDto.source,
            id: fieldId,
          ),
        ),
        ExpressionNodeDto(kind: ExpressionKindDto.constant, value: constant),
        ExpressionNodeDto(
          kind: ExpressionKindDto.compare,
          comparisonOperator: filterOperator,
          left: 0,
          right: 1,
        ),
      ],
    );
  }

  TypedValueDto? _constant(FieldDefinitionDto field) {
    final raw = filterValue.text.trim();
    final kind = switch (field.fieldType.kind) {
      FieldTypeKindDto.text => ValueTypeKindDto.text,
      FieldTypeKindDto.integer => ValueTypeKindDto.integer,
      FieldTypeKindDto.fixedDecimal => ValueTypeKindDto.fixedDecimal,
      FieldTypeKindDto.boolean => ValueTypeKindDto.boolean,
      FieldTypeKindDto.date => ValueTypeKindDto.date,
      FieldTypeKindDto.dateTime => ValueTypeKindDto.dateTime,
      FieldTypeKindDto.duration => ValueTypeKindDto.duration,
      FieldTypeKindDto.enum_ => ValueTypeKindDto.enum_,
    };
    final valueType = ValueTypeDto(kind: kind, scale: field.fieldType.scale);
    return switch (kind) {
      ValueTypeKindDto.text || ValueTypeKindDto.enum_ => TypedValueDto(
        valueType: valueType,
        textValue: raw,
      ),
      ValueTypeKindDto.boolean => TypedValueDto(
        valueType: valueType,
        booleanValue: switch (raw.toLowerCase()) {
          'true' => true,
          'false' => false,
          _ => null,
        },
      ),
      ValueTypeKindDto.fixedDecimal => TypedValueDto(
        valueType: valueType,
        integerValue: parseScaled(raw, field.fieldType.scale ?? 0),
      ),
      _ => TypedValueDto(valueType: valueType, integerValue: int.tryParse(raw)),
    };
  }
}

ExpressionDto _fieldExpression(String fieldId) => ExpressionDto(
  root: 0,
  nodes: [
    ExpressionNodeDto(
      kind: ExpressionKindDto.field,
      field: FieldReferenceDto(kind: FieldReferenceKindDto.source, id: fieldId),
    ),
  ],
);

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
