// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get navCollections => 'Collections';

  @override
  String get navDevices => 'Devices';

  @override
  String get navSettings => 'Settings';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get langAppLanguage => 'App language';

  @override
  String get langAppLanguageHint =>
      'Menus, labels and dates. Changes apply right away.';

  @override
  String get langSystemDefault => 'System default';

  @override
  String langSystemDefaultNamed(String language) {
    return 'System default ($language)';
  }

  @override
  String langSameAsPhone(String language) {
    return '$language — same as your phone';
  }

  @override
  String get errorUnexpected =>
      'The local collection service encountered an unexpected error.';

  @override
  String get errorInitialization =>
      'Secure device networking could not be initialized.';

  @override
  String get errorSecureStoreLocked =>
      'Your login keyring is locked, so secure device networking cannot start. Unlock the keyring and retry.';

  @override
  String get errorPaused => 'Sync with paired devices is off.';

  @override
  String get errorBootstrap => 'This device\'s local data cannot be opened.';

  @override
  String get errorPersistence => 'Local data could not be saved or loaded.';

  @override
  String get errorProjection => 'The local read model could not be refreshed.';

  @override
  String get errorLifecycle =>
      'The device could not be reached, or the local service is not running.';

  @override
  String get errorInternal =>
      'The local collection data is not supported by this application version.';

  @override
  String errorValidation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count problems need attention',
      one: '1 problem needs attention',
    );
    return '$_temp0';
  }

  @override
  String get issueRequired => 'Required';

  @override
  String get issueTypeMismatch => 'Value does not match this field\'s type';

  @override
  String get issueInactiveOption => 'Pick an active option';

  @override
  String get issueFieldUnavailable => 'This field is no longer available';

  @override
  String issueLengthRange(int min, int max) {
    return 'Must be $min–$max characters';
  }

  @override
  String issueLengthExact(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Must be exactly $count characters',
      one: 'Must be exactly 1 character',
    );
    return '$_temp0';
  }

  @override
  String issueLengthMin(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Must be at least $count characters',
      one: 'Must be at least 1 character',
    );
    return '$_temp0';
  }

  @override
  String issueLengthMax(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Must be at most $count characters',
      one: 'Must be at most 1 character',
    );
    return '$_temp0';
  }

  @override
  String get issueLength => 'Length is not allowed';

  @override
  String issueRangeBetween(String min, String max) {
    return 'Must be between $min and $max';
  }

  @override
  String issueRangeMin(String min) {
    return 'Must be at least $min';
  }

  @override
  String issueRangeMax(String max) {
    return 'Must be at most $max';
  }

  @override
  String get issueRange => 'Value is out of range';

  @override
  String get pairingDidNotComplete => 'Pairing did not complete.';

  @override
  String get widgetErrorRemoved => 'This widget was removed.';

  @override
  String get widgetErrorUnsupportedType =>
      'This widget type is not supported by this version of the app.';

  @override
  String get widgetErrorUnsupportedConfigurationVersion =>
      'This widget was saved by a newer version of the app.';

  @override
  String get widgetErrorInvalidConfiguration =>
      'This widget\'s settings are not valid.';

  @override
  String get widgetErrorUnknownQuery =>
      'The saved query of this widget is no longer available.';

  @override
  String get widgetErrorInvalidQuery =>
      'The saved query of this widget is not valid.';

  @override
  String get widgetErrorShapeMismatch =>
      'The saved query returns a result this widget cannot show.';

  @override
  String get widgetErrorOverflow =>
      'The result is too large to compute exactly.';

  @override
  String get widgetErrorQueryFailed => 'The saved query could not run.';

  @override
  String importRecords(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count records into $name',
      one: 'Imported 1 record into $name',
    );
    return '$_temp0';
  }

  @override
  String importCollections(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count collections',
      one: 'Imported 1 collection',
    );
    return '$_temp0';
  }

  @override
  String importStoppedAt(String place, String reason) {
    return 'Import stopped at $place: $reason Nothing was imported.';
  }

  @override
  String importStopped(String reason) {
    return 'Import stopped: $reason Nothing was imported.';
  }

  @override
  String get importPlaceHeader => 'the header';

  @override
  String importPlaceRow(int row) {
    return 'row $row';
  }

  @override
  String importPlaceCollection(int index) {
    return 'collection $index';
  }

  @override
  String get widgetNotEvaluated => 'This widget could not be evaluated.';

  @override
  String get commonYes => 'Yes';

  @override
  String get commonNo => 'No';

  @override
  String get timeNever => 'never';

  @override
  String get timeJustNow => 'just now';

  @override
  String timeMinutesAgo(int minutes) {
    return '$minutes min ago';
  }

  @override
  String timeHoursAgo(int hours) {
    return '$hours h ago';
  }

  @override
  String get devicesNeverSeen => 'Never seen';

  @override
  String get devicesNeverSynced => 'Never synced';

  @override
  String devicesSeen(String time) {
    return 'Seen $time';
  }

  @override
  String devicesSynced(String time) {
    return 'Synced $time';
  }

  @override
  String timeLeftMinutes(int minutes) {
    return 'about $minutes min left';
  }

  @override
  String timeLeftSeconds(int seconds) {
    return 'about $seconds s left';
  }

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonClose => 'Close';

  @override
  String get commonDone => 'Done';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonTryAgain => 'Try again';

  @override
  String get commonShow => 'Show';

  @override
  String get commonClear => 'Clear';

  @override
  String get commonRename => 'Rename';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonBack => 'Back';

  @override
  String get commonOk => 'OK';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonNone => 'None';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonRequired => 'Required';

  @override
  String get commonDetails => 'Details';

  @override
  String get commonNew => 'New';

  @override
  String get themeChoose => 'Choose…';

  @override
  String themeSearchOptions(int count) {
    return 'Search $count options';
  }

  @override
  String themeTypeToSearchOptions(int count) {
    return 'Type to search $count options';
  }

  @override
  String themeMatchesFooter(int matches, int total) {
    return '$matches of $total · ↑↓ to move, Enter to pick';
  }

  @override
  String get themeSearch => 'Search';

  @override
  String get themeMore => 'More';

  @override
  String get themeSet => 'Set';

  @override
  String get themeVoice => 'Voice';

  @override
  String themeFilledByVoice(String field) {
    return '$field, filled by voice';
  }

  @override
  String get themeDefault => 'Default';

  @override
  String get themeNeeded => 'Needed';

  @override
  String get queryPresetDailyTotal => 'Daily total';

  @override
  String get queryPresetMonthlyTotal => 'Monthly total';

  @override
  String get queryPresetCountPerDay => 'Count per day';

  @override
  String get queryPresetLatestValues => 'Latest values';

  @override
  String get queryBlockerOperand => 'Choose the field to aggregate.';

  @override
  String get queryBlockerCategoryOrPeriod =>
      'Choose the category or period field.';

  @override
  String get queryBlockerAxes => 'Choose both axes.';

  @override
  String get queryBlockerCategory => 'Choose the category field.';

  @override
  String get queryBlockerFilterValue =>
      'Enter the filter value or clear the filter.';

  @override
  String get queryMadeElsewhere => 'Made elsewhere; not editable here.';

  @override
  String get queryAnExpression => 'an expression';

  @override
  String queryDescAggregationOf(String aggregation, String field) {
    return '$aggregation of $field';
  }

  @override
  String queryDescSeries(String x, String y) {
    return 'each record, $x against $y';
  }

  @override
  String queryDescBy(String field) {
    return 'by $field';
  }

  @override
  String get queryDescPerDay => 'per day';

  @override
  String get queryDescPerWeek => 'per week';

  @override
  String get queryDescPerMonth => 'per month';

  @override
  String get queryDescPerYear => 'per year';

  @override
  String get queryDescFiltered => 'filtered';

  @override
  String queryDescLimit(int limit) {
    return 'limit $limit';
  }

  @override
  String get queryDescEveryRecord => 'Every record';

  @override
  String get queryAggCount => 'Count';

  @override
  String get queryAggSum => 'Sum';

  @override
  String get queryAggAverage => 'Average';

  @override
  String get queryAggMin => 'Min';

  @override
  String get queryAggMax => 'Max';

  @override
  String get queryGroupBy => 'Group by';

  @override
  String get queryPeriodDay => 'Day';

  @override
  String get queryPeriodWeek => 'Week';

  @override
  String get queryPeriodMonth => 'Month';

  @override
  String get queryPeriodYear => 'Year';

  @override
  String get queryCategoryField => 'Category field';

  @override
  String get queryDateField => 'Date field';

  @override
  String get queryAggregation => 'Aggregation';

  @override
  String get queryAggregationNeedsGroup =>
      'Choose a Group by period to aggregate';

  @override
  String get queryOperandField => 'Field to aggregate';

  @override
  String get queryOutputScale => 'Output scale';

  @override
  String get queryRoundingPolicy => 'Rounding policy';

  @override
  String get queryRoundingHalfEven => 'Half to even';

  @override
  String get queryRoundingRejectInexact => 'Reject inexact';

  @override
  String get queryXAxis => 'X axis';

  @override
  String get queryYAxis => 'Y axis';

  @override
  String get queryFilterField => 'Field';

  @override
  String get queryFilterOperator => 'Operator';

  @override
  String get queryFilterValue => 'Value';

  @override
  String get queryOpEquals => 'equals';

  @override
  String get queryOpIsNot => 'is not';

  @override
  String get queryOpGreaterThan => 'greater than';

  @override
  String get queryOpAtLeast => 'at least';

  @override
  String get queryOpLessThan => 'less than';

  @override
  String get queryOpAtMost => 'at most';

  @override
  String queryUsedBy(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Used by $count widgets',
      one: 'Used by 1 widget',
      zero: 'Used by no widgets',
    );
    return '$_temp0';
  }

  @override
  String get queryNameRequired => 'Give the query a name.';

  @override
  String get queryName => 'Query name';

  @override
  String get queryNotEditable =>
      'This query was made elsewhere and cannot be edited here.';

  @override
  String get queryEditTitle => 'Edit query';

  @override
  String get querySaveAsNewTitle => 'Save as new query';

  @override
  String queryCopyName(String name) {
    return '$name copy';
  }

  @override
  String get queryEditThis => 'Edit this query';

  @override
  String get querySaveAsNew => 'Save as new';

  @override
  String get queryDefaultName => 'Widget query';

  @override
  String get modelCardTitle => 'Voice models';

  @override
  String get modelTagNotDownloaded => 'Not downloaded';

  @override
  String get modelTagDownloading => 'Downloading';

  @override
  String get modelTagReconnecting => 'Reconnecting';

  @override
  String get modelTagVerifying => 'Verifying';

  @override
  String get modelTagPaused => 'Paused';

  @override
  String get modelTagFailed => 'Failed';

  @override
  String get modelTagReady => 'Ready';

  @override
  String get modelRoleSpeech => 'Speech recognition';

  @override
  String get modelRoleUnderstanding => 'Understanding';

  @override
  String get modelRoleSpeechInSentence => 'speech recognition';

  @override
  String get modelRoleUnderstandingInSentence => 'understanding';

  @override
  String get modelAllLanguages => 'All languages';

  @override
  String modelSummaryTotal(String language, String total) {
    return '$language · $total total';
  }

  @override
  String modelSummaryProgress(String language, String done, String total) {
    return '$language · $done of $total';
  }

  @override
  String modelSummarySize(String language, String total) {
    return '$language · $total';
  }

  @override
  String modelSummaryPaused(String language, String done, String total) {
    return '$language · paused at $done of $total';
  }

  @override
  String modelSummaryStopped(String language, String done) {
    return '$language · stopped at $done';
  }

  @override
  String modelSummaryCheckFailed(String language) {
    return '$language · check failed';
  }

  @override
  String modelSummaryReady(String language, String total) {
    return '$language · $total used on this phone';
  }

  @override
  String modelRowProgress(String stored, String size) {
    return '$stored of $size';
  }

  @override
  String get modelRowChecking => 'Checking';

  @override
  String modelRowDamaged(String size) {
    return '$size · damaged';
  }

  @override
  String get modelWifiRecommended => 'Wi-Fi recommended';

  @override
  String modelNeeds(String needed) {
    return 'Needs $needed';
  }

  @override
  String modelNeedsWithFree(String needed, String free) {
    return 'Needs $needed · $free free on this phone';
  }

  @override
  String modelDownload(String size) {
    return 'Download $size';
  }

  @override
  String get modelPause => 'Pause';

  @override
  String get modelResume => 'Resume';

  @override
  String get modelCancelAndDelete => 'Cancel and delete';

  @override
  String modelPercent(int percent) {
    return '$percent%';
  }

  @override
  String modelTimeLeft(String time) {
    return 'about $time';
  }

  @override
  String get modelReconnectingTitle => 'Connection lost — reconnecting…';

  @override
  String get modelReconnectingResumes =>
      'The download resumes where it stopped.';

  @override
  String get modelReconnectingKeepOpen =>
      'Leaving Fi can pause the network. Keep it open to finish faster.';

  @override
  String get modelVerifyingTitle => 'Checking downloaded data…';

  @override
  String get modelResumesFromHere => 'resumes from here';

  @override
  String get modelNetworkTitle => 'No connection';

  @override
  String get modelNetworkLine =>
      'Couldn\'t reach the download server. Check your Wi-Fi, then retry. Downloaded data is kept.';

  @override
  String get modelStorageTitle => 'Not enough storage';

  @override
  String modelStorageLine(String needed) {
    return 'Free up $needed on this phone, then retry.';
  }

  @override
  String get modelDamagedTitle => 'Downloaded file is damaged';

  @override
  String modelDamagedLine(String role, String size) {
    return 'The $role model failed its check. Retry downloads it again ($size).';
  }

  @override
  String get modelIoTitle => 'Couldn\'t save the download';

  @override
  String get modelIoLine => 'Storage error. Retry; downloaded data is kept.';

  @override
  String get modelCancelDialogTitle => 'Cancel download?';

  @override
  String modelCancelDialogBody(String done) {
    return 'Downloaded data ($done) will be deleted.';
  }

  @override
  String get modelCancelDialogConfirm => 'Cancel download';

  @override
  String get modelCancelDialogKeep => 'Keep downloading';

  @override
  String get modelDeleteDialogTitle => 'Delete voice models?';

  @override
  String modelDeleteDialogBody(String size) {
    return 'Frees $size. Voice fill won’t work until you download them again.';
  }

  @override
  String get modelKeepModels => 'Keep models';

  @override
  String get modelRedownloadDialogTitle => 'Re-download voice models?';

  @override
  String modelRedownloadDialogBody(String size) {
    return 'The models are deleted and downloaded again ($size).';
  }

  @override
  String get modelRedownloadDialogConfirm => 'Re-download';

  @override
  String get modelOfferTitle => 'Download voice models';

  @override
  String modelOfferLine(String language, String size) {
    return '$language · $size total, one time. Everything runs on this phone.';
  }

  @override
  String get modelOnMobileData => 'You\'re on mobile data';

  @override
  String get modelOnWifi => 'You\'re on Wi-Fi';

  @override
  String get modelStorage => 'Storage';

  @override
  String modelFree(String size) {
    return '$size free';
  }

  @override
  String get modelLater => 'Later';

  @override
  String get modelDownloadingTitle => 'Downloading voice models';

  @override
  String get modelReconnectingShort => 'Reconnecting…';

  @override
  String get modelPausedTitle => 'Download paused';

  @override
  String modelProgressLine(String done, String total, int percent) {
    return '$done of $total · $percent%';
  }

  @override
  String get modelKeepFilling =>
      'Keep filling by hand. The mic turns on when it\'s ready.';

  @override
  String get modelPauseDownload => 'Pause download';

  @override
  String get modelHide => 'Hide';

  @override
  String modelErrorLine(String title, String line) {
    return '$title. $line';
  }

  @override
  String get helpFieldRequiredTitle => 'Required';

  @override
  String get helpFieldRequiredBody =>
      'A required field must hold a value. New records cannot be saved without it.\n\nTurning this on for a field that existing records do not have marks those records invalid until you fill the field in. They are never deleted, and you can still open and repair them from the record list.\n\nSetting a default avoids that: the default counts as the value for every record that does not have one.';

  @override
  String get helpFieldDefaultTitle => 'Default';

  @override
  String get helpFieldDefaultBody =>
      'The value used when a record does not supply one. It fills new records as you create them, and it satisfies the Required rule for existing records that lack the field.\n\nLeave it empty if every record should state its own value.';

  @override
  String get helpFieldDecimalScaleTitle => 'Decimal scale';

  @override
  String get helpFieldDecimalScaleBody =>
      'How many digits are kept after the decimal point. Scale 2 stores 10.25 exactly; scale 0 stores whole numbers only.\n\nValues are stored as exact numbers, never as floating point, so sums and averages do not drift. The scale cannot be changed once records hold a value for this field.';

  @override
  String get helpFieldMinMaxTitle => 'Minimum and Maximum';

  @override
  String get helpFieldMinMaxBody =>
      'The range a value is allowed to fall in, inclusive on both ends. A record outside the range is rejected when you save it.\n\nLeave either box empty for no limit on that side.';

  @override
  String get helpFieldMinMaxLengthTitle => 'Minimum and Maximum length';

  @override
  String get helpFieldMinMaxLengthBody =>
      'How short and how long the text may be, counted in characters.\n\nLeave either box empty for no limit on that side.';

  @override
  String get helpFieldMultilineTitle => 'Multiline';

  @override
  String get helpFieldMultilineBody =>
      'Shows this text field as a box that accepts line breaks instead of a single line. It changes how the field is edited, not what may be stored in it.';

  @override
  String get helpFieldSliderTitle => 'Show as slider';

  @override
  String get helpFieldSliderBody =>
      'Shows this number field as a slider that moves from the minimum to the maximum, with the picked value beside it. Until a value is picked the track shows no thumb; tap or drag it to pick one, and the number appears beside it.\n\nA row of numbers under the track shows the scale: every step when they all fit, otherwise only the minimum and the maximum at the two ends.\n\nStep sets how far each move goes, for example 10 on a 0 to 100 range. Leave it empty for whole steps of 1. The step must divide the distance from the minimum to the maximum exactly, so the last position lands on the maximum.\n\nAvailable only once both a minimum and a maximum are set. It changes how the field is edited, not what is stored: queries, charts, and the record list still see a number.';

  @override
  String get helpWidgetTypeTitle => 'Widget type';

  @override
  String get helpWidgetTypeBody =>
      'What the widget draws.\n\nNumber shows one aggregated value, such as a total or a count. Line chart draws a value over time. Bar chart compares one value across categories. Scatter plot places one point per record using two fields as the axes.';

  @override
  String get helpWidgetUseSavedQueryTitle => 'Use a saved query';

  @override
  String get helpWidgetUseSavedQueryBody =>
      'On, the widget reuses a query you already saved, and editing that query updates every widget that uses it.\n\nOff, you build the query here and it is saved under the widget title.';

  @override
  String get helpWidgetAggregationTitle => 'Aggregation';

  @override
  String get helpWidgetAggregationBody =>
      'How many records are reduced to one number.\n\nCount counts records and needs no field. Sum, Average, Min, and Max each read one numeric field, chosen below.\n\nWith a Group by period the aggregation is computed once per period rather than once over everything.';

  @override
  String get helpWidgetOperandFieldTitle => 'Field to aggregate';

  @override
  String get helpWidgetOperandFieldBody =>
      'The numeric field the aggregation reads. Only number, decimal, and duration fields can be summed or averaged.\n\nCount ignores this because it counts records rather than values.';

  @override
  String get helpWidgetOutputScaleTitle => 'Output scale';

  @override
  String get helpWidgetOutputScaleBody =>
      'How many decimal places the average keeps. An average rarely divides evenly, so the result must state its own precision instead of inheriting one.';

  @override
  String get helpWidgetRoundingTitle => 'Rounding policy';

  @override
  String get helpWidgetRoundingBody =>
      'What happens when the average does not fit the output scale exactly.\n\nHalf to even rounds to the nearest value and breaks ties toward the even digit, which keeps long runs of numbers unbiased. Reject inexact refuses to show a result rather than round, so you never read a rounded number as an exact one.';

  @override
  String get helpWidgetGroupByTitle => 'Group by';

  @override
  String get helpWidgetGroupByBody =>
      'Buckets records by calendar period — day, week, month, or year — using the date field you choose, and computes the aggregation once per bucket. Each bucket becomes one point or one bar.\n\nChoose None to aggregate over everything at once, or to group by a category instead of a period.';

  @override
  String get helpWidgetDateFieldTitle => 'Date field';

  @override
  String get helpWidgetDateFieldBody =>
      'The date or timestamp used to decide which period a record falls into. Weeks start on Monday and periods are computed in UTC.';

  @override
  String get helpWidgetCategoryFieldTitle => 'Category field';

  @override
  String get helpWidgetCategoryFieldBody =>
      'The field whose values become the categories along the axis: one bar or one point per distinct value. Records sharing a value are aggregated together.';

  @override
  String get helpWidgetXAxisTitle => 'X axis';

  @override
  String get helpWidgetXAxisBody =>
      'The field plotted horizontally, one point per record. No aggregation happens: each record keeps its own point.';

  @override
  String get helpWidgetYAxisTitle => 'Y axis';

  @override
  String get helpWidgetYAxisBody =>
      'The numeric field plotted vertically, one point per record.';

  @override
  String get helpWidgetFilterTitle => 'Filter';

  @override
  String get helpWidgetFilterBody =>
      'Restricts the widget to records matching one condition, such as amount greater than 10 or category equals Migraine.\n\nLeave the field set to None to include every record. The filter changes what the widget shows; it never hides or deletes records anywhere else.';

  @override
  String get helpWidgetUnitSuffixTitle => 'Unit suffix';

  @override
  String get helpWidgetUnitSuffixBody =>
      'Text shown after the value, such as EUR or mg. It is display only: the exact number is unchanged and the suffix is never stored with the data.';

  @override
  String get helpWidgetShowPointsTitle => 'Show points';

  @override
  String get helpWidgetShowPointsBody =>
      'Draws a marker at every data point on the line, which helps when there are only a few points or when gaps matter.';

  @override
  String get helpWidgetAxisLabelTitle => 'Y axis label';

  @override
  String get helpWidgetAxisLabelBody =>
      'Text shown beside the vertical axis to name what is being measured, such as \"Hours\" or \"EUR\". Leave it empty for no label.';

  @override
  String get helpWidgetBarWidthTitle => 'Bar width';

  @override
  String get helpWidgetBarWidthBody =>
      'How wide each bar is drawn, in logical pixels. Leave it empty to let the chart size the bars to fit.';

  @override
  String get helpWidgetPointRadiusTitle => 'Point radius';

  @override
  String get helpWidgetPointRadiusBody =>
      'How large each plotted point is drawn, in logical pixels. Leave it empty for the default size.';

  @override
  String get helpComputedFieldsTitle => 'Computed fields';

  @override
  String get helpComputedFieldsBody =>
      'A computed field derives its value from other fields of the same record, such as amount × rate or ended − started. It is recalculated on this device whenever it is read, so it is never out of date, and only its definition is synchronised, never its values.\n\nUse one for totals with the sign removed, products like price × quantity, or the time between two dates. Queries and widgets can use it like any other field, and editing it changes every query and widget that uses it.';

  @override
  String get helpComputedFieldResultTitle => 'Result type';

  @override
  String get helpComputedFieldResultBody =>
      'The result type is worked out from the expression; you never pick it.\n\n+ and − need both sides to have the same number of decimals. × adds the decimals of both sides (scale 2 × scale 3 gives scale 5). Whole numbers and decimals cannot be mixed in +, − or ×; turn the number into a decimal instead. Subtracting two dates gives a duration.\n\n÷ always gives a decimal at the scale you choose. \"Round half to even\" rounds the last digit; \"Reject inexact\" leaves the value empty when the answer does not fit exactly.\n\nIf any field used is empty for a record, the result is empty for that record (\"may be empty\").';

  @override
  String get helpQuerySavedQueriesTitle => 'Saved queries';

  @override
  String get helpQuerySavedQueriesBody =>
      'A named query that widgets can reference. Editing one here updates every widget that uses it; the editor states how many widgets that is before you save.\n\nDeleting a query does not delete any record.';

  @override
  String get helpPairingStartPairingTitle => 'Start pairing';

  @override
  String get helpPairingStartPairingBody =>
      'Makes this device discoverable to nearby devices for a short window so the two can exchange trust.\n\nBoth devices must be nearby and on the same network, and both must have pairing on. Nothing is shared until you confirm the same six-digit code on both screens.';

  @override
  String get helpPairingSingleInitiatorTitle => 'Only one device connects';

  @override
  String get helpPairingSingleInitiatorBody =>
      'Both devices see each other, but only one may tap Connect. If both tap, the two attempts collide and the pairing fails.\n\nPick either device, tap Connect there, and let the other one wait.';

  @override
  String get helpDiscoverableTitle => 'Discoverable';

  @override
  String get helpDiscoverableBody =>
      'When on, this device announces itself to your paired devices on the local network and looks for their announcements, so they find each other automatically.\n\nWhen off, it neither announces nor looks. Paired devices can still connect while their address is known, for example a session that is already open or one that dials this device, but a device whose address changed will not be found again until you turn this back on.\n\nPairing a new device is not affected: it uses its own short announcement.';

  @override
  String get helpSyncEnabledTitle => 'Sync with paired devices';

  @override
  String get helpSyncEnabledBody =>
      'When on, this device connects to your paired devices and keeps the dataset in sync with them.\n\nWhen off, sync is paused: open sessions close, this device stops connecting, and connections from paired devices are refused. Your pairings and data are kept, and changes sync again once you turn this back on.\n\nPairing a new device still works while sync is paused.';

  @override
  String helpAboutTooltip(String title) {
    return 'About $title';
  }

  @override
  String get bootResetLeadError =>
      'This device\'s local data cannot be opened by this version of the app. Resetting it lets you create a new dataset or join one from another device.';

  @override
  String get recoveryResetLead =>
      'Recovery needs one of your other devices. Resetting instead abandons the dataset recorded on this device; if you own no other device holding it, the set-aside copy is kept on disk but this app cannot read it.';

  @override
  String get bootRetryAfterUnlock => 'Retry after unlocking';

  @override
  String get shellResetData => 'Reset this device\'s data';

  @override
  String get bootServiceUnavailable =>
      'The local collection service is unavailable.';

  @override
  String get recoveryNeedsDevice => 'Recovery needs another device';

  @override
  String get onboardQuarantined =>
      'Data found on this device was set aside because its dataset record was missing. Nothing was deleted: joining the same dataset from another device restores it.';

  @override
  String get onboardCreating => 'Creating…';

  @override
  String sidebarPairedSummary(int count, String reach) {
    return '$count paired · $reach';
  }

  @override
  String get sidebarNoneNearby => 'none nearby';

  @override
  String sidebarConnectedCount(int count) {
    return '$count connected';
  }

  @override
  String get devicesStatusOffline => 'Offline';

  @override
  String get devicesStatusLooking => 'Looking for paired devices';

  @override
  String get devicesStatusSearching => 'Searching';

  @override
  String get devicesStatusConnected => 'Connected';

  @override
  String get devicesStatusSyncing => 'Syncing';

  @override
  String get devicesStatusSynced => 'Synced';

  @override
  String get devicesStatusError => 'Error';

  @override
  String get devicesStatusPaused => 'Paused';

  @override
  String get devicesStatusRevoked => 'Revoked';

  @override
  String get devicesIntro =>
      'Devices you trust sync this dataset directly with each other.';

  @override
  String devicesRotationError(String error) {
    return 'The device was revoked, but the discovery secret could not be rotated: $error';
  }

  @override
  String get devicesRetryRotation => 'Retry rotation';

  @override
  String get devicesOtherDevice => 'the other device';

  @override
  String devicesTrustedHeading(int count) {
    return 'Trusted devices · $count';
  }

  @override
  String get devicesPairDevice => 'Pair device';

  @override
  String get devicesThisDevice => 'This device';

  @override
  String get devicesActions => 'Device actions';

  @override
  String get devicesRevokeUnpair => 'Revoke / unpair';

  @override
  String get devicesLogCopied => 'Log copied';

  @override
  String get devicesRenameTitle => 'Rename device';

  @override
  String devicesRevokeTitle(String name) {
    return 'Revoke $name?';
  }

  @override
  String get devicesRevokeBody =>
      'It stops syncing with this device right away. It stays in the list as revoked, and you can pair it again later.';

  @override
  String get devicesRevoke => 'Revoke';

  @override
  String get devicesDeleteTitle => 'Delete revoked device?';

  @override
  String devicesDeleteBody(String name) {
    return 'Removes $name from this list. It can be paired again.';
  }

  @override
  String get devicesConnections => 'Connections';

  @override
  String get devicesDiscoverable => 'Discoverable';

  @override
  String get devicesDiscoverableSubtitle =>
      'Announce this device to paired devices on the local network.';

  @override
  String get devicesSyncEnabled => 'Sync with paired devices';

  @override
  String get devicesSyncEnabledSubtitle =>
      'Connect to and accept connections from paired devices.';

  @override
  String get devicesNoneYet => 'No devices paired yet';

  @override
  String get devicesNoneBodyPhone =>
      'Start pairing on both devices while they\'re nearby.';

  @override
  String get devicesNoneBody =>
      'Start pairing on both devices while they\'re nearby. Pairing turns itself off after 2 minutes.';

  @override
  String devicesPairedBanner(String name) {
    return 'Paired with $name. The first sync starts automatically.';
  }

  @override
  String get devicesPairAnother => 'Pair another';

  @override
  String get devicesDismiss => 'Dismiss';

  @override
  String get devicesNetworkingMissing => 'Networking is not set up';

  @override
  String get devicesIdCopied => 'ID copied';

  @override
  String get devicesCopyId => 'Copy ID';

  @override
  String get devicesResetBody =>
      'Abandon the dataset here to create a new one or join another device\'s. Your device identity is kept.';

  @override
  String get devicesFactState => 'State';

  @override
  String get devicesFactEndpoint => 'Endpoint';

  @override
  String get devicesFactLastAttempt => 'Last attempt';

  @override
  String get devicesFactSyncPort => 'Sync port';

  @override
  String get devicesNotBound => 'not bound';

  @override
  String get devicesReconnect => 'Reconnect';

  @override
  String get devicesCopyLog => 'Copy log';

  @override
  String devicesLogHeading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count events',
      one: '1 event',
    );
    return 'Connection log · $_temp0';
  }

  @override
  String get devicesLogAll => 'All';

  @override
  String get devicesLogPairing => 'Pairing';

  @override
  String get devicesLogPeer => 'Peer';

  @override
  String get devicesNoEvents => 'No events.';

  @override
  String get pairingTitle => 'Pair a device';

  @override
  String get pairingIdleBody =>
      'Pairing is off. Start it only when both devices are nearby.';

  @override
  String get pairingStart => 'Start pairing';

  @override
  String get pairingDiscoveryOffNote =>
      'Discovery is off — pairing still works.';

  @override
  String get pairingAlreadyPaired => 'All nearby devices are already paired.';

  @override
  String get pairingNoCandidates => 'No nearby pairing candidates yet.';

  @override
  String get pairingConnect => 'Connect';

  @override
  String get pairingStop => 'Stop';

  @override
  String get pairingConnecting => 'Connecting securely…';

  @override
  String get pairingSuccess => 'Device paired successfully.';

  @override
  String get pairingAnother => 'Pair another device';

  @override
  String get pairingDifferentDevice => 'Pair a different device';

  @override
  String get pairingKeyringLocked =>
      'Your login keyring is locked, so this device could not save the pairing. Unlock the keyring, then retry — the other device may already show this one as paired.';

  @override
  String get pairingResetLead =>
      'To join the other device\'s dataset, this device\'s local data must be reset first.';

  @override
  String get resetTitle => 'Reset this device\'s data?';

  @override
  String resetTrustedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count trusted devices are kept and can be paired again.',
      one: '1 trusted device is kept and can be paired again.',
      zero: 'No trusted devices are recorded.',
    );
    return '$_temp0';
  }

  @override
  String get resetConfirm => 'Reset data';

  @override
  String get fieldTypeText => 'Text';

  @override
  String get fieldTypeInteger => 'Integer';

  @override
  String get fieldTypeDecimal => 'Decimal';

  @override
  String get fieldTypeBoolean => 'Boolean';

  @override
  String get fieldTypeDate => 'Date';

  @override
  String get fieldTypeDateTime => 'Date & time';

  @override
  String get fieldTypeDuration => 'Duration';

  @override
  String get fieldTypeChoice => 'Choice';

  @override
  String get inputTrue => 'True';

  @override
  String get inputFalse => 'False';

  @override
  String get inputPickDate => 'Pick a date';

  @override
  String get inputPickDateTime => 'Pick date & time';

  @override
  String get inputToday => 'Today';

  @override
  String get inputNow => 'Now';

  @override
  String get inputEmpty => 'Empty';

  @override
  String get collectionsImportCsv => 'Import CSV…';

  @override
  String get collectionsExportCsv => 'Export CSV';

  @override
  String get collectionsExportJson => 'Export JSON';

  @override
  String get collectionsDeleteEllipsis => 'Delete…';

  @override
  String get collectionsSortLastEdited => 'Last edited';

  @override
  String get collectionsSortName => 'Name';

  @override
  String get collectionsSort => 'Sort';

  @override
  String get collectionsTitle => 'Collections';

  @override
  String get collectionsImportExport => 'Import and export';

  @override
  String get collectionsImportJson => 'Import JSON…';

  @override
  String get collectionsExportAll => 'Export all';

  @override
  String get collectionsExportSelected => 'Export selected…';

  @override
  String get collectionsNewCollection => 'New collection';

  @override
  String get collectionsEmpty =>
      'Create a collection to start shaping your data.';

  @override
  String collectionsRecordCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records',
      one: '1 record',
    );
    return '$_temp0';
  }

  @override
  String collectionsFieldCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fields',
      one: '1 field',
    );
    return '$_temp0';
  }

  @override
  String collectionsIncomplete(int count) {
    return '$count incomplete';
  }

  @override
  String collectionsEditedLower(String time) {
    return 'edited $time';
  }

  @override
  String get collectionsActions => 'Collection actions';

  @override
  String collectionsExportedTo(String name) {
    return 'Exported to $name';
  }

  @override
  String get collectionsExportTitle => 'Export collections';

  @override
  String collectionsDeleteTitle(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String get collectionsDeleteGeneric =>
      'Its records, widgets and saved queries are deleted with it.';

  @override
  String get collectionsRenameTitle => 'Rename collection';

  @override
  String get collectionsDescription => 'Description';

  @override
  String collectionsCopyName(String name) {
    return '$name (copy)';
  }

  @override
  String collectionsContentsRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records',
      one: '1 record',
    );
    return '$_temp0';
  }

  @override
  String collectionsContentsWidgets(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count widgets',
      one: '1 widget',
    );
    return '$_temp0';
  }

  @override
  String collectionsContentsSavedQueries(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count saved queries',
      one: '1 saved query',
    );
    return '$_temp0';
  }

  @override
  String get collectionsContentsEmpty => 'This collection is empty.';

  @override
  String collectionsContentsJoin(String list, String last) {
    return '$list and $last';
  }

  @override
  String collectionsContentsDeleted(int total, String list) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$list are deleted with it.',
      one: '$list is deleted with it.',
    );
    return '$_temp0';
  }

  @override
  String get recordsBackToCollections => 'Back to collections';

  @override
  String get recordsBreadcrumb => 'Collections  /';

  @override
  String get recordsSchema => 'Schema';

  @override
  String get recordsQueries => 'Queries';

  @override
  String get recordsSelect => 'Select';

  @override
  String get recordsNewRecord => 'New record';

  @override
  String get recordsMoreActions => 'More actions';

  @override
  String get recordsSelectRecords => 'Select records';

  @override
  String get recordsCollectionActions => 'Collection actions…';

  @override
  String get recordsSection => 'Records';

  @override
  String get recordsNewestFirst => 'Newest first';

  @override
  String get recordsEmpty => 'No records yet.';

  @override
  String get recordsFab => 'Record';

  @override
  String recordsMoreFields(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '+ $count more fields',
      one: '+ 1 more field',
    );
    return '$_temp0';
  }

  @override
  String get recordsIncomplete => 'Incomplete';

  @override
  String get recordsDeleteRecord => 'Delete record';

  @override
  String get recordsSchemaTitle => 'Collection schema';

  @override
  String get recordsReorderPhone => 'Long-press to reorder';

  @override
  String get recordsReorderDesktop => 'Drag to reorder · click a field to edit';

  @override
  String get recordsAddField => 'Add field';

  @override
  String recordsComputedNewer(String version) {
    return 'Made by a newer version (expression v$version); not editable here';
  }

  @override
  String get recordsComputedUnsupported =>
      'Uses operations this editor does not offer; not editable here';

  @override
  String get recordsMayBeEmpty => 'may be empty';

  @override
  String get recordsEditComputed => 'Edit computed field';

  @override
  String get recordsRemoveComputed => 'Remove computed field';

  @override
  String get recordsComputedSheetTitle => 'Computed fields & queries';

  @override
  String get recordsComputedFields => 'Computed fields';

  @override
  String get recordsComputedFieldsHint =>
      'Calculated per record from other fields.';

  @override
  String get recordsAddComputed => 'Add computed field';

  @override
  String get recordsSavedQueries => 'Saved queries';

  @override
  String get recordsSavedQueriesHint =>
      'Aggregates across records. Widgets can reuse them.';

  @override
  String get recordsEditQuery => 'Edit query';

  @override
  String get recordsRemoveQuery => 'Remove query';

  @override
  String recordsUsedBy(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'used by $count widgets',
      one: 'used by 1 widget',
      zero: 'used by no widgets',
    );
    return '$_temp0';
  }

  @override
  String recordsSelected(int count) {
    return '$count selected';
  }

  @override
  String recordsInCollection(String name) {
    return 'in $name';
  }

  @override
  String get recordsSelectAll => 'Select all';

  @override
  String get recordsEditField => 'Edit field';

  @override
  String recordsBatchDeleteTitle(int count) {
    return 'Delete $count records?';
  }

  @override
  String get recordsBatchDeleteBody =>
      'Every selected record is deleted in one step.';

  @override
  String recordsDeletedSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Deleted $count records',
      one: 'Deleted 1 record',
    );
    return '$_temp0';
  }

  @override
  String recordsBatchSetTitle(String field, int count) {
    return 'Set $field on $count records?';
  }

  @override
  String get recordsBatchSetBody =>
      'Every selected record is updated in one step.';

  @override
  String recordsBatchEditTitle(int count) {
    return 'Edit field on $count records';
  }

  @override
  String get recordsField => 'Field';

  @override
  String get recordsContinue => 'Continue';

  @override
  String get recordDiscardTitle => 'Discard this record?';

  @override
  String get recordDiscardBody =>
      'Voice processing will stop and the fields you changed will be lost.';

  @override
  String get recordDiscard => 'Discard';

  @override
  String get recordKeepEditing => 'Keep editing';

  @override
  String get recordDeleteTitle => 'Delete this record?';

  @override
  String get recordDeleteBody => 'It is removed from the collection.';

  @override
  String recordCreated(String date) {
    return 'created $date';
  }

  @override
  String get recordEditTitle => 'Edit record';

  @override
  String recordTitleNeeded(String title, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fields needed',
      one: '1 field needed',
    );
    return '$title · $_temp0';
  }

  @override
  String get recordFooterHint => '* Required · Ctrl+Enter to save';

  @override
  String get recordDeleteRecordEllipsis => 'Delete record…';

  @override
  String get recordSave => 'Save record';

  @override
  String get recordSaveChanges => 'Save changes';

  @override
  String get recordScrollMore => 'Scroll for more columns →';

  @override
  String recordIncompleteLead(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records are missing a required field',
      one: '1 record is missing a required field',
    );
    return '$_temp0';
  }

  @override
  String recordTapToFinish(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tap one to finish.',
      one: 'Tap it to finish.',
    );
    return '$_temp0';
  }

  @override
  String recordClickToFinish(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Click one to finish.',
      one: 'Click it to finish.',
    );
    return '$_temp0';
  }

  @override
  String formCouldntSave(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Couldn\'t save. $count fields need attention.',
      one: 'Couldn\'t save. 1 field needs attention.',
    );
    return '$_temp0';
  }

  @override
  String formRequiredSemantics(String name) {
    return '$name, required';
  }

  @override
  String get formRequiredLegend => ' required';

  @override
  String get formNeeded => 'Needed to complete this record';

  @override
  String get widgetDashboard => 'Dashboard';

  @override
  String get widgetReorder => 'Reorder';

  @override
  String get widgetAdd => 'Add widget';

  @override
  String get widgetEdit => 'Edit widget';

  @override
  String get widgetEmptyDashboard =>
      'No widgets yet. Add one to summarize this collection.';

  @override
  String widgetAllRecords(String description) {
    return '$description · all records';
  }

  @override
  String get widgetTitleRequired => 'Give the widget a title.';

  @override
  String get widgetSavedQueryRequired => 'Choose a saved query.';

  @override
  String get widgetType => 'Widget type';

  @override
  String widgetTypeValue(String type) {
    return 'Widget type: $type';
  }

  @override
  String get widgetUnsupportedNotice =>
      'This build cannot render this widget. Title, query, size, and order stay editable and its configuration is preserved untouched.';

  @override
  String get widgetTitle => 'Title';

  @override
  String get widgetUseSavedQuery => 'Use a saved query';

  @override
  String get widgetSavedQuery => 'Saved query';

  @override
  String get widgetPresentation => 'Presentation';

  @override
  String widgetConfigVersionPreserved(String version) {
    return 'Configuration version $version is preserved as is.';
  }

  @override
  String get widgetSize => 'Size';

  @override
  String get widgetSizeFull => 'Full';

  @override
  String get widgetRemove => 'Remove';

  @override
  String get widgetRemoveTooltip => 'Remove widget';

  @override
  String get widgetUntitled => 'Untitled';

  @override
  String get widgetPreview => 'Preview';

  @override
  String get widgetChooseData => 'Choose the data to show';

  @override
  String get widgetSizeSmallHint => 'Small spans 1 of 4 columns.';

  @override
  String get widgetSizeMediumHint => 'Medium spans 2 of 4 columns.';

  @override
  String get widgetSizeLargeHint => 'Large spans 3 of 4 columns.';

  @override
  String get widgetSizeFullHint => 'Full spans all 4 columns.';

  @override
  String get widgetUnitSuffix => 'Unit suffix (optional)';

  @override
  String get widgetUnitSuffixHelper =>
      'Shown after the exact value, for example \"EUR\".';

  @override
  String get widgetShowPoints => 'Show points';

  @override
  String get widgetYAxisLabel => 'Y axis label (optional)';

  @override
  String get widgetBarWidth => 'Bar width (optional)';

  @override
  String get widgetPointRadius => 'Point radius (optional)';

  @override
  String get widgetTypeAggregateNumber => 'Aggregate number';

  @override
  String get widgetTypeLineChart => 'Line chart';

  @override
  String get widgetTypeBarChart => 'Bar chart';

  @override
  String get widgetTypeScatterPlot => 'Scatter plot';

  @override
  String get voiceFillByVoice => 'Fill by voice';

  @override
  String get voiceTipLine =>
      'Tap the mic below and say the details. You review before saving.';

  @override
  String get voiceDismissTip => 'Dismiss tip';

  @override
  String get voicePrimerTitle => 'Speak to fill records';

  @override
  String get voicePrivacyLine =>
      'Audio is processed on this device and never saved.';

  @override
  String get voicePrimerNext => 'Next, Android will ask for microphone access.';

  @override
  String get voiceNotNow => 'Not now';

  @override
  String get voiceContinue => 'Continue';

  @override
  String get voiceDownloadProgressLabel => 'Download progress';

  @override
  String get voiceListening => 'Listening';

  @override
  String voiceTry(String example) {
    return 'Try: “$example”';
  }

  @override
  String get voiceListeningHint =>
      'Tap stop when done, or hold the mic to talk';

  @override
  String get voiceFillingFields => 'Filling fields';

  @override
  String get voiceTranscribing => 'Transcribing';

  @override
  String get voiceTranscribed => 'Transcribed';

  @override
  String get voiceTranscribingStep => 'Transcribing…';

  @override
  String get voiceFillingFieldsStep => 'Filling fields…';

  @override
  String get voiceUsuallySeconds => 'Usually 4–8 seconds';

  @override
  String get voiceHeard => 'Heard';

  @override
  String voiceQuotedTranscript(String transcript) {
    return '“$transcript”';
  }

  @override
  String get voiceHeardCaps => 'HEARD';

  @override
  String get voiceWhatWasHeard => 'What was heard';

  @override
  String get voiceClearField => 'Clear field';

  @override
  String get voiceOrdinalFirst => '1st';

  @override
  String get voiceOrdinalSecond => '2nd';

  @override
  String get voiceOrdinalThird => '3rd';

  @override
  String voiceOrdinalOther(int n) {
    return '${n}th';
  }

  @override
  String voiceFilledCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Filled $count fields',
      one: 'Filled 1 field',
    );
    return '$_temp0';
  }

  @override
  String get voiceCheckThenSave => 'Check the fields, then save.';

  @override
  String get voiceSpeakAgain => 'Speak again';

  @override
  String voiceRound(int round, int max) {
    return '$round of $max';
  }

  @override
  String voiceNeedLine(String filled) {
    return '$filled. Say the rest, or type into the marked fields.';
  }

  @override
  String get voiceAnswerByVoice => 'Answer by voice';

  @override
  String voiceCouldntGet(String fields) {
    return 'Couldn\'t get the $fields';
  }

  @override
  String get voiceExhaustedLine =>
      'Type it in the marked field, then save. The mic still works if you want to try again.';

  @override
  String voiceUpdated(String fields) {
    return 'Updated $fields';
  }

  @override
  String get voiceSpeaking => 'Speaking';

  @override
  String get voiceMute => 'Mute spoken feedback';

  @override
  String get voiceDismiss => 'Dismiss';

  @override
  String get voiceOpenSettings => 'Open settings';

  @override
  String get voiceSettings => 'Settings';

  @override
  String get voiceErrorNoSpeechTitle => 'Didn\'t hear anything';

  @override
  String get voiceErrorNoSpeechLine =>
      'Check the mic isn\'t covered, then try again.';

  @override
  String get voiceErrorNothingMatchedTitle => 'Nothing matched';

  @override
  String get voiceErrorNothingMatchedLine =>
      'I couldn\'t match anything to this collection\'s fields. Try naming a field, like “amount 12.50”.';

  @override
  String get voiceErrorPermissionDeniedTitle => 'Microphone access is off';

  @override
  String get voiceErrorPermissionDeniedLine =>
      'Allow microphone access in Android settings to fill by voice. You can keep typing.';

  @override
  String get voiceErrorMicBusyTitle => 'Microphone is busy';

  @override
  String get voiceErrorMicBusyLine =>
      'Another app is using the microphone. Close it, then try again.';

  @override
  String get voiceErrorModelLoadFailedTitle => 'Voice model couldn\'t load';

  @override
  String get voiceErrorModelLoadFailedLine =>
      'The model file may be damaged. Retry, or re-download it in Settings.';

  @override
  String get voiceErrorLowMemoryTitle => 'Not enough memory';

  @override
  String get voiceErrorLowMemoryLine =>
      'Close other apps and try again. Your form is kept.';

  @override
  String get voiceErrorInterruptedBackgroundTitle => 'Recording stopped';

  @override
  String get voiceErrorInterruptedBackgroundLine =>
      'Fi went to the background, so recording stopped. Nothing was kept.';

  @override
  String get voiceErrorInterruptedCallTitle => 'Stopped for a call';

  @override
  String get voiceErrorInterruptedCallLine =>
      'Recording stopped when a call came in. Nothing was kept.';

  @override
  String get voiceErrorCancelledTitle => 'Stopped';

  @override
  String get voiceErrorCancelledLine => 'Nothing was kept.';

  @override
  String get voiceMicStopListening => 'Stop listening';

  @override
  String get voiceMicProcessing => 'Processing speech';

  @override
  String voiceMicDownloading(int percent) {
    return 'Voice model downloading, $percent percent';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSubtitle => 'Preferences for this computer.';

  @override
  String get settingsVoiceInput => 'Voice input';

  @override
  String get settingsMicrophone => 'Microphone';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsNetwork => 'Network';

  @override
  String settingsNetworkSummary(int first, int last, int mdns) {
    return 'Local network and tailnet · UDP $first–$last · mDNS $mdns';
  }

  @override
  String get settingsMicAccess => 'Microphone access';

  @override
  String get settingsMicAllowed => 'Allowed';

  @override
  String get settingsMicNotAllowed => 'Not allowed yet';

  @override
  String get settingsMicAsksFirst => 'Fi asks the first time you use voice.';

  @override
  String get settingsMicOff => 'Off';

  @override
  String get settingsMicTurnOn =>
      'Turn it on in Android settings to fill by voice.';

  @override
  String get settingsMicUnknown => 'Unknown';

  @override
  String get settingsAndroidSettings => 'Android settings';

  @override
  String get settingsHandsFree => 'Hands-free spoken feedback';

  @override
  String get settingsHandsFreeDetail =>
      'Speaks the “still need” question and a short confirmation';

  @override
  String settingsNotEnoughStorage(String size) {
    return 'Not enough storage: $size needed.';
  }

  @override
  String get settingsFinishVoiceFirst =>
      'Finish the voice fill in progress first.';

  @override
  String get settingsCouldntChangeModels =>
      'Couldn\'t change the voice models. Try again.';

  @override
  String get fieldEditorChipMultiline => 'Multiline';

  @override
  String get fieldEditorChipLengthLimits => 'Length limits';

  @override
  String get fieldEditorChipRange => 'Range';

  @override
  String get fieldEditorChipSlider => 'Show as slider';

  @override
  String get fieldEditorChipDateRange => 'Date range';

  @override
  String get fieldEditorChipDefaultValue => 'Default value';

  @override
  String get fieldEditorSummaryMultiline => 'multiline';

  @override
  String fieldEditorSummaryScale(int scale) {
    return '$scale dp';
  }

  @override
  String fieldEditorAtLeast(int min) {
    return 'at least $min';
  }

  @override
  String fieldEditorAtMost(int max) {
    return 'at most $max';
  }

  @override
  String fieldEditorTurnOff(String option) {
    return 'Turn off $option';
  }

  @override
  String get fieldEditorStepPositive => 'Step must be a positive whole number';

  @override
  String get fieldEditorStepDivides => 'Step must divide the range.';

  @override
  String get helpGotIt => 'Got it';

  @override
  String get fieldSummarySlider => 'slider';

  @override
  String fieldEditorDefaultExactLength(int min) {
    return 'Default must be exactly $min characters.';
  }

  @override
  String fieldEditorDefaultLengthBetween(int min, int max) {
    return 'Default must be $min–$max characters.';
  }

  @override
  String fieldEditorDefaultMinLength(int min) {
    return 'Default must be at least $min characters.';
  }

  @override
  String fieldEditorDefaultMaxLength(int max) {
    return 'Default must be at most $max characters.';
  }

  @override
  String fieldEditorDefaultBetween(String low, String high) {
    return 'Default must be between $low and $high.';
  }

  @override
  String fieldEditorDefaultAtLeast(String low) {
    return 'Default must be at least $low.';
  }

  @override
  String fieldEditorDefaultAtMost(String high) {
    return 'Default must be at most $high.';
  }

  @override
  String fieldEditorMakeRequiredTitle(String name) {
    return 'Make “$name” required?';
  }

  @override
  String fieldEditorMakeRequiredBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records have no value and will be marked incomplete.',
      one: '1 record has no value and will be marked incomplete.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorMakeRequired => 'Make required';

  @override
  String get fieldEditorKeepOptional => 'Keep optional';

  @override
  String fieldEditorDeleteOptionTitle(String label) {
    return 'Delete option “$label”?';
  }

  @override
  String fieldEditorDeleteOptionBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count records use it and keep it. It can\'t be picked for new records.',
      one:
          '1 record uses it and keeps it. It can\'t be picked for new records.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorKeepOption => 'Keep option';

  @override
  String get fieldEditorNewField => 'New field';

  @override
  String get fieldEditorName => 'Name';

  @override
  String get fieldEditorNameHint => 'e.g. note';

  @override
  String get fieldEditorType => 'Type';

  @override
  String get fieldEditorDecimalScale => 'Decimal scale';

  @override
  String get fieldEditorSliderNeedsRange =>
      'Show as slider needs a range with both ends.';

  @override
  String get fieldEditorAddField => 'Add field';

  @override
  String get fieldEditorSaveField => 'Save field';

  @override
  String get fieldEditorDeleteField => 'Delete field';

  @override
  String fieldEditorDeleteFieldTitle(String name) {
    return 'Delete field “$name”?';
  }

  @override
  String fieldEditorDeleteFieldBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Removes the field from the schema. $count records lose their value for it.',
      one:
          'Removes the field from the schema. 1 record loses its value for it.',
      zero: 'Removes the field from the schema.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorKeepField => 'Keep field';

  @override
  String fieldEditorDeleteFieldNamed(String name) {
    return 'Delete field $name';
  }

  @override
  String fieldEditorRequiredWarning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count records have no value for this field and will be marked incomplete.',
      one:
          '1 record has no value for this field and will be marked incomplete.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorMinCharacters => 'Min characters';

  @override
  String get fieldEditorMaxCharacters => 'Max characters';

  @override
  String get fieldEditorEarliest => 'Earliest';

  @override
  String get fieldEditorLatest => 'Latest';

  @override
  String get fieldEditorMinimum => 'Minimum';

  @override
  String get fieldEditorMaximum => 'Maximum';

  @override
  String get fieldEditorStepOptional => 'Step (optional)';

  @override
  String get fieldEditorDate => 'Date';

  @override
  String get fieldEditorDefault => 'Default';

  @override
  String get fieldEditorDayOfCreation => 'Day of creation';

  @override
  String get fieldEditorFixedDate => 'Fixed date';

  @override
  String get fieldEditorDays => 'days';

  @override
  String fieldEditorOptionsCount(int count) {
    return 'Options · $count';
  }

  @override
  String get fieldEditorOptionFallback => 'option';

  @override
  String get fieldEditorOptionLabel => 'Option label';

  @override
  String get fieldEditorDeleteOption => 'Delete option';

  @override
  String get fieldEditorAddOption => 'Add option';

  @override
  String fieldEditorDeletedOptionNote(String example) {
    return 'Records that already use a deleted option keep it. It shows as “$example (deleted)” and can\'t be picked for new records.';
  }

  @override
  String fieldEditorFieldIn(String collection) {
    return 'Field in $collection';
  }

  @override
  String get fieldEditorMore => 'More';

  @override
  String widgetCouldNotRender(String error) {
    return 'This widget could not be rendered: $error';
  }

  @override
  String get widgetUntitledWidget => 'Untitled widget';

  @override
  String get widgetUnsupported => 'Unsupported widget';

  @override
  String get widgetUnsupportedExplanation =>
      'This widget was created by another device or a newer version. Its configuration is preserved and can be renamed, reordered, or removed.';

  @override
  String voiceKept(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Your edits to $names were kept.',
      one: 'Your edit to $names was kept.',
    );
    return '$_temp0';
  }

  @override
  String get exprPickFieldIssue => 'Pick a field.';

  @override
  String get exprWholeNumberIssue => 'Enter a whole number.';

  @override
  String exprDecimalsIssue(int scale) {
    return 'Enter a number with at most $scale decimals.';
  }

  @override
  String get exprTypeInteger => 'Integer';

  @override
  String exprTypeDecimal(int scale) {
    return 'Decimal, scale $scale';
  }

  @override
  String get exprTypeDuration => 'Duration';

  @override
  String get exprTypeDate => 'Date';

  @override
  String get exprTypeDateTime => 'Date & time';

  @override
  String get exprTypeBoolean => 'Boolean';

  @override
  String get exprTypeText => 'Text';

  @override
  String get exprTypeChoice => 'Choice';

  @override
  String get exprTypeEmpty => 'Empty';

  @override
  String get exprSlotField => 'field?';

  @override
  String get exprSlotNumber => 'number?';

  @override
  String exprTermsMissing(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count terms still need a value',
      one: '1 term still needs a value',
    );
    return '$_temp0';
  }

  @override
  String get exprResultInvalid => 'Result: not valid, see the highlighted part';

  @override
  String get exprResultChecking => 'Result: checking…';

  @override
  String exprResultType(String type) {
    return 'Result: $type';
  }

  @override
  String exprResultTypeMaybeEmpty(String type) {
    return 'Result: $type · may be empty';
  }

  @override
  String get exprResultUnknown => 'Result: unknown';

  @override
  String get exprAbsoluteValue => 'Absolute value';

  @override
  String get exprAddOperator => 'Add operator';

  @override
  String get exprField => 'Field';

  @override
  String get exprNumber => 'Number';

  @override
  String get exprFunction => 'Function';

  @override
  String get exprDivide => 'Divide';

  @override
  String get exprAddTerm => 'Add term';

  @override
  String get exprDragTerm => 'Drag to reorder';

  @override
  String get exprRemoveTerm => 'Remove term';

  @override
  String exprCannotAdd(String right, String left) {
    return 'Can\'t add a $right to a $left.';
  }

  @override
  String exprCannotSubtract(String right, String left) {
    return 'Can\'t subtract a $right from a $left.';
  }

  @override
  String exprCannotMultiply(String left, String right) {
    return 'Can\'t multiply a $left by a $right.';
  }

  @override
  String exprCannotDivide(String left, String right) {
    return 'Can\'t divide a $left by a $right.';
  }

  @override
  String get exprPickField => 'Pick a field';

  @override
  String get exprWhole => 'Whole';

  @override
  String get exprRemoveOperator => 'Remove operator (keep the left side)';

  @override
  String get exprScale => 'Scale';

  @override
  String get exprFewerDecimals => 'Fewer decimals';

  @override
  String get exprMoreDecimals => 'More decimals';

  @override
  String get exprRoundHalfEven => 'Round half to even';

  @override
  String get exprOf => 'of';

  @override
  String get exprRemoveAbsolute => 'Remove absolute value';

  @override
  String get computedNewTitle => 'New computed field';

  @override
  String get computedEditTitle => 'Edit computed field';

  @override
  String computedInCollection(String collection) {
    return 'in $collection';
  }

  @override
  String get computedName => 'Name';

  @override
  String get computedNameHint => 'e.g. difference';

  @override
  String inputDurationHint(String first, String second) {
    return 'e.g. $first or $second';
  }

  @override
  String inputDurationUnparsed(String example) {
    return 'Use units like $example';
  }

  @override
  String voiceStillNeed(String names) {
    return 'Still need: $names';
  }

  @override
  String voiceSpokenFilled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fields filled.',
      one: '1 field filled.',
    );
    return '$_temp0 Tap Save record when ready.';
  }

  @override
  String modelSpeechLabel(String language) {
    String _temp0 = intl.Intl.selectLogic(language, {
      'es': 'Whisper Base (Spanish)',
      'other': 'Whisper Base (English)',
    });
    return '$_temp0';
  }

  @override
  String get modelOnThisPhone => 'On this phone';

  @override
  String modelOfferToDownload(String language, String size) {
    return '$language · $size to download, one time. Everything runs on this phone.';
  }

  @override
  String modelMissingTag(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count models missing',
      one: '1 model missing',
    );
    return '$_temp0';
  }

  @override
  String modelSummaryToDownload(String language, String size) {
    return '$language · $size to download';
  }

  @override
  String get modelOtherLanguages => 'Other languages';

  @override
  String get modelDeleteSpeechTitle => 'Delete this speech model?';

  @override
  String modelDeleteSpeechBody(String size, String language) {
    return 'Frees $size. $language voice input won\'t work until you download it again.';
  }

  @override
  String get modelKeepModel => 'Keep model';

  @override
  String voiceNeedsSpeechModel(String language, String lang, String size) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'Spanish',
      'other': 'English',
    });
    return 'Voice input: $language — needs $_temp0 speech model ($size)';
  }

  @override
  String get langVoiceFollows => 'Voice input follows the app language';

  @override
  String langVoiceReady(String lang) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'Spanish',
      'other': 'English',
    });
    return 'Voice input follows the app language · $_temp0 models ready';
  }

  @override
  String langVoiceOfferTitle(String lang, String size) {
    String _temp0 = intl.Intl.selectLogic(lang, {
      'es': 'Spanish',
      'other': 'English',
    });
    return 'Download $_temp0 speech model · $size';
  }

  @override
  String langVoiceOfferBody(String size) {
    return 'Voice input follows the app language. Understanding ($size) is already on this phone.';
  }

  @override
  String get langVoiceDownload => 'Download';

  @override
  String get peerNotReachable => 'Not reachable';

  @override
  String get peerCantVerify => 'Can\'t verify';

  @override
  String get peerNotFound => 'Not found on your network';

  @override
  String get peerNoAnswer => 'Didn\'t answer at its last address';

  @override
  String get peerNotRecognized => 'It no longer recognizes this device';

  @override
  String peerLastSynced(String problem, String time) {
    return '$problem · Last synced $time';
  }

  @override
  String peerNeverSynced(String problem) {
    return '$problem · Never synced';
  }

  @override
  String get peerGuidanceReach =>
      'Make sure both devices are on the same Wi-Fi and Fi is open on the other device. Fi keeps trying on its own.';

  @override
  String get peerGuidanceVerify =>
      'The other device may have been reset or may have unpaired this one. Pair again on both devices.';

  @override
  String get peerTryAgain => 'Try again';

  @override
  String get peerPairAgain => 'Pair again';

  @override
  String get peerConnectByAddress => 'Connect by address…';

  @override
  String get connectAddressTitle => 'Connect by address';

  @override
  String connectAddressLead(String name) {
    return 'Reach $name directly when it isn\'t found on the network. It must already be paired.';
  }

  @override
  String get connectAddressField => 'Address';

  @override
  String get connectAddressHelp =>
      'Find it on the other device under Settings › About › This device.';

  @override
  String get connectAddressConnect => 'Connect';

  @override
  String get connectAddressConnecting => 'Connecting…';

  @override
  String connectAddressConnected(String name) {
    return 'Connected to $name';
  }

  @override
  String get connectAddressInvalid =>
      'Enter an IPv4 address like 192.168.0.165, optionally followed by :port.';

  @override
  String get connectAddressNotLocal =>
      'Use an address on your local network or tailnet, like 192.168.x.x or 100.x.x.x.';

  @override
  String connectAddressNoAnswer(String address) {
    return 'No answer at $address. Check the address and that Fi is open on the other device.';
  }

  @override
  String connectAddressWrongDevice(String address, String name) {
    return 'The device at $address isn\'t $name.';
  }

  @override
  String get connectAddressPaused =>
      'Sync with paired devices is off. Turn it on to connect.';

  @override
  String get aboutThisDevice => 'This device';

  @override
  String get aboutNotOnLocalNetwork => 'Not on a local network or tailnet';

  @override
  String get aboutAddressCopied => 'Address copied';

  @override
  String get aboutCopyAddress => 'Copy address';

  @override
  String get devicesFailureCode => 'Failure code';

  @override
  String get aboutNetworkLan => 'LAN';

  @override
  String get aboutNetworkTailnet => 'Tailnet';

  @override
  String get modelRedownloadShort => 'Re-download';

  @override
  String get modelDeleteShort => 'Delete';

  @override
  String get modelFailedTitle => 'Download failed';

  @override
  String modelKeptLine(String done, String total) {
    return '$done of $total kept';
  }

  @override
  String get modelReconnectingResumesLong =>
      'Connection lost — the download resumes where it stopped.';

  @override
  String voiceListeningCap(int seconds) {
    return 'Stops on its own after $seconds seconds.';
  }

  @override
  String get collectionsClone => 'Clone';

  @override
  String get collectionsCloneTitle => 'Clone collection';

  @override
  String get collectionsCloneAction => 'Clone';

  @override
  String get collectionsExportLine => 'Choose what goes in the file';

  @override
  String collectionsExportCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Export $count collections',
      one: 'Export 1 collection',
    );
    return '$_temp0';
  }

  @override
  String collectionsExportCountShort(int count) {
    return 'Export $count';
  }

  @override
  String get collectionsImportGroup => 'Import';

  @override
  String get collectionsRenameHint => 'Enter to save · Esc to cancel';

  @override
  String importPlaceRowColumn(int row, String column) {
    return 'row $row, column “$column”';
  }

  @override
  String get outcomeDismiss => 'Dismiss';

  @override
  String get recordsNewValue => 'New value';

  @override
  String get recordsNewValueHelp => 'Uses the same control as the record form.';

  @override
  String recordsSetField(String field) {
    return 'Set $field';
  }

  @override
  String get recordsKeepRecords => 'Keep records';

  @override
  String recordsSetSnack(String field, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Set $field on $count records',
      one: 'Set $field on 1 record',
    );
    return '$_temp0';
  }

  @override
  String issueDateMin(String date) {
    return 'Must be on or after $date';
  }

  @override
  String issueDateMax(String date) {
    return 'Must be on or before $date';
  }

  @override
  String get collectionsExport => 'Export';

  @override
  String importPlaceHeaderColumn(String column) {
    return 'the header, column “$column”';
  }

  @override
  String get widgetMenuTooltip => 'Widget actions';

  @override
  String get widgetMenuRemove => 'Remove…';

  @override
  String widgetRemoveConfirmTitle(String title) {
    return 'Remove widget “$title”?';
  }

  @override
  String get widgetRemoveConfirmBody => 'Its saved query and the records stay.';

  @override
  String get widgetKeep => 'Keep widget';

  @override
  String get widgetMoveUp => 'Move up';

  @override
  String get widgetMoveDown => 'Move down';

  @override
  String get widgetDragToReorder => 'Drag to reorder';

  @override
  String get widgetNoRecordsMatch => 'No records match yet';

  @override
  String get widgetData => 'Data';

  @override
  String get widgetDefineHere => 'Define here';

  @override
  String get queryOnlyRecordsWhere => 'Only records where';

  @override
  String get queryOpIs => 'is';

  @override
  String queryFilterChip(String field, String operator, String value) {
    return '$field $operator $value';
  }

  @override
  String get queryAddFilter => 'Add filter';

  @override
  String get queryRemoveFilter => 'Remove filter';

  @override
  String get recordsAddQuery => 'Add query';

  @override
  String get queryNewTitle => 'New query';

  @override
  String queryUsedByApplies(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Used by $count widgets · changes apply there too',
      one: 'Used by 1 widget · changes apply there too',
    );
    return '$_temp0';
  }

  @override
  String get queryResultNow => 'Result now';

  @override
  String queryResultPoints(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count points',
      one: '1 point',
    );
    return '$_temp0';
  }

  @override
  String queryDeleteConfirmTitle(String name) {
    return 'Delete query “$name”?';
  }

  @override
  String queryDeleteConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count widgets use it and will show an error until you edit them.',
      one: '1 widget uses it and will show an error until you edit it.',
    );
    return '$_temp0';
  }

  @override
  String get queryDelete => 'Delete query';

  @override
  String get queryKeep => 'Keep query';

  @override
  String get devicesNetworkingMissingBody =>
      'This device has no identity for pairing yet.';

  @override
  String get devicesLocalNameHint => 'Name other devices see when pairing';

  @override
  String get devicesRenameSubtitle => 'Only changes the name on this device';

  @override
  String get devicesNameLabel => 'Name';

  @override
  String get devicesKeepDevice => 'Keep device';

  @override
  String get devicesKeep => 'Keep';

  @override
  String get devicesSwitchError => 'Couldn\'t change this. Try again.';

  @override
  String devicesPausedSynced(String time) {
    return 'Paused on this device · last synced $time';
  }

  @override
  String get devicesPausedNever => 'Paused on this device · never synced';

  @override
  String get sidebarSyncOff => 'sync is off';

  @override
  String get sidebarPairingOpen => 'pairing open';

  @override
  String get devicesChipPaused => 'Paused · sync with paired devices is off';

  @override
  String get devicesChipPausedShort => 'Paused · sync is off';

  @override
  String get devicesFactLastEndpoint => 'Last endpoint';

  @override
  String devicesUdpPort(int port) {
    return 'UDP $port';
  }

  @override
  String get pairingOpen => 'Pairing is open';

  @override
  String pairingTimeLeft(String time) {
    return '$time left of 2:00 · start it on the other device too';
  }

  @override
  String pairingNearby(int count) {
    return 'Nearby · $count';
  }

  @override
  String get pairingHiddenPaired =>
      'Devices you\'ve already paired are hidden.';

  @override
  String get pairingExpiredTitle => 'Pairing expired';

  @override
  String get pairingExpiredBody =>
      'Pairing closed after 2 minutes. Start it again on both devices when they\'re nearby.';

  @override
  String get pairingRejectedTitle => 'Pairing rejected';

  @override
  String get pairingRejectedBody =>
      'The code was rejected. Nothing was paired.';

  @override
  String get pairingConfirmTitle => 'Confirm the code';

  @override
  String get pairingConfirmInstruction =>
      'Check the same code shows on the other device, then confirm on both.';

  @override
  String pairingWith(String name) {
    return 'Pairing with $name';
  }

  @override
  String pairingPeerIdOf(String name) {
    return 'Device ID of $name';
  }

  @override
  String get pairingReject => 'Reject';

  @override
  String get pairingConfirm => 'Confirm';

  @override
  String get pairingSavingTrust => 'Saving trust…';

  @override
  String get pairingKeyringLine => 'Unlock your desktop keyring, then retry.';

  @override
  String get resetParagraph =>
      'This deletes the only copy of the dataset on this device. Other devices keep their copies and are not told about the reset. If this is the only device, the data is permanently lost.';

  @override
  String get resetAcknowledge => 'I understand this can\'t be undone';

  @override
  String get resetKeep => 'Keep data';

  @override
  String get setupTitle => 'Set up this device';

  @override
  String get setupLead =>
      'Your data stays on your devices. Pick how this one starts.';

  @override
  String get setupCreateTitle => 'Create a new dataset';

  @override
  String get setupCreateBody =>
      'Start fresh. You can pair other devices later.';

  @override
  String get setupCreateLocked =>
      'Not available while pairing is open. Stop pairing to create one instead.';

  @override
  String get setupJoinTitle => 'Join an existing dataset';

  @override
  String get setupJoinBody =>
      'Copy the dataset from one of your other devices.';

  @override
  String get setupJoinNeedsDataset =>
      'The other device must already have a dataset.';

  @override
  String get setupJoinOneSide =>
      'Start the connection from only one of the two devices.';

  @override
  String setupPairingStatus(String time) {
    return 'Pairing is open · $time left';
  }

  @override
  String get setupPairingWaiting =>
      'Waiting for your other device. Tap Connect on one device only.';

  @override
  String get setupStopPairing => 'Stop pairing';

  @override
  String get joinLead =>
      'Start pairing on the other device too. Tap Connect on one device only.';

  @override
  String get couldntJoinTitle => 'Couldn\'t join';

  @override
  String get couldntJoinBody =>
      'The other device has no dataset yet. Create one there first, or create one here.';

  @override
  String joiningTitleNamed(String name) {
    return 'Joining “$name”';
  }

  @override
  String get joiningTitle => 'Joining the other device';

  @override
  String joiningBodyNamed(String name) {
    return 'Copying the dataset from $name. Keep both devices open until this finishes.';
  }

  @override
  String get joiningBody =>
      'Copying the dataset from the other device. Keep both devices open until this finishes.';

  @override
  String get mismatchTitle => 'This device has a different dataset';

  @override
  String mismatchBodyNamed(String name) {
    return '“$name” uses another dataset than this device. Devices can only sync when they share the same one.';
  }

  @override
  String get mismatchBody =>
      'The other device uses another dataset than this device. Devices can only sync when they share the same one.';

  @override
  String get mismatchResetNote =>
      'To join it, reset this device\'s data first. The collections on this device will be deleted; the other device keeps its data.';

  @override
  String get resetDataEllipsis => 'Reset this device\'s data…';

  @override
  String get fatalTitle => 'Fi couldn\'t start';

  @override
  String get fatalResetBody =>
      'This device\'s local data can\'t be opened. Retrying won\'t fix it. Resetting deletes this device\'s copy; your other devices keep theirs.';

  @override
  String get fatalCopyDetails => 'Copy details';

  @override
  String get fatalDetailsCopied => 'Details copied';

  @override
  String get recoveringTitle => 'Recovering this device\'s data';

  @override
  String get recoveringBody =>
      'Fi is getting the dataset back from your other devices. Keep them open.';

  @override
  String get recoveryNeedsDeviceBody =>
      'This device\'s copy of the dataset is damaged. Open Fi on a paired device on the same network to restore it, or reset.';

  @override
  String get deferredLockedTitle =>
      'Sync is off: the desktop keyring is locked';

  @override
  String get deferredLockedBody =>
      'Fi keeps this device\'s keys in the desktop keyring. Unlock it, then retry. Your data here still works.';

  @override
  String get deferredNoKeyringTitle => 'Sync is off: no keyring is available';

  @override
  String get deferredNoKeyringBody =>
      'Install and unlock a desktop keyring (GNOME Keyring or KWallet), then retry.';

  @override
  String deferredPortsTitle(int first, int last) {
    return 'Sync is off: UDP $first–$last are in use';
  }

  @override
  String get deferredPortsBody =>
      'Another program or another copy of Fi is using these ports. Your data here still works.';

  @override
  String get sidebarCauseLocked => 'keyring locked';

  @override
  String get sidebarCauseNoKeyring => 'no keyring';

  @override
  String get sidebarCausePorts => 'ports in use';

  @override
  String get recordsClone => 'Clone';

  @override
  String recordsCloneOf(String title) {
    return 'Clone of ‘$title’';
  }

  @override
  String recordsClonedSnack(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Cloned $count records',
      one: 'Cloned 1 record',
    );
    return '$_temp0';
  }

  @override
  String get recordsActions => 'Record actions';

  @override
  String get commonUndo => 'Undo';

  @override
  String dictationMicLabel(String field) {
    return 'Dictate into $field';
  }

  @override
  String get dictationListening => 'Listening…';

  @override
  String dictationListeningAnnounce(String field) {
    return 'Listening into $field';
  }

  @override
  String get dictationCleaningUp => 'Cleaning up…';

  @override
  String get dictatedTitle => 'Dictated';

  @override
  String dictatedInto(String field) {
    return 'into $field';
  }

  @override
  String get dictatedCleaned => 'Cleaned';

  @override
  String get dictatedDefault => 'Default';

  @override
  String get dictatedAsHeard => 'As heard';

  @override
  String get dictatedNothingToClean => 'Nothing to clean up.';

  @override
  String dictatedInFieldNow(String text) {
    return 'In the field now: “$text”';
  }

  @override
  String get dictatedFieldEmpty => 'The field is empty.';

  @override
  String get dictatedAppend => 'Append';

  @override
  String get dictatedReplace => 'Replace';

  @override
  String get dictatedInsert => 'Insert';

  @override
  String dictatedRemovedWords(String words) {
    return 'Removed: $words';
  }

  @override
  String get fieldTypeChoices => 'Choices';

  @override
  String themeChoicesPicked(int count) {
    return '$count picked';
  }

  @override
  String get fieldEditorChoicesRequiredHelp =>
      'Required means at least one option is picked.';

  @override
  String get fieldEditorChoicesDefaultHelp =>
      'A set of options, picked on new records.';

  @override
  String get fieldEditorChoicesSemicolon =>
      'Options of a Choices field can\'t contain “;”.';

  @override
  String fieldEditorChoicesConversionBlocked(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records hold more than one choice. Edit them first.',
      one: '1 record holds more than one choice. Edit it first.',
    );
    return '$_temp0';
  }

  @override
  String get queryOpHasAnyOf => 'has any of';

  @override
  String get queryOpHasAllOf => 'has all of';

  @override
  String get queryOpHasNoneOf => 'has none of';

  @override
  String get queryOpIsEmpty => 'is empty';

  @override
  String get queryOpIsNotEmpty => 'is not empty';

  @override
  String get widgetGroupsOverlap =>
      'Groups overlap: a record counts in each of its choices.';

  @override
  String recordsMoreTags(int count) {
    return '+$count';
  }

  @override
  String get fieldEditorAllowAddingOptions =>
      'Allow adding options from records';

  @override
  String get fieldEditorAllowAddingOptionsHelp =>
      'New options are added to this field when the record is saved.';

  @override
  String fieldEditorOptionActions(String label) {
    return 'Actions for “$label”';
  }

  @override
  String get fieldEditorMergeEllipsis => 'Merge…';

  @override
  String get fieldEditorDeleteEllipsis => 'Delete…';

  @override
  String fieldEditorDuplicateBanner(int count, String label) {
    return '$count options are named “$label”. Merge them?';
  }

  @override
  String get fieldEditorMerge => 'Merge';

  @override
  String fieldEditorMergedStill(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records still use merged options.',
      one: '1 record still uses merged options.',
    );
    return '$_temp0';
  }

  @override
  String get fieldEditorMoveThem => 'Move them';

  @override
  String get mergeOptionsTitle => 'Merge options';

  @override
  String mergeOptionsSubtitle(String field, String kind) {
    return 'in $field · $kind';
  }

  @override
  String get mergeOptionsToMerge => 'Options to merge';

  @override
  String mergeOptionsRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records',
      one: '1 record',
    );
    return '$_temp0';
  }

  @override
  String get mergeOptionsKeep => 'Keep';

  @override
  String get mergeOptionsLabelStays => 'Its label stays';

  @override
  String mergeOptionsWillUse(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records will use “$label”',
      one: '1 record will use “$label”',
    );
    return '$_temp0';
  }

  @override
  String mergeOptionsHadBoth(int count, String label) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records had both. Each keeps one “$label”.',
      one: '1 record had both. It keeps one “$label”.',
    );
    return '$_temp0';
  }

  @override
  String get mergeOptionsCantUndo => 'This can\'t be undone.';

  @override
  String get mergeOptionsSaveFirst =>
      'Save the field first. Options with unsaved changes can\'t be merged.';

  @override
  String choiceAddOption(String label) {
    return 'Add “$label”';
  }

  @override
  String get choiceAddChip => 'Add';

  @override
  String get choiceNewTag => 'New';

  @override
  String get choiceExistingTag => 'existing';

  @override
  String get choiceNewOptionHint => 'New option';
}
