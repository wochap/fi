import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart' show allViewId;
import 'package:fi/controllers.dart';
import 'package:fi/field_registry.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/views.dart';
import 'package:fi/theme/action_sheet.dart';
import 'package:fi/theme/confirm_dialog.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/form_surface.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:intl/intl.dart';

/// Below this screen width the views UI is laid out for a phone: long press opens a chip's
/// menu, and the editor and the reorder list are bottom sheets.
const double _phoneScreen = 720;

/// Most sort keys a view can hold.
const int maxViewSortKeys = 3;

/// The localized name shown for a view: All's name comes from the active language.
String viewDisplayName(AppLocalizations l, ViewDto view) =>
    view.id == allViewId ? l.viewAllName : view.name;

// ---------------------------------------------------------------------------------------------
// Sort and filter in words
// ---------------------------------------------------------------------------------------------

/// The field id a sort or filter expression names, or null for anything else.
String? _fieldIdOf(ExpressionDto expression) {
  if (expression.nodes.length != 1) return null;
  final node = expression.nodes.single;
  final field = node.field;
  if (node.kind != ExpressionKindDto.field || field == null) return null;
  return field.id;
}

bool _isCreated(ExpressionDto expression) =>
    expression.nodes.length == 1 &&
    expression.nodes.single.kind == ExpressionKindDto.recordCreatedAt;

/// The value a sort key picker uses for [expression].
String sortKeyOf(ExpressionDto expression) =>
    _isCreated(expression) ? 'created' : (_fieldIdOf(expression) ?? '?');

ExpressionDto _sortExpression(String key) => key == 'created'
    ? const ExpressionDto(
        root: 0,
        nodes: [ExpressionNodeDto(kind: ExpressionKindDto.recordCreatedAt)],
      )
    : fieldExpression(key);

FieldDefinitionDto? _field(CollectionSchemaDto schema, String? id) =>
    schema.fields.where((field) => field.id == id).firstOrNull;

/// The words for ascending and descending on a key of [kind]; null [kind] is the creation time.
(String ascending, String descending) directionWords(
  AppLocalizations l,
  FieldTypeKindDto? kind,
) => switch (kind) {
  null ||
  FieldTypeKindDto.date ||
  FieldTypeKindDto.dateTime => (l.viewDirOldest, l.viewDirNewest),
  FieldTypeKindDto.text => (l.viewDirAToZ, l.viewDirZToA),
  FieldTypeKindDto.integer ||
  FieldTypeKindDto.fixedDecimal ||
  FieldTypeKindDto.duration => (l.viewDirLow, l.viewDirHigh),
  FieldTypeKindDto.enum_ ||
  FieldTypeKindDto.enumSet => (l.viewDirOptionOrder, l.viewDirReverse),
  FieldTypeKindDto.boolean => (l.viewDirNoFirst, l.viewDirYesFirst),
};

String _sortKeyName(
  AppLocalizations l,
  CollectionSchemaDto schema,
  ExpressionDto expression,
) => _isCreated(expression)
    ? l.viewSortCreated
    : (_field(schema, _fieldIdOf(expression))?.name ?? '?');

String _directionWord(
  AppLocalizations l,
  CollectionSchemaDto schema,
  SortClauseDto clause,
) {
  final kind = _isCreated(clause.expression)
      ? null
      : _field(schema, _fieldIdOf(clause.expression))?.fieldType.kind;
  final (ascending, descending) = directionWords(l, kind);
  return clause.direction == SortDirectionDto.ascending
      ? ascending
      : descending;
}

/// `start at · newest, then type`.
String sortSummary(
  AppLocalizations l,
  CollectionSchemaDto schema,
  List<SortClauseDto> sorting,
) {
  if (sorting.isEmpty) return '';
  final first = sorting.first;
  return [
    '${_sortKeyName(l, schema, first.expression)} · '
        '${_directionWord(l, schema, first)}',
    for (final clause in sorting.skip(1))
      l.viewThenField(_sortKeyName(l, schema, clause.expression)),
  ].join(', ');
}

/// Fields a view may group by: single Choice, yes/no, Date and Date & time.
List<FieldDefinitionDto> groupableFields(CollectionSchemaDto schema) => [
  for (final field in activeFieldsOf(schema))
    if (const {
      FieldTypeKindDto.enum_,
      FieldTypeKindDto.boolean,
      FieldTypeKindDto.date,
      FieldTypeKindDto.dateTime,
    }.contains(field.fieldType.kind))
      field,
];

bool _isDateKind(FieldTypeKindDto? kind) =>
    kind == FieldTypeKindDto.date || kind == FieldTypeKindDto.dateTime;

String periodWord(AppLocalizations l, GroupPeriodDto period) =>
    switch (period) {
      GroupPeriodDto.day => l.viewPeriodDay,
      GroupPeriodDto.week => l.viewPeriodWeek,
      GroupPeriodDto.month => l.viewPeriodMonth,
    };

/// `start at · month`, or the field name for a Choice or yes/no grouping.
String groupingSummary(
  AppLocalizations l,
  CollectionSchemaDto schema,
  ViewGroupingDto grouping,
) {
  final name = _field(schema, grouping.fieldId)?.name ?? '?';
  return switch (grouping.period) {
    final period? => '$name · ${periodWord(l, period)}',
    null => name,
  };
}

