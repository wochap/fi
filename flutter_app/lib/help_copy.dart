/// Stable identifiers for every contextual help affordance in the application.
///
/// The id names a concept, never the label text, so renaming a control on screen never orphans
/// its copy. Every value must have an entry in [helpCopy]; a registry test enumerates the enum so
/// a missing entry fails a test rather than rendering an empty popup.
enum HelpId {
  // Field editor.
  fieldRequired,
  fieldDefault,
  fieldDecimalScale,
  fieldMinMax,
  fieldMinMaxLength,
  fieldMultiline,

  // Widget form: query.
  widgetType,
  widgetUseSavedQuery,
  widgetAggregation,
  widgetOperandField,
  widgetOutputScale,
  widgetRounding,
  widgetGroupBy,
  widgetDateField,
  widgetCategoryField,
  widgetXAxis,
  widgetYAxis,
  widgetFilter,

  // Widget form: presentation.
  widgetUnitSuffix,
  widgetShowPoints,
  widgetAxisLabel,
  widgetBarWidth,
  widgetPointRadius,

  // Computed fields and queries dialog.
  queryComputedFields,
  querySavedQueries,

  // Pairing card.
  pairingStartPairing,
  pairingSingleInitiator,
}

/// One popup's worth of copy.
final class HelpEntry {
  const HelpEntry({required this.title, required this.body});

  final String title;
  final String body;
}

