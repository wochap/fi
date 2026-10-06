import 'dart:async';

import 'package:fi/l10n/error_text.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/controllers.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/confirm_dialog.dart';
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
final class CollectionDashboard extends StatefulWidget {
  const CollectionDashboard({super.key, required this.controller});

  final CollectionsController controller;

  static const _registry = WidgetRendererRegistry();

  @override
  State<CollectionDashboard> createState() => _CollectionDashboardState();
}

final class _CollectionDashboardState extends State<CollectionDashboard> {
  CollectionsController get controller => widget.controller;

  /// Reorder mode replaces each tile's menu with move and remove controls, in place.
  bool reordering = false;

  @override
  Widget build(BuildContext context) {
    final definitions = controller.widgetDefinitions;
    final schema = controller.schema;
    final l = context.l10n;
    // Leaving reorder mode once fewer than two widgets remain keeps the header honest.
    final inReorder = reordering && definitions.length >= 2;
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
            if (inReorder)
              FilledButton(
                key: const Key('reorder-done'),
                onPressed: () => setState(() => reordering = false),
                child: Text(l.commonDone),
              )
            else ...[
              Flexible(
                child: TextButton.icon(
                  key: const Key('reorder-widgets'),
                  style: TextButton.styleFrom(
                    foregroundColor: Nocturne.muted(.6),
                  ),
                  onPressed: definitions.length < 2 ? null : _startReorder,
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
                  for (final (index, definition) in definitions.indexed)
                    SizedBox(
                      key: ValueKey('widget-${definition.id}'),
                      width: _tileWidth(
                        definition.layout.size,
                        available,
                        wide,
                      ),
                      height: _tileHeight(definition.layout.size),
                      child: inReorder
                          ? _ReorderTile(
                              definitions: definitions,
                              index: index,
                              wide: wide,
                              onMove: _move,
                              onRemove: () => unawaited(
                                confirmRemoveWidget(
                                  context,
                                  controller,
                                  definition,
                                ),
                              ),
                              child: _tile(definition, labels, schema),
                            )
                          : WidgetTileActions(
                              onEdit: () => _edit(definition),
                              onReorder: definitions.length < 2
                                  ? null
                                  : _startReorder,
                              onRemove: () => unawaited(
                                confirmRemoveWidget(
                                  context,
                                  controller,
                                  definition,
                                ),
                              ),
                              child: _tile(definition, labels, schema),
                            ),
                    ),
                  if (!inReorder)
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

  void _startReorder() => setState(() => reordering = true);

  void _edit(WidgetDefinitionDto definition) =>
      unawaited(showWidgetEditor(context, controller, definition));

  /// Moves the widget at [from] to [to] and submits the whole new order.
  void _move(int from, int to) {
    final ids = controller.widgetDefinitions.map((item) => item.id).toList();
    if (from == to || to < 0 || to >= ids.length) return;
    ids.insert(to, ids.removeAt(from));
    unawaited(controller.reorderWidgets(ids));
  }

  Widget _tile(
    WidgetDefinitionDto definition,
    Map<String, String> labels,
    CollectionSchemaDto? schema,
  ) => NocturneCard(
    padding: EdgeInsets.zero,
    // The glow marks a headline number; charts keep a flat ground.
    gradient: definition.widgetType == 'core.aggregate-number'
        ? nocturneGlow()
        : null,
    // Tile taps are inert while reordering.
    onTap: reordering ? null : () => _edit(definition),
    child: CollectionDashboard._registry.build(
      WidgetRenderContext(
        definition: definition,
        evaluation: controller.evaluationFor(definition.id),
        enumLabels: labels,
        summary: _summary(context.l10n, definition, schema),
        onEdit: () => _edit(definition),
      ),
    ),
  );

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

/// One tile in reorder mode: the tile itself, inert, under a bar with a drag handle, Move up,
/// Move down and Remove widget. Dropping another tile here moves it to this position.
final class _ReorderTile extends StatelessWidget {
  const _ReorderTile({
    required this.definitions,
    required this.index,
    required this.wide,
    required this.onMove,
    required this.onRemove,
    required this.child,
  });

  final List<WidgetDefinitionDto> definitions;
  final int index;
  final bool wide;
  final void Function(int from, int to) onMove;
  final VoidCallback onRemove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final definition = definitions[index];
    final handle = Icon(
      FiIcons.dragHandle,
      size: 18,
      color: Nocturne.muted(.7),
    );
    final feedback = Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: .8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Nocturne.surface,
            borderRadius: BorderRadius.circular(Nocturne.radius),
            border: Border.all(color: Nocturne.accent),
          ),
          child: Text(definition.title),
        ),
      ),
    );
    final box = wide ? 36.0 : Nocturne.touchTarget;
    final handleBox = SizedBox(
      width: box,
      height: box,
      child: Tooltip(
        message: l.widgetDragToReorder,
        child: Center(child: handle),
      ),
    );
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onMove(details.data, index),
      builder: (context, candidates, _) => Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(child: Opacity(opacity: .55, child: child)),
          ),
          if (candidates.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Nocturne.radius),
                    border: Border.all(color: Nocturne.accent, width: 2),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 6,
            right: 6,
            child: DecoratedBox(
              key: Key('reorder-controls-${definition.id}'),
              decoration: BoxDecoration(
                color: Nocturne.surface,
                borderRadius: BorderRadius.circular(Nocturne.radiusSm),
                border: Border.all(color: Nocturne.muted(.12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A mouse drags straight away; touch drags after a long press so scrolling
                  // the dashboard still works.
                  if (wide)
                    Draggable<int>(
                      key: const Key('widget-drag-handle'),
                      data: index,
                      feedback: feedback,
                      child: handleBox,
                    )
                  else
                    LongPressDraggable<int>(
                      key: const Key('widget-drag-handle'),
                      data: index,
                      feedback: feedback,
                      child: handleBox,
                    ),
                  FiIconButton(
                    key: const Key('widget-move-up'),
                    icon: FiIcons.collapse,
                    tooltip: l.widgetMoveUp,
                    onPressed: index == 0
                        ? null
                        : () => onMove(index, index - 1),
                  ),
                  FiIconButton(
                    key: const Key('widget-move-down'),
                    icon: FiIcons.expand,
                    tooltip: l.widgetMoveDown,
                    onPressed: index == definitions.length - 1
                        ? null
                        : () => onMove(index, index + 1),
                  ),
                  FiIconButton(
                    key: const Key('widget-reorder-remove'),
                    icon: FiIcons.delete,
                    tooltip: l.widgetRemoveTooltip,
                    onPressed: onRemove,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks before removing [definition] (destructive Remove left, Keep widget right) and removes it
/// only on Remove. Returns whether it was removed.
Future<bool> confirmRemoveWidget(
  BuildContext context,
  CollectionsController controller,
  WidgetDefinitionDto definition,
) async {
  final l = context.l10n;
  final confirmed = await showConfirmDialog(
    context,
    title: l.widgetRemoveConfirmTitle(
      definition.title.isEmpty ? l.widgetUntitledWidget : definition.title,
    ),
    body: l.widgetRemoveConfirmBody,
    destructive: l.widgetRemove,
    safe: l.widgetKeep,
    destructiveKey: const Key('confirm-remove-widget'),
    safeKey: const Key('keep-widget'),
  );
  if (!confirmed) return false;
  await controller.removeWidget(definition.id);
  return true;
}

const double _gap = 12;

/// Four columns on a wide screen: small, medium, large and full tiles span one, two, three and
/// four. A phone stacks every tile full width.
double _tileWidth(WidgetSizeDto size, double available, bool wide) {
  if (!wide) return available;
  final column = (available - 3 * _gap) / 4;
  final span = switch (size) {
    WidgetSizeDto.small => 1,
    WidgetSizeDto.medium => 2,
    WidgetSizeDto.large => 3,
    WidgetSizeDto.full => 4,
  };
  return span * column + (span - 1) * _gap;
}

double _tileHeight(WidgetSizeDto size) => switch (size) {
  WidgetSizeDto.small => 118,
  WidgetSizeDto.medium => 220,
  WidgetSizeDto.large => 290,
  WidgetSizeDto.full => 330,
};

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
    final phone = FormSurfaceScope.modeOf(context) == FormSurfaceMode.sheet;
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: [
        if (supported) ...[
          _typePicker(l),
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
        SectionLabel(l.widgetData),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<bool>(
                key: const Key('query-source'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(
                      l.widgetDefineHere,
                      key: const Key('query-source-define'),
                    ),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(
                      l.widgetUseSavedQuery,
                      key: const Key('query-source-saved'),
                    ),
                  ),
                ],
                selected: {reuseQuery},
                onSelectionChanged: (value) => setState(() {
                  _edited('query');
                  reuseQuery = value.single;
                }),
              ),
            ),
            const HelpButton(HelpId.widgetUseSavedQuery),
          ],
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
            filterStyle: QueryFilterStyle.chip,
            onChanged: (next) => setState(() => query = next),
          ),
        const SizedBox(height: 4),
        SectionLabel(l.widgetPresentation),
        if (supported)
          ..._presentationFields(l)
        else
          Text(
            l.widgetConfigVersionPreserved(
              '${existing?.configuration.version}',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        Text(
          l.widgetSize,
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
        ),
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
        // A phone shows the preview in the form flow, after Size (mock widget-editor).
        if (phone) _preview(schema),
      ],
    );
    // Wide screens get the form beside a live preview of the tile.
    return FormSurface(
      title: existing == null ? l.widgetAdd : l.widgetEdit,
      width: 520,
      body: form,
      aside: phone ? null : _preview(schema),
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
              if (await confirmRemoveWidget(context, controller, existing!)) {
                navigator.pop();
              }
            },
          ),
      ],
      primaryKey: const Key('save-widget'),
      primaryLabel: existing == null ? l.widgetAdd : l.commonSave,
      // Save stays enabled; pressing it shows what is missing under the input it belongs to.
      onPrimary: _save,
    );
  }

  /// What the tile will look like: the saved evaluation for an existing widget, the title and
  /// query in words for a new one, and what the chosen size spans.
  Widget _preview(CollectionSchemaDto? schema) {
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
        const SizedBox(height: 10),
        SizedBox(
          height: _tileHeight(size).clamp(118, 220),
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
        const SizedBox(height: 10),
        Text(switch (size) {
          WidgetSizeDto.small => l.widgetSizeSmallHint,
          WidgetSizeDto.medium => l.widgetSizeMediumHint,
          WidgetSizeDto.large => l.widgetSizeLargeHint,
          WidgetSizeDto.full => l.widgetSizeFullHint,
        }, style: TextStyle(fontSize: 12, color: Nocturne.muted(.5))),
      ],
    );
  }

  /// The widget type as icon tiles, four in a row (two by two on a phone). Switching away from a
  /// scatter plot keeps the period; a scatter plot has none.
  Widget _typePicker(AppLocalizations l) {
    final descriptors = controller.widgetDescriptors;
    final perRow = Nocturne.isPhone(context) ? 2 : 4;
    Widget tile(WidgetDescriptorDto descriptor) {
      final type = descriptor.widgetType;
      final selected = type == widgetType;
      return Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          key: Key('widget-type-$type'),
          borderRadius: BorderRadius.circular(Nocturne.radius),
          onTap: () => setState(() {
            query = query.copyWith(
              widgetType: type,
              bucket: type == 'core.scatter-plot' ? null : query.bucket,
            );
          }),
          child: Container(
            height: 72,
            decoration: BoxDecoration(
              color: selected ? Nocturne.accent.withValues(alpha: .12) : null,
              borderRadius: BorderRadius.circular(Nocturne.radius),
              border: Border.all(
                color: selected ? Nocturne.accent : Nocturne.muted(.15),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 6,
              children: [
                Icon(
                  _typeIcon(type),
                  size: 22,
                  color: selected ? Nocturne.accent : Nocturne.muted(.7),
                ),
                Text(
                  widgetTypeName(l, type, descriptor.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? Nocturne.accent : Nocturne.muted(.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      key: const Key('widget-type'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Row(
          children: [
            Text(
              l.widgetType,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.7)),
            ),
            const HelpButton(HelpId.widgetType),
          ],
        ),
        for (var start = 0; start < descriptors.length; start += perRow)
          Row(
            spacing: 8,
            children: [
              for (var i = start; i < start + perRow; i++)
                Expanded(
                  child: i < descriptors.length
                      ? tile(descriptors[i])
                      : const SizedBox.shrink(),
                ),
            ],
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
        run: controller.runQuery,
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