/// A group's label: the localized day, "Week of ‹Monday›", the month and year, the option label,
/// Yes or No, or "No ‹field›".
String groupLabel(
  AppLocalizations l,
  CollectionSchemaDto schema,
  ViewGroupingDto grouping,
  ViewGroupDto group,
) {
  final field = _field(schema, grouping.fieldId);
  final key = group.key;
  switch (key.kind) {
    case GroupKeyKindDto.empty:
      return l.viewGroupNoValue(field?.name ?? '?');
    case GroupKeyKindDto.boolean:
      return key.flag == true ? l.commonYes : l.commonNo;
    case GroupKeyKindDto.option:
      return group.labelHint ??
          (field == null
              ? '?'
              : FieldRendererRegistry.optionLabel(field, key.optionId)) ??
          '?';
    case GroupKeyKindDto.date:
      final day = DateTime.utc(1970).add(Duration(days: key.days ?? 0));
      return switch (grouping.period) {
        GroupPeriodDto.week => l.viewGroupWeekOf(
          DateFormat.yMMMd().format(day),
        ),
        GroupPeriodDto.month => DateFormat.yMMMM().format(day),
        GroupPeriodDto.day || null => DateFormat.yMMMd().format(day),
      };
  }
}

/// The AND-ed conditions of a view filter, each as its own expression.
List<ExpressionDto> splitConditions(ExpressionDto? filter) {
  if (filter == null) return const [];
  final out = <ExpressionDto>[];
  void visit(int index) {
    final node = filter.nodes[index];
    if (node.kind == ExpressionKindDto.boolean &&
        node.booleanOperator == BooleanOperatorDto.and &&
        node.left != null &&
        node.right != null) {
      visit(node.left!);
      visit(node.right!);
    } else {
      out.add(_subtree(filter, index));
    }
  }

  visit(filter.root);
  return out;
}

/// The part of [expression] rooted at [root], renumbered from zero.
ExpressionDto _subtree(ExpressionDto expression, int root) {
  final order = <int>[];
  void collect(int index) {
    final node = expression.nodes[index];
    for (final child in [node.left, node.right, node.expression]) {
      if (child != null) collect(child);
    }
    if (!order.contains(index)) order.add(index);
  }

  collect(root);
  final map = {for (final (i, old) in order.indexed) old: i};
  return ExpressionDto(
    root: map[root]!,
    nodes: [
      for (final old in order) _shift(expression.nodes[old], (i) => map[i]!),
    ],
  );
}

ExpressionNodeDto _shift(ExpressionNodeDto node, int Function(int) to) =>
    ExpressionNodeDto(
      kind: node.kind,
      value: node.value,
      field: node.field,
      arithmeticOperator: node.arithmeticOperator,
      comparisonOperator: node.comparisonOperator,
      setOperator: node.setOperator,
      booleanOperator: node.booleanOperator,
      left: node.left == null ? null : to(node.left!),
      right: node.right == null ? null : to(node.right!),
      expression: node.expression == null ? null : to(node.expression!),
      outputScale: node.outputScale,
      rounding: node.rounding,
      boundary: node.boundary,
    );

/// [conditions] joined with AND, or null when there are none.
ExpressionDto? combineConditions(List<ExpressionDto> conditions) {
  if (conditions.isEmpty) return null;
  var combined = conditions.first;
  for (final next in conditions.skip(1)) {
    final offset = combined.nodes.length;
    final nodes = [
      ...combined.nodes,
      for (final node in next.nodes) _shift(node, (index) => index + offset),
    ];
    nodes.add(
      ExpressionNodeDto(
        kind: ExpressionKindDto.boolean,
        booleanOperator: BooleanOperatorDto.and,
        left: combined.root,
        right: next.root + offset,
      ),
    );
    combined = ExpressionDto(root: nodes.length - 1, nodes: nodes);
  }
  return combined;
}

/// One condition in words: `type is headache`, `level at least 5`.
String conditionSummary(
  AppLocalizations l,
  CollectionSchemaDto schema,
  ExpressionDto condition, {
  String decimalSeparator = '.',
}) {
  final state = QueryBuilderState.fromFilter(
    condition,
    schema,
    decimalSeparator: decimalSeparator,
  );
  if (state == null) return l.viewEditorOtherCondition;
  // "type is any of headache" reads as "type is headache" with a single option.
  if (state.filterChoices &&
      state.choicesOperator == ChoicesFilterOperator.hasAnyOf &&
      state.filterOptions.length == 1) {
    final field = _field(schema, state.filterFieldId);
    final label = field == null
        ? state.filterOptions.single
        : FieldRendererRegistry.optionLabels(
            field,
            FieldValueDto(
              kind: FieldValueKindDto.enumSet,
              listValue: state.filterOptions,
            ),
          ).join();
    return l.queryFilterChip(field?.name ?? '?', l.queryOpIs, label);
  }
  return queryConditionText(l, schema, state, viewWords: true);
}