/// Every piece of contextual help copy, in one reviewable place.
const Map<HelpId, HelpEntry> helpCopy = {
  HelpId.fieldRequired: HelpEntry(
    title: 'Required',
    body:
        'A required field must hold a value. New records cannot be saved without it.\n\n'
        'Turning this on for a field that existing records do not have marks those records '
        'invalid until you fill the field in. They are never deleted, and you can still open '
        'and repair them from the record list.\n\n'
        'Setting a default avoids that: the default counts as the value for every record that '
        'does not have one.',
  ),
  HelpId.fieldDefault: HelpEntry(
    title: 'Default',
    body:
        'The value used when a record does not supply one. It fills new records as you create '
        'them, and it satisfies the Required rule for existing records that lack the field.\n\n'
        'Leave it empty if every record should state its own value.',
  ),
  HelpId.fieldDecimalScale: HelpEntry(
    title: 'Decimal scale',
    body:
        'How many digits are kept after the decimal point. Scale 2 stores 10.25 exactly; scale 0 '
        'stores whole numbers only.\n\n'
        'Values are stored as exact numbers, never as floating point, so sums and averages do not '
        'drift. The scale cannot be changed once records hold a value for this field.',
  ),
  HelpId.fieldMinMax: HelpEntry(
    title: 'Minimum and Maximum',
    body:
        'The range a value is allowed to fall in, inclusive on both ends. A record outside the '
        'range is rejected when you save it.\n\n'
        'Leave either box empty for no limit on that side.',
  ),
  HelpId.fieldMinMaxLength: HelpEntry(
    title: 'Minimum and Maximum length',
    body:
        'How short and how long the text may be, counted in characters.\n\n'
        'Leave either box empty for no limit on that side.',
  ),
  HelpId.fieldMultiline: HelpEntry(
    title: 'Multiline',
    body:
        'Shows this text field as a box that accepts line breaks instead of a single line. It '
        'changes how the field is edited, not what may be stored in it.',
  ),
  HelpId.widgetType: HelpEntry(
    title: 'Widget type',
    body:
        'What the widget draws.\n\n'
        'Number shows one aggregated value, such as a total or a count. Line chart draws a value '
        'over time. Bar chart compares one value across categories. Scatter plot places one point '
        'per record using two fields as the axes.',
  ),
  HelpId.widgetUseSavedQuery: HelpEntry(
    title: 'Use a saved query',
    body:
        'On, the widget reuses a query you already saved, and editing that query updates every '
        'widget that uses it.\n\n'
        'Off, you build the query here and it is saved under the widget title.',
  ),
  HelpId.widgetAggregation: HelpEntry(
    title: 'Aggregation',
    body:
        'How many records are reduced to one number.\n\n'
        'Count counts records and needs no field. Sum, Average, Min, and Max each read one '
        'numeric field, chosen below.\n\n'
        'With a Group by period the aggregation is computed once per period rather than once over '
        'everything.',
  ),
  HelpId.widgetOperandField: HelpEntry(
    title: 'Field to aggregate',
    body:
        'The numeric field the aggregation reads. Only number, decimal, and duration fields can '
        'be summed or averaged.\n\n'
        'Count ignores this because it counts records rather than values.',
  ),
  HelpId.widgetOutputScale: HelpEntry(
    title: 'Output scale',
    body:
        'How many decimal places the average keeps. An average rarely divides evenly, so the '
        'result must state its own precision instead of inheriting one.',
  ),
  HelpId.widgetRounding: HelpEntry(
    title: 'Rounding policy',
    body:
        'What happens when the average does not fit the output scale exactly.\n\n'
        'Half to even rounds to the nearest value and breaks ties toward the even digit, which '
        'keeps long runs of numbers unbiased. Reject inexact refuses to show a result rather than '
        'round, so you never read a rounded number as an exact one.',
  ),
  HelpId.widgetGroupBy: HelpEntry(
    title: 'Group by',
    body:
        'Buckets records by calendar period — day, week, month, or year — using the date field '
        'you choose, and computes the aggregation once per bucket. Each bucket becomes one point '
        'or one bar.\n\n'
        'Choose None to aggregate over everything at once, or to group by a category instead of a '
        'period.',
  ),
  HelpId.widgetDateField: HelpEntry(
    title: 'Date field',
    body:
        'The date or timestamp used to decide which period a record falls into. Weeks start on '
        'Monday and periods are computed in UTC.',
  ),
  HelpId.widgetCategoryField: HelpEntry(
    title: 'Category field',
    body:
        'The field whose values become the categories along the axis: one bar or one point per '
        'distinct value. Records sharing a value are aggregated together.',
  ),
  HelpId.widgetXAxis: HelpEntry(
    title: 'X axis',
    body:
        'The field plotted horizontally, one point per record. No aggregation happens: each '
        'record keeps its own point.',
  ),
  HelpId.widgetYAxis: HelpEntry(
    title: 'Y axis',
    body: 'The numeric field plotted vertically, one point per record.',
  ),
  HelpId.widgetFilter: HelpEntry(
    title: 'Filter',
    body:
        'Restricts the widget to records matching one condition, such as amount greater than 10 '
        'or category equals Migraine.\n\n'
        'Leave the field set to None to include every record. The filter changes what the widget '
        'shows; it never hides or deletes records anywhere else.',
  ),
  HelpId.widgetUnitSuffix: HelpEntry(
    title: 'Unit suffix',
    body:
        'Text shown after the value, such as EUR or mg. It is display only: the exact number is '
        'unchanged and the suffix is never stored with the data.',
  ),
  HelpId.widgetShowPoints: HelpEntry(
    title: 'Show points',
    body:
        'Draws a marker at every data point on the line, which helps when there are only a few '
        'points or when gaps matter.',
  ),
  HelpId.widgetAxisLabel: HelpEntry(
    title: 'Y axis label',
    body:
        'Text shown beside the vertical axis to name what is being measured, such as "Hours" or '
        '"EUR". Leave it empty for no label.',
  ),
  HelpId.widgetBarWidth: HelpEntry(
    title: 'Bar width',
    body:
        'How wide each bar is drawn, in logical pixels. Leave it empty to let the chart size the '
        'bars to fit.',
  ),
  HelpId.widgetPointRadius: HelpEntry(
    title: 'Point radius',
    body:
        'How large each plotted point is drawn, in logical pixels. Leave it empty for the default '
        'size.',
  ),
  HelpId.queryComputedFields: HelpEntry(
    title: 'Computed fields',
    body:
        'A field derived from other fields of the same record rather than typed in. It is '
        'recalculated on read, so it is never out of date, and it can be used by queries like any '
        'other field.',
  ),
  HelpId.querySavedQueries: HelpEntry(
    title: 'Saved queries',
    body:
        'A named query that widgets can reference. Editing one here updates every widget that '
        'uses it; the editor states how many widgets that is before you save.\n\n'
        'Deleting a query does not delete any record.',
  ),
  HelpId.pairingStartPairing: HelpEntry(
    title: 'Start pairing',
    body:
        'Makes this device discoverable to nearby devices for a short window so the two can '
        'exchange trust.\n\n'
        'Both devices must be nearby and on the same network, and both must have pairing on. '
        'Nothing is shared until you confirm the same six-digit code on both screens.',
  ),
  HelpId.pairingSingleInitiator: HelpEntry(
    title: 'Only one device connects',
    body:
        'Both devices see each other, but only one may tap Connect. If both tap, the two '
        'attempts collide and the pairing fails.\n\n'
        'Pick either device, tap Connect there, and let the other one wait.',
  ),
};
