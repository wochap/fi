import 'package:fi/l10n/l10n.dart';

/// Stable identifiers for every contextual help affordance in the application.
///
/// The id names a concept, never the label text, so renaming a control on screen never orphans
/// its copy. [helpEntry] switches over every value, so a missing entry fails to compile.
enum HelpId {
  // Field editor.
  fieldRequired,
  fieldDefault,
  fieldDecimalScale,
  fieldMinMax,
  fieldMinMaxLength,
  fieldMultiline,
  fieldSlider,

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
  computedFields,
  computedFieldResult,
  querySavedQueries,

  // Pairing card.
  pairingStartPairing,
  pairingSingleInitiator,

  // Devices screen: connection switches.
  discoverable,
  syncEnabled,
}

/// One popup's worth of copy.
final class HelpEntry {
  const HelpEntry({required this.title, required this.body});

  final String title;
  final String body;
}

/// The localized help copy for [id]; titles and bodies live in the ARB files.
HelpEntry helpEntry(AppLocalizations l, HelpId id) => switch (id) {
  HelpId.fieldRequired => HelpEntry(
    title: l.helpFieldRequiredTitle,
    body: l.helpFieldRequiredBody,
  ),
  HelpId.fieldDefault => HelpEntry(
    title: l.helpFieldDefaultTitle,
    body: l.helpFieldDefaultBody,
  ),
  HelpId.fieldDecimalScale => HelpEntry(
    title: l.helpFieldDecimalScaleTitle,
    body: l.helpFieldDecimalScaleBody,
  ),
  HelpId.fieldMinMax => HelpEntry(
    title: l.helpFieldMinMaxTitle,
    body: l.helpFieldMinMaxBody,
  ),
  HelpId.fieldMinMaxLength => HelpEntry(
    title: l.helpFieldMinMaxLengthTitle,
    body: l.helpFieldMinMaxLengthBody,
  ),
  HelpId.fieldMultiline => HelpEntry(
    title: l.helpFieldMultilineTitle,
    body: l.helpFieldMultilineBody,
  ),
  HelpId.fieldSlider => HelpEntry(
    title: l.helpFieldSliderTitle,
    body: l.helpFieldSliderBody,
  ),
  HelpId.widgetType => HelpEntry(
    title: l.helpWidgetTypeTitle,
    body: l.helpWidgetTypeBody,
  ),
  HelpId.widgetUseSavedQuery => HelpEntry(
    title: l.helpWidgetUseSavedQueryTitle,
    body: l.helpWidgetUseSavedQueryBody,
  ),
  HelpId.widgetAggregation => HelpEntry(
    title: l.helpWidgetAggregationTitle,
    body: l.helpWidgetAggregationBody,
  ),
  HelpId.widgetOperandField => HelpEntry(
    title: l.helpWidgetOperandFieldTitle,
    body: l.helpWidgetOperandFieldBody,
  ),
  HelpId.widgetOutputScale => HelpEntry(
    title: l.helpWidgetOutputScaleTitle,
    body: l.helpWidgetOutputScaleBody,
  ),
  HelpId.widgetRounding => HelpEntry(
    title: l.helpWidgetRoundingTitle,
    body: l.helpWidgetRoundingBody,
  ),
  HelpId.widgetGroupBy => HelpEntry(
    title: l.helpWidgetGroupByTitle,
    body: l.helpWidgetGroupByBody,
  ),
  HelpId.widgetDateField => HelpEntry(
    title: l.helpWidgetDateFieldTitle,
    body: l.helpWidgetDateFieldBody,
  ),
  HelpId.widgetCategoryField => HelpEntry(
    title: l.helpWidgetCategoryFieldTitle,
    body: l.helpWidgetCategoryFieldBody,
  ),
  HelpId.widgetXAxis => HelpEntry(
    title: l.helpWidgetXAxisTitle,
    body: l.helpWidgetXAxisBody,
  ),
  HelpId.widgetYAxis => HelpEntry(
    title: l.helpWidgetYAxisTitle,
    body: l.helpWidgetYAxisBody,
  ),
  HelpId.widgetFilter => HelpEntry(
    title: l.helpWidgetFilterTitle,
    body: l.helpWidgetFilterBody,
  ),
  HelpId.widgetUnitSuffix => HelpEntry(
    title: l.helpWidgetUnitSuffixTitle,
    body: l.helpWidgetUnitSuffixBody,
  ),
  HelpId.widgetShowPoints => HelpEntry(
    title: l.helpWidgetShowPointsTitle,
    body: l.helpWidgetShowPointsBody,
  ),
  HelpId.widgetAxisLabel => HelpEntry(
    title: l.helpWidgetAxisLabelTitle,
    body: l.helpWidgetAxisLabelBody,
  ),
  HelpId.widgetBarWidth => HelpEntry(
    title: l.helpWidgetBarWidthTitle,
    body: l.helpWidgetBarWidthBody,
  ),
  HelpId.widgetPointRadius => HelpEntry(
    title: l.helpWidgetPointRadiusTitle,
    body: l.helpWidgetPointRadiusBody,
  ),
  HelpId.computedFields => HelpEntry(
    title: l.helpComputedFieldsTitle,
    body: l.helpComputedFieldsBody,
  ),
  HelpId.computedFieldResult => HelpEntry(
    title: l.helpComputedFieldResultTitle,
    body: l.helpComputedFieldResultBody,
  ),
  HelpId.querySavedQueries => HelpEntry(
    title: l.helpQuerySavedQueriesTitle,
    body: l.helpQuerySavedQueriesBody,
  ),
  HelpId.pairingStartPairing => HelpEntry(
    title: l.helpPairingStartPairingTitle,
    body: l.helpPairingStartPairingBody,
  ),
  HelpId.pairingSingleInitiator => HelpEntry(
    title: l.helpPairingSingleInitiatorTitle,
    body: l.helpPairingSingleInitiatorBody,
  ),
  HelpId.discoverable => HelpEntry(
    title: l.helpDiscoverableTitle,
    body: l.helpDiscoverableBody,
  ),
  HelpId.syncEnabled => HelpEntry(
    title: l.helpSyncEnabledTitle,
    body: l.helpSyncEnabledBody,
  ),
};