/// `type is headache · level at least 5`, or null when [filter] keeps every record.
String? filterSummary(
  AppLocalizations l,
  CollectionSchemaDto schema,
  ExpressionDto? filter, {
  String decimalSeparator = '.',
}) {
  final conditions = splitConditions(filter);
  if (conditions.isEmpty) return null;
  return [
    for (final condition in conditions)
      conditionSummary(
        l,
        schema,
        condition,
        decimalSeparator: decimalSeparator,
      ),
  ].join(' · ');
}

// ---------------------------------------------------------------------------------------------
// Chip row
// ---------------------------------------------------------------------------------------------

/// The view chips (mock collection-records, Views block): All, the saved views and "+ View". It
/// scrolls sideways and keeps the selected chip in view.
class ViewChipRow extends StatefulWidget {
  const ViewChipRow({
    required this.controller,
    required this.schema,
    this.anchor,
    super.key,
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;

  /// Where the edit-view popover hangs from at 720px and wider.
  final GlobalKey? anchor;

  @override
  State<ViewChipRow> createState() => _ViewChipRowState();
}

class _ViewChipRowState extends State<ViewChipRow> {
  final _selected = GlobalKey();
  String? _shown;
  bool _wasModified = false;

  CollectionsController get controller => widget.controller;

  void _keepSelectedVisible() {
    if (_shown == controller.activeViewId) return;
    _shown = controller.activeViewId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _selected.currentContext;
      if (chip == null || !chip.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          chip,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: const Duration(milliseconds: 150),
        ),
      );
      if (!chip.mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          chip,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: const Duration(milliseconds: 150),
        ),
      );
    });
  }

  void _announceModified(AppLocalizations l) {
    final modified = controller.isModified;
    if (modified && !_wasModified) {
      final view = controller.activeView;
      final name = view == null ? l.viewAllName : viewDisplayName(l, view);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          SemanticsService.sendAnnouncement(
            View.of(context),
            l.viewModifiedAnnounce(name),
            Directionality.of(context),
          ),
        );
      });
    }
    _wasModified = modified;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    _keepSelectedVisible();
    _announceModified(l);
    final views = controller.views.isEmpty
        ? [
            ViewDto(
              id: allViewId,
              name: l.viewAllName,
              order: 0,
              count: controller.allRecords.length,
              effectiveSort: CollectionsController.allViewBody.sorting,
            ),
          ]
        : controller.views;
    final phone = MediaQuery.sizeOf(context).width < _phoneScreen;
    return SingleChildScrollView(
      key: const Key('view-chips'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Semantics(
            role: SemanticsRole.tabBar,
            label: l.viewTabsLabel,
            container: true,
            explicitChildNodes: true,
            child: Row(
              spacing: 6,
              children: [
                for (final view in views) _chip(context, l, view, phone: phone),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            key: const Key('new-view'),
            style: TextButton.styleFrom(
              minimumSize: Size(0, phone ? 40 : 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foregroundColor: context.nocturne.muted(.7),
            ),
            onPressed: () => unawaited(
              showViewEditor(
                context,
                controller: controller,
                schema: widget.schema,
                create: true,
                body: CollectionsController.allViewBody,
                anchor: widget.anchor,
              ),
            ),
            icon: const Icon(FiIcons.add, size: 14),
            label: Semantics(
              label: l.viewNewViewLabel,
              child: ExcludeSemantics(child: Text(l.viewNewView)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    AppLocalizations l,
    ViewDto view, {
    required bool phone,
  }) {
    final c = context.nocturne;
    final selected = view.id == controller.activeViewId;
    final modified = selected && controller.isModified;
    final broken =
        view.broken != null || (selected && controller.brokenView != null);
    // The selected view's count follows its unsaved changes.
    final count = selected && controller.viewResult != null && !broken
        ? controller.viewResult!.count
        : view.count;
    final name = viewDisplayName(l, view);
    void select() => unawaited(controller.selectView(view.id));
    void menu([Offset? at]) => unawaited(
      showViewMenu(
        context,
        controller: controller,
        schema: widget.schema,
        view: view,
        position: at,
        anchor: widget.anchor,
      ),
    );
    final semantics = [
      name,
      if (broken)
        l.viewSemanticsBroken
      else if (count != null)
        l.viewSemanticsCount(count),
      if (modified) l.viewSemanticsModified,
    ].join(', ');
    final ink = selected ? c.accentInkStrong : c.muted(.8);
    return Semantics(
      key: selected ? _selected : null,
      role: SemanticsRole.tab,
      container: true,
      selected: selected,
      label: semantics,
      onTap: select,
      onLongPress: menu,
      child: ExcludeSemantics(
        child: Material(
          key: Key('view-chip-${view.id}'),
          color: selected ? c.accentFill : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Nocturne.radius),
            side: BorderSide(color: selected ? c.accentEdge : c.neutralEdge),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: select,
            onLongPress: phone ? menu : null,
            onSecondaryTapUp: phone
                ? null
                : (details) => menu(details.globalPosition),
            child: Container(
              constraints: BoxConstraints(minHeight: phone ? 40 : 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w500 : null,
                      color: ink,
                    ),
                  ),
                  if (broken)
                    Icon(
                      FiIcons.warning,
                      key: Key('view-broken-${view.id}'),
                      size: 14,
                      color: c.warning,
                    )
                  else if (count != null)
                    Text(
                      '· $count',
                      style: TextStyle(
                        fontSize: 13,
                        fontFeatures: Nocturne.tabular,
                        color: selected ? c.accentInk : c.muted(.5),
                      ),
                    ),
                  if (modified)
                    Container(
                      key: Key('view-modified-${view.id}'),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// View line
// ---------------------------------------------------------------------------------------------

/// The summary under the chips: "Sort: start at · newest" and "Filter: …", the ⇅ flip, and Save ·
/// Save as new view · Reset while the view is modified. Tapping the line opens the editor.
class ViewLine extends StatelessWidget {
  const ViewLine({
    required this.controller,
    required this.schema,
    this.anchor,
    super.key,
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;
  final GlobalKey? anchor;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.nocturne;
    final body = controller.activeBody;
    // A degraded view shows the sort it actually runs with.
    final sorting = controller.isModified || controller.activeView == null
        ? body.sorting
        : controller.activeView!.effectiveSort;
    final separator = decimalSeparatorOf(context);
    final filter = controller.brokenView != null
        ? null
        : filterSummary(l, schema, body.filter, decimalSeparator: separator);
    final grouping = controller.brokenView != null ? null : body.grouping;
    final muted = TextStyle(color: c.muted(.5));
    final summary = Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: c.muted(.75)),
        children: [
          TextSpan(text: '${l.viewSortLabel} ', style: muted),
          TextSpan(text: sortSummary(l, schema, sorting)),
          if (filter != null) ...[
            TextSpan(text: '  ·  ', style: muted),
            TextSpan(text: '${l.viewFilterLabel} ', style: muted),
            TextSpan(text: filter),
          ],
          if (grouping != null) ...[
            TextSpan(text: '  ·  ', style: muted),
            TextSpan(text: '${l.viewGroupLabel} ', style: muted),
            TextSpan(text: groupingSummary(l, schema, grouping)),
          ],
        ],
      ),
      key: const Key('view-line-text'),
    );
    final ghost = TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontSize: 12),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: InkWell(
                key: const Key('view-line'),
                borderRadius: BorderRadius.circular(Nocturne.radiusSm),
                onTap: () => unawaited(_edit(context)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Flexible(child: summary),
                      const SizedBox(width: 6),
                      Icon(FiIcons.filter, size: 14, color: c.muted(.45)),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('view-flip'),
              tooltip: l.viewFlipSort,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () => unawaited(controller.flipPrimarySort()),
              icon: const Icon(FiIcons.reorder),
            ),
          ],
        ),
        if (controller.isModified)
          Wrap(
            spacing: 4,
            children: [
              if (controller.canSaveView)
                TextButton.icon(
                  key: const Key('view-save'),
                  style: ghost,
                  onPressed: () => unawaited(controller.saveView()),
                  icon: const Icon(FiIcons.check, size: 14),
                  label: Text(l.commonSave),
                ),
              TextButton(
                key: const Key('view-save-as-new'),
                style: ghost,
                onPressed: () => unawaited(
                  showViewEditor(
                    context,
                    controller: controller,
                    schema: schema,
                    create: true,
                    body: controller.activeBody,
                    anchor: anchor,
                  ),
                ),
                child: Text(l.viewSaveAsNew),
              ),
              TextButton(
                key: const Key('view-reset'),
                style: ghost,
                onPressed: () => unawaited(controller.resetView()),
                child: Text(l.viewReset),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context) => showViewEditor(
    context,
    controller: controller,
    schema: schema,
    view: controller.activeView,
    body: controller.activeBody,
    anchor: anchor,
  );
}

// ---------------------------------------------------------------------------------------------
// Notices
// ---------------------------------------------------------------------------------------------

/// A one-line notice with an action: the broken-view and discarded-changes notices.
class ViewNotice extends StatelessWidget {
  const ViewNotice({
    required this.text,
    required this.action,
    required this.onAction,
    super.key,
  });

  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.nocturne;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.neutralFill,
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: c.neutralEdge),
      ),
      child: Row(
        children: [
          Icon(FiIcons.warning, size: 16, color: c.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: c.muted(.8)),
            ),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}

/// The list area of a view that keeps no record: "No records match ‹view›." with Edit view and
/// Show all.
class EmptyViewState extends StatelessWidget {
  const EmptyViewState({
    required this.controller,
    required this.schema,
    this.anchor,
    super.key,
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;
  final GlobalKey? anchor;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final view = controller.activeView;
    final name = view == null ? l.viewAllName : viewDisplayName(l, view);
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Text(
          l.viewEmpty(name),
          key: const Key('view-empty'),
          textAlign: TextAlign.center,
          style: TextStyle(color: context.nocturne.muted(.55)),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton(
              key: const Key('view-empty-edit'),
              onPressed: () => unawaited(
                showViewEditor(
                  context,
                  controller: controller,
                  schema: schema,
                  view: view,
                  body: controller.activeBody,
                  anchor: anchor,
                ),
              ),
              child: Text(l.viewEditView),
            ),
            TextButton(
              key: const Key('view-show-all'),
              onPressed: () => unawaited(controller.selectView(allViewId)),
              child: Text(l.viewShowAll),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Edit-view editor
// ---------------------------------------------------------------------------------------------

/// The top-left point below [anchor], where the desktop popover hangs from.
Offset? _anchorPoint(GlobalKey? anchor) {
  final box = anchor?.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset(0, box.size.height + 6));
}

/// Opens the edit-view editor: a bottom sheet on a phone, a popover anchored to the chip row at
/// 720px and wider. [create] makes a new view from [body]; otherwise it edits [view] (All when
/// null or All).
Future<void> showViewEditor(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
  required ViewBodyDto body,
  ViewDto? view,
  bool create = false,
  GlobalKey? anchor,
}) {
  final editor = _ViewEditor(
    controller: controller,
    schema: schema,
    view: create ? null : view,
    create: create,
    body: body,
    anchor: _anchorPoint(anchor),
  );
  if (MediaQuery.sizeOf(context).width < _phoneScreen) {
    return showFormSurface<void>(context, builder: (_) => editor);
  }
  return showDialog<void>(
    context: context,
    builder: (_) =>
        FormSurfaceScope(mode: FormSurfaceMode.dialog, child: editor),
  );
}

/// One filter condition in the editor: builder state, or an expression it can't show, kept as
/// it is.
final class _Condition {
  _Condition.state(QueryBuilderState this.state) : raw = null;
  _Condition.raw(ExpressionDto this.raw) : state = null;

  QueryBuilderState? state;
  final ExpressionDto? raw;
}

class _ViewEditor extends StatefulWidget {
  const _ViewEditor({
    required this.controller,
    required this.schema,
    required this.view,
    required this.create,
    required this.body,
    required this.anchor,
  });

  final CollectionsController controller;
  final CollectionSchemaDto schema;
  final ViewDto? view;
  final bool create;
  final ViewBodyDto body;
  final Offset? anchor;

  @override
  State<_ViewEditor> createState() => _ViewEditorState();
}

class _ViewEditorState extends State<_ViewEditor> {
  late final TextEditingController name;
  late final List<_Condition> conditions;
  late final List<SortClauseDto> sorting;
  ViewGroupingDto? grouping;
  var _counter = 0;
  late final List<int> _conditionKeys;
  FormIssues issues = FormIssues.none;
  bool saving = false;

  bool get editsAll =>
      !widget.create && (widget.view == null || widget.view!.id == allViewId);

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.create ? '' : widget.view?.name);
    final schema = widget.schema;
    conditions = [
      for (final condition in splitConditions(widget.body.filter))
        switch (QueryBuilderState.fromFilter(condition, schema)) {
          final state? => _Condition.state(state),
          null => _Condition.raw(condition),
        },
    ];
    _conditionKeys = [for (final _ in conditions) _counter++];
    sorting = [...widget.body.sorting];
    grouping = widget.body.grouping;
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  /// Fields a view may sort by: every active field except multi-option Choices.
  List<FieldDefinitionDto> get _sortFields => [
    for (final field in activeFieldsOf(widget.schema))
      if (field.fieldType.kind != FieldTypeKindDto.enumSet) field,
  ];

  ViewBodyDto _body(String decimalSeparator) => ViewBodyDto(
    filter: combineConditions([
      for (final condition in conditions)
        if (condition.raw case final raw?)
          raw
        else
          ?condition.state!.filterExpression(widget.schema, decimalSeparator),
    ]),
    sorting: sorting,
    grouping: grouping,
  );

  ViewNameProblem? _nameProblem(AppLocalizations l) => editsAll
      ? null
      : viewNameProblem(
          name.text,
          allName: l.viewAllName,
          views: widget.controller.views,
          exceptViewId: widget.view?.id,
        );

  Future<void> _save() async {
    final controller = widget.controller;
    final body = _body(decimalSeparatorOf(context));
    final navigator = Navigator.of(context);
    setState(() {
      saving = true;
      issues = FormIssues.none;
    });
    try {
      if (widget.create) {
        await controller.saveAsNewView(name.text.trim(), body: body);
      } else if (editsAll) {
        await controller.editView(allViewId, body: body);
      } else {
        final view = widget.view!;
        final newName = name.text.trim();
        await controller.editView(
          view.id,
          body: body,
          name: newName == view.name ? null : newName,
        );
      }
      if (mounted) navigator.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        saving = false;
        issues = FormIssues.from(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.nocturne;
    final problem = _nameProblem(l);
    final sectionStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: c.muted(.7),
    );
    final nameLines = [
      ...issues.fieldLines(l, 'name'),
      if (problem == ViewNameProblem.reserved)
        l.viewNameReserved(l.viewAllName),
    ];
    final title = widget.create
        ? l.viewNewViewLabel
        : editsAll
        ? '${l.viewEditView} · ${l.viewAllName}'
        : l.viewEditView;
    return FormSurface(
      title: title,
      anchor: widget.anchor,
      width: 520,
      primaryLabel: l.commonSave,
      primaryKey: const Key('view-editor-save'),
      onPrimary: saving || viewNameBlocksSave(problem) ? null : _save,
      errors: issues.formLines(l),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (!editsAll)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FiTextInput(
                key: const Key('view-editor-name'),
                controller: name,
                label: l.viewEditorName,
                autofocus: widget.create,
                errors: nameLines,
                helperText: problem == ViewNameProblem.duplicate
                    ? l.viewNameDuplicate(name.text.trim())
                    : null,
                onChanged: (_) => setState(() {}),
              ),
            ),
          Text(l.viewEditorFilter, style: sectionStyle),
          for (final (index, condition) in conditions.indexed)
            Row(
              key: ValueKey('condition-${_conditionKeys[index]}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: switch (condition.state) {
                    final state? => QueryConditionRow(
                      schema: widget.schema,
                      state: state,
                      viewWords: true,
                      onChanged: (next) =>
                          setState(() => condition.state = next),
                    ),
                    null => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l.viewEditorOtherCondition,
                        style: TextStyle(fontSize: 13, color: c.muted(.6)),
                      ),
                    ),
                  },
                ),
                IconButton(
                  key: Key('remove-condition-$index'),
                  tooltip: l.viewEditorRemoveCondition,
                  iconSize: 16,
                  onPressed: () => setState(() {
                    conditions.removeAt(index);
                    _conditionKeys.removeAt(index);
                  }),
                  icon: const Icon(FiIcons.clear),
                ),
              ],
            ),
          ...[
            for (final line in issues.fieldLines(l, 'filter'))
              Text(line, style: TextStyle(fontSize: 12, color: c.danger)),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('view-add-filter'),
              onPressed: () => setState(() {
                conditions.add(_Condition.state(const QueryBuilderState()));
                _conditionKeys.add(_counter++);
              }),
              icon: const Icon(FiIcons.add, size: 14),
              label: Text(l.queryAddFilter),
            ),
          ),
          Text(l.viewEditorSort, style: sectionStyle),
          for (final (index, clause) in sorting.indexed)
            _sortRow(context, l, index, clause),
          ...[
            for (final line in issues.fieldLines(l, 'sorting'))
              Text(line, style: TextStyle(fontSize: 12, color: c.danger)),
          ],
          if (sorting.length < maxViewSortKeys)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('view-then-by'),
                onPressed: () => setState(() {
                  final used = {
                    for (final clause in sorting) sortKeyOf(clause.expression),
                  };
                  final key = [
                    'created',
                    for (final field in _sortFields) field.id,
                  ].where((key) => !used.contains(key)).firstOrNull;
                  if (key == null) return;
                  sorting.add(
                    SortClauseDto(
                      expression: _sortExpression(key),
                      direction: SortDirectionDto.descending,
                      nullOrder: NullOrderDto.last,
                    ),
                  );
                }),
                icon: const Icon(FiIcons.add, size: 14),
                label: Text(
                  sorting.isEmpty ? l.viewEditorSort : l.viewEditorThenBy,
                ),
              ),
            ),
          Text(l.viewEditorGroup, style: sectionStyle),
          _groupRow(l),
          ...[
            for (final line in issues.fieldLines(l, 'grouping'))
              Text(line, style: TextStyle(fontSize: 12, color: c.danger)),
          ],
        ],
      ),
    );
  }

  /// None, any single Choice, yes/no, Date or Date & time field; dates also pick Day, Week or
  /// Month. Multi-option Choices fields are never offered.
  Widget _groupRow(AppLocalizations l) {
    final fields = groupableFields(widget.schema);
    final current = grouping;
    final known =
        current != null && fields.any((field) => field.id == current.fieldId);
    final kind = known
        ? _field(widget.schema, current.fieldId)?.fieldType.kind
        : null;
    return Row(
      key: const Key('view-group'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Expanded(
          flex: 3,
          child: FiSelect<String>.compact(
            key: const Key('view-group-field'),
            value: known ? current.fieldId : '',
            label: l.viewEditorGroupField,
            items: [
              DropdownMenuItem(value: '', child: Text(l.viewEditorGroupNone)),
              for (final field in fields)
                DropdownMenuItem(value: field.id, child: Text(field.name)),
            ],
            onChanged: (value) => setState(() {
              if (value == null || value.isEmpty) {
                grouping = null;
                return;
              }
              final date = _isDateKind(
                _field(widget.schema, value)?.fieldType.kind,
              );
              grouping = ViewGroupingDto(
                fieldId: value,
                period: date ? (current?.period ?? GroupPeriodDto.month) : null,
              );
            }),
          ),
        ),
        if (_isDateKind(kind))
          Expanded(
            flex: 2,
            child: FiSelect<GroupPeriodDto>.compact(
              key: const Key('view-group-period'),
              value: current!.period ?? GroupPeriodDto.month,
              label: l.viewEditorGroupPeriod,
              items: [
                for (final period in GroupPeriodDto.values)
                  DropdownMenuItem(
                    value: period,
                    child: Text(periodWord(l, period)),
                  ),
              ],
              onChanged: (value) => setState(
                () => grouping = ViewGroupingDto(
                  fieldId: current.fieldId,
                  period: value ?? current.period,
                ),
              ),
            ),
          )
        else
          const Spacer(flex: 2),
      ],
    );
  }

  Widget _sortRow(
    BuildContext context,
    AppLocalizations l,
    int index,
    SortClauseDto clause,
  ) {
    final key = sortKeyOf(clause.expression);
    final fields = _sortFields;
    final known = key == 'created' || fields.any((field) => field.id == key);
    final kind = key == 'created'
        ? null
        : _field(widget.schema, key)?.fieldType.kind;
    final (ascending, descending) = directionWords(l, kind);
    void replace(SortClauseDto next) => setState(() => sorting[index] = next);
    return Row(
      key: ValueKey('sort-$index'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Expanded(
          flex: 3,
          child: FiSelect<String>.compact(
            key: Key('view-sort-field-$index'),
            value: known ? key : null,
            label: index == 0 ? l.viewEditorSortField : l.viewEditorThenBy,
            items: [
              DropdownMenuItem(
                value: 'created',
                child: Text(l.viewSortCreated),
              ),
              for (final field in fields)
                DropdownMenuItem(value: field.id, child: Text(field.name)),
            ],
            onChanged: (value) {
              if (value == null) return;
              replace(
                SortClauseDto(
                  expression: _sortExpression(value),
                  direction: clause.direction,
                  nullOrder: NullOrderDto.last,
                ),
              );
            },
          ),
        ),
        Expanded(
          flex: 2,
          child: FiSelect<SortDirectionDto>.compact(
            key: Key('view-sort-direction-$index'),
            value: clause.direction,
            label: l.viewEditorDirection,
            items: [
              DropdownMenuItem(
                value: SortDirectionDto.descending,
                child: Text(descending),
              ),
              DropdownMenuItem(
                value: SortDirectionDto.ascending,
                child: Text(ascending),
              ),
            ],
            onChanged: (value) => replace(
              SortClauseDto(
                expression: clause.expression,
                direction: value ?? clause.direction,
                nullOrder: NullOrderDto.last,
              ),
            ),
          ),
        ),
        IconButton(
          key: Key('remove-sort-$index'),
          tooltip: l.viewEditorRemoveSort,
          iconSize: 16,
          onPressed: () => setState(() => sorting.removeAt(index)),
          icon: const Icon(FiIcons.clear),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Chip menu, rename, delete
// ---------------------------------------------------------------------------------------------

enum _ViewAction { rename, edit, reorder, delete }

/// The chip menu: Rename, Edit, "Reorder views…", "Delete…" for a saved view; only "Reorder
/// views…" for All. An action sheet on a phone, a popup menu at [position] otherwise.
Future<void> showViewMenu(
  BuildContext context, {
  required CollectionsController controller,
  required CollectionSchemaDto schema,
  required ViewDto view,
  Offset? position,
  GlobalKey? anchor,
}) async {
  final l = context.l10n;
  final actions = view.id == allViewId
      ? const [_ViewAction.reorder]
      : _ViewAction.values;
  String label(_ViewAction action) => switch (action) {
    _ViewAction.rename => l.commonRename,
    _ViewAction.edit => l.commonEdit,
    _ViewAction.reorder => l.viewMenuReorder,
    _ViewAction.delete => l.viewMenuDelete,
  };
  IconData icon(_ViewAction action) => switch (action) {
    _ViewAction.rename => FiIcons.edit,
    _ViewAction.edit => FiIcons.filter,
    _ViewAction.reorder => FiIcons.reorder,
    _ViewAction.delete => FiIcons.delete,
  };
  final phone = MediaQuery.sizeOf(context).width < _phoneScreen;
  final _ViewAction? picked;
  if (phone || position == null) {
    picked = await showActionSheet<_ViewAction>(
      context,
      icon: FiIcons.filter,
      title: viewDisplayName(l, view),
      groups: [
        ActionSheetGroup([
          for (final action in actions)
            ActionSheetItem(
              value: action,
              label: label(action),
              icon: icon(action),
            ),
        ]),
      ],
    );
  } else {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    picked = await showMenu<_ViewAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final action in actions)
          PopupMenuItem(
            key: Key('view-menu-${action.name}'),
            value: action,
            child: Row(
              spacing: 10,
              children: [Icon(icon(action), size: 16), Text(label(action))],
            ),
          ),
      ],
    );
  }
  if (picked == null || !context.mounted) return;
  switch (picked) {
    case _ViewAction.rename:
      await showRenameView(context, controller: controller, view: view);
    case _ViewAction.edit:
      if (controller.activeViewId != view.id) {
        await controller.selectView(view.id);
      }
      if (!context.mounted) return;
      await showViewEditor(
        context,
        controller: controller,
        schema: schema,
        view: view,
        body: controller.activeViewId == view.id
            ? controller.activeBody
            : (view.body ?? CollectionsController.allViewBody),
        anchor: anchor,
      );
    case _ViewAction.reorder:
      await showReorderViews(context, controller: controller);
    case _ViewAction.delete:
      await confirmDeleteView(context, controller: controller, view: view);
  }
}

/// Renames [view] with the editor's name checks.
Future<void> showRenameView(
  BuildContext context, {
  required CollectionsController controller,
  required ViewDto view,
}) => showDialog<void>(
  context: context,
  builder: (_) => _RenameView(controller: controller, view: view),
);

class _RenameView extends StatefulWidget {
  const _RenameView({required this.controller, required this.view});

  final CollectionsController controller;
  final ViewDto view;

  @override
  State<_RenameView> createState() => _RenameViewState();
}

class _RenameViewState extends State<_RenameView> {
  late final name = TextEditingController(text: widget.view.name);
  FormIssues issues = FormIssues.none;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    try {
      await widget.controller.renameView(widget.view.id, name.text.trim());
      navigator.pop();
    } catch (error) {
      if (mounted) setState(() => issues = FormIssues.from(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final problem = viewNameProblem(
      name.text,
      allName: l.viewAllName,
      views: widget.controller.views,
      exceptViewId: widget.view.id,
    );
    final blocked = viewNameBlocksSave(problem);
    return AlertDialog(
      title: Text(l.viewRenameTitle),
      content: SizedBox(
        width: 360,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FiTextInput(
            key: const Key('view-rename-name'),
            controller: name,
            autofocus: true,
            label: l.viewEditorName,
            errors: [
              ...issues.fieldLines(l, 'name'),
              ...issues.formLines(l),
              if (problem == ViewNameProblem.reserved)
                l.viewNameReserved(l.viewAllName),
            ],
            helperText: problem == ViewNameProblem.duplicate
                ? l.viewNameDuplicate(name.text.trim())
                : null,
            onChanged: (_) => setState(() {}),
            onSubmitted: blocked ? null : (_) => unawaited(_save()),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.commonCancel),
        ),
        FilledButton(
          key: const Key('view-rename-save'),
          onPressed: blocked ? null : () => unawaited(_save()),
          child: Text(l.commonSave),
        ),
      ],
    );
  }
}

/// Asks "Delete view “‹name›”?" and deletes on confirmation.
Future<void> confirmDeleteView(
  BuildContext context, {
  required CollectionsController controller,
  required ViewDto view,
}) async {
  final l = context.l10n;
  final confirmed = await showConfirmDialog(
    context,
    title: l.viewDeleteTitle(view.name),
    body: l.viewDeleteBody,
    destructive: l.commonDelete,
    safe: l.viewDeleteKeep,
    destructiveKey: const Key('view-delete-confirm'),
    safeKey: const Key('view-delete-keep'),
  );
  if (confirmed) await controller.deleteView(view.id);
}

// ---------------------------------------------------------------------------------------------
// Reorder views
// ---------------------------------------------------------------------------------------------

/// "Reorder views…": a sheet on a phone, a dialog at 720px and wider. All stays first; each
/// saved view moves by its six-dot handle or the list's move actions, and every move is saved.
Future<void> showReorderViews(
  BuildContext context, {
  required CollectionsController controller,
}) {
  final content = _ReorderViews(controller: controller);
  if (MediaQuery.sizeOf(context).width < _phoneScreen) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => content,
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 420, child: content)),
  );
}

class _ReorderViews extends StatefulWidget {
  const _ReorderViews({required this.controller});

  final CollectionsController controller;

  @override
  State<_ReorderViews> createState() => _ReorderViewsState();
}

class _ReorderViewsState extends State<_ReorderViews> {
  late final List<ViewDto> saved = [
    for (final view in widget.controller.views)
      if (view.id != allViewId) view,
  ];

  void _move(int from, int to) {
    setState(() => saved.insert(to > from ? to - 1 : to, saved.removeAt(from)));
    unawaited(
      widget.controller.reorderViews([for (final view in saved) view.id]),
    );
  }

  Widget _count(BuildContext context, ViewDto view) {
    final c = context.nocturne;
    if (view.broken != null) {
      return Icon(FiIcons.warning, size: 14, color: c.warning);
    }
    return Text(
      '${view.count ?? ''}',
      style: TextStyle(
        fontSize: 12,
        fontFeatures: Nocturne.tabular,
        color: c.muted(.55),
      ),
    );
  }

  Widget _row(BuildContext context, {required Widget child, Key? key}) =>
      Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 6),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: context.nocturne.bg,
          borderRadius: BorderRadius.circular(Nocturne.radius),
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.nocturne;
    final all = widget.controller.views
        .where((view) => view.id == allViewId)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          child: Text(
            l.viewReorderTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row(
                  context,
                  key: const Key('reorder-all'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(44, 0, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l.viewAllName,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        Text(
                          l.viewReorderAlwaysFirst,
                          style: TextStyle(fontSize: 12, color: c.muted(.5)),
                        ),
                        const SizedBox(width: 12),
                        ?all == null ? null : _count(context, all),
                      ],
                    ),
                  ),
                ),
                ReorderableListView(
                  key: const Key('reorder-views'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorder: _move,
                  children: [
                    for (final (index, view) in saved.indexed)
                      _row(
                        context,
                        key: ValueKey(view.id),
                        child: Row(
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              child: Padding(
                                key: Key('reorder-handle-${view.id}'),
                                padding: const EdgeInsets.all(10),
                                child: Icon(
                                  FiIcons.dragHandle,
                                  size: 18,
                                  color: c.muted(.45),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                view.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            _count(context, view),
                            const SizedBox(width: 12),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: const Key('reorder-done'),
              onPressed: () => Navigator.pop(context),
              child: Text(l.commonDone),
            ),
          ),
        ),
      ],
    );
  }
}
