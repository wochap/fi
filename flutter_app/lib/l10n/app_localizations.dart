import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// Navigation label for the collections destination.
  ///
  /// In en, this message translates to:
  /// **'Collections'**
  String get navCollections;

  /// Navigation label for the devices destination.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get navDevices;

  /// Navigation label for the settings destination.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Settings section label for the interface language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// Title of the language setting.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get langAppLanguage;

  /// Explains what the language setting changes.
  ///
  /// In en, this message translates to:
  /// **'Menus, labels and dates. Changes apply right away.'**
  String get langAppLanguageHint;

  /// Language option that follows the system language.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get langSystemDefault;

  /// Language option that follows the system language, naming the resolved language.
  ///
  /// In en, this message translates to:
  /// **'System default ({language})'**
  String langSystemDefaultNamed(String language);

  /// Subtitle of the system default language option on Android.
  ///
  /// In en, this message translates to:
  /// **'{language} — same as your phone'**
  String langSameAsPhone(String language);

  /// Settings section label for the color theme.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// Title of the color theme setting.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// Explains the color theme setting.
  ///
  /// In en, this message translates to:
  /// **'Light or dark. Changes apply right away.'**
  String get themeHint;

  /// The light color theme.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// The dark color theme.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// Shown for a failure that is not a typed bridge error.
  ///
  /// In en, this message translates to:
  /// **'The local collection service encountered an unexpected error.'**
  String get errorUnexpected;

  /// Bridge error: initialization failed.
  ///
  /// In en, this message translates to:
  /// **'Secure device networking could not be initialized.'**
  String get errorInitialization;

  /// Bridge error: the desktop secure key store is locked.
  ///
  /// In en, this message translates to:
  /// **'Your login keyring is locked, so secure device networking cannot start. Unlock the keyring and retry.'**
  String get errorSecureStoreLocked;

  /// Bridge error: sync with paired devices is turned off.
  ///
  /// In en, this message translates to:
  /// **'Sync with paired devices is off.'**
  String get errorPaused;

  /// Bridge error: the local dataset could not be opened.
  ///
  /// In en, this message translates to:
  /// **'This device\'s local data cannot be opened.'**
  String get errorBootstrap;

  /// Bridge error: storage failed.
  ///
  /// In en, this message translates to:
  /// **'Local data could not be saved or loaded.'**
  String get errorPersistence;

  /// Bridge error: the read model could not be refreshed.
  ///
  /// In en, this message translates to:
  /// **'The local read model could not be refreshed.'**
  String get errorProjection;

  /// Bridge error: lifecycle failure.
  ///
  /// In en, this message translates to:
  /// **'The device could not be reached, or the local service is not running.'**
  String get errorLifecycle;

  /// Bridge error: internal failure.
  ///
  /// In en, this message translates to:
  /// **'The local collection data is not supported by this application version.'**
  String get errorInternal;

  /// Summary of several validation problems.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 problem needs attention} other{{count} problems need attention}}'**
  String errorValidation(int count);

  /// Validation issue: a value is required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get issueRequired;

  /// Validation issue: wrong value type.
  ///
  /// In en, this message translates to:
  /// **'Value does not match this field\'s type'**
  String get issueTypeMismatch;

  /// Validation issue: the chosen option was removed.
  ///
  /// In en, this message translates to:
  /// **'Pick an active option'**
  String get issueInactiveOption;

  /// Validation issue: the field was removed.
  ///
  /// In en, this message translates to:
  /// **'This field is no longer available'**
  String get issueFieldUnavailable;

  /// Validation issue: text length outside a range.
  ///
  /// In en, this message translates to:
  /// **'Must be {min}–{max} characters'**
  String issueLengthRange(int min, int max);

  /// Validation issue: text must have an exact length.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Must be exactly 1 character} other{Must be exactly {count} characters}}'**
  String issueLengthExact(int count);

  /// Validation issue: text too short.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Must be at least 1 character} other{Must be at least {count} characters}}'**
  String issueLengthMin(int count);

  /// Validation issue: text too long.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Must be at most 1 character} other{Must be at most {count} characters}}'**
  String issueLengthMax(int count);

  /// Validation issue: length problem without known bounds.
  ///
  /// In en, this message translates to:
  /// **'Length is not allowed'**
  String get issueLength;

  /// Validation issue: value outside a range.
  ///
  /// In en, this message translates to:
  /// **'Must be between {min} and {max}'**
  String issueRangeBetween(String min, String max);

  /// Validation issue: value too small.
  ///
  /// In en, this message translates to:
  /// **'Must be at least {min}'**
  String issueRangeMin(String min);

  /// Validation issue: value too large.
  ///
  /// In en, this message translates to:
  /// **'Must be at most {max}'**
  String issueRangeMax(String max);

  /// Validation issue: range problem without known bounds.
  ///
  /// In en, this message translates to:
  /// **'Value is out of range'**
  String get issueRange;

  /// Pairing failed for an unspecified reason.
  ///
  /// In en, this message translates to:
  /// **'Pairing did not complete.'**
  String get pairingDidNotComplete;

  /// Widget error: removed.
  ///
  /// In en, this message translates to:
  /// **'This widget was removed.'**
  String get widgetErrorRemoved;

  /// Widget error: unsupported type.
  ///
  /// In en, this message translates to:
  /// **'This widget type is not supported by this version of the app.'**
  String get widgetErrorUnsupportedType;

  /// Widget error: unsupported configuration version.
  ///
  /// In en, this message translates to:
  /// **'This widget was saved by a newer version of the app.'**
  String get widgetErrorUnsupportedConfigurationVersion;

  /// Widget error: invalid configuration.
  ///
  /// In en, this message translates to:
  /// **'This widget\'s settings are not valid.'**
  String get widgetErrorInvalidConfiguration;

  /// Widget error: unknown query.
  ///
  /// In en, this message translates to:
  /// **'The saved query of this widget is no longer available.'**
  String get widgetErrorUnknownQuery;

  /// Widget error: invalid query.
  ///
  /// In en, this message translates to:
  /// **'The saved query of this widget is not valid.'**
  String get widgetErrorInvalidQuery;

  /// Widget error: query result shape does not fit.
  ///
  /// In en, this message translates to:
  /// **'The saved query returns a result this widget cannot show.'**
  String get widgetErrorShapeMismatch;

  /// Widget error: aggregation overflowed.
  ///
  /// In en, this message translates to:
  /// **'The result is too large to compute exactly.'**
  String get widgetErrorOverflow;

  /// Widget error: the query failed.
  ///
  /// In en, this message translates to:
  /// **'The saved query could not run.'**
  String get widgetErrorQueryFailed;

  /// Toast after a CSV import.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Imported 1 record into {name}} other{Imported {count} records into {name}}}'**
  String importRecords(int count, String name);

  /// Toast after a JSON import.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Imported 1 collection} other{Imported {count} collections}}'**
  String importCollections(int count);

  /// Import failed at a place; reason is Rust's text.
  ///
  /// In en, this message translates to:
  /// **'Import stopped at {place}: {reason} Nothing was imported.'**
  String importStoppedAt(String place, String reason);

  /// Import failed without a place.
  ///
  /// In en, this message translates to:
  /// **'Import stopped: {reason} Nothing was imported.'**
  String importStopped(String reason);

  /// Import place: the CSV header row.
  ///
  /// In en, this message translates to:
  /// **'the header'**
  String get importPlaceHeader;

  /// Import place: a CSV row.
  ///
  /// In en, this message translates to:
  /// **'row {row}'**
  String importPlaceRow(int row);

  /// Import place: a collection in a JSON file.
  ///
  /// In en, this message translates to:
  /// **'collection {index}'**
  String importPlaceCollection(int index);

  /// Widget failure without a typed kind.
  ///
  /// In en, this message translates to:
  /// **'This widget could not be evaluated.'**
  String get widgetNotEvaluated;

  /// Boolean true value.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get commonYes;

  /// Boolean false value.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get commonNo;

  /// Status time when something never happened.
  ///
  /// In en, this message translates to:
  /// **'never'**
  String get timeNever;

  /// Status time under one minute ago.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// Status time in minutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min ago'**
  String timeMinutesAgo(int minutes);

  /// Status time in hours.
  ///
  /// In en, this message translates to:
  /// **'{hours} h ago'**
  String timeHoursAgo(int hours);

  /// Trusted device was never seen.
  ///
  /// In en, this message translates to:
  /// **'Never seen'**
  String get devicesNeverSeen;

  /// Trusted device never synced.
  ///
  /// In en, this message translates to:
  /// **'Never synced'**
  String get devicesNeverSynced;

  /// When a device was last seen; time is a status time like '5 min ago'.
  ///
  /// In en, this message translates to:
  /// **'Seen {time}'**
  String devicesSeen(String time);

  /// When a device last synced.
  ///
  /// In en, this message translates to:
  /// **'Synced {time}'**
  String devicesSynced(String time);

  /// Download time left in minutes.
  ///
  /// In en, this message translates to:
  /// **'about {minutes} min left'**
  String timeLeftMinutes(int minutes);

  /// Download time left in seconds.
  ///
  /// In en, this message translates to:
  /// **'about {seconds} s left'**
  String timeLeftSeconds(int seconds);

  /// Generic button: cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Generic button: save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// Generic button: delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// Generic button or tooltip: close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// Generic button: done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// Generic button: retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// Generic button: try again.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get commonTryAgain;

  /// Generic button: show.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get commonShow;

  /// Generic button or tooltip: clear a value.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get commonClear;

  /// Generic action: rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get commonRename;

  /// Generic action: edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// Generic action: add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// Generic button or tooltip: back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get commonBack;

  /// Generic button: OK.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// Generic action: copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// Generic option: no value chosen.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get commonNone;

  /// Generic loading text.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get commonLoading;

  /// Tag marking a required field.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get commonRequired;

  /// Generic action or title: details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get commonDetails;

  /// Generic short button: create something new.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get commonNew;

  /// Hint for an empty choice input
  ///
  /// In en, this message translates to:
  /// **'Choose…'**
  String get themeChoose;

  /// Hint for a searchable choice sheet
  ///
  /// In en, this message translates to:
  /// **'Search {count} options'**
  String themeSearchOptions(int count);

  /// Hint for a desktop searchable choice field
  ///
  /// In en, this message translates to:
  /// **'Type to search {count} options'**
  String themeTypeToSearchOptions(int count);

  /// Footer under choice search results
  ///
  /// In en, this message translates to:
  /// **'{matches} of {total} · ↑↓ to move, Enter to pick'**
  String themeMatchesFooter(int matches, int total);

  /// Search box hint
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get themeSearch;

  /// Overflow menu tooltip
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get themeMore;

  /// Button that sets a bounded number input to its minimum
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get themeSet;

  /// Chip marking a field filled by voice
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get themeVoice;

  /// Semantics label of the voice chip
  ///
  /// In en, this message translates to:
  /// **'{field}, filled by voice'**
  String themeFilledByVoice(String field);

  /// Marker for a field holding its default value
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get themeDefault;

  /// Marker for a required field without a value
  ///
  /// In en, this message translates to:
  /// **'Needed'**
  String get themeNeeded;

  /// Chart preset
  ///
  /// In en, this message translates to:
  /// **'Daily total'**
  String get queryPresetDailyTotal;

  /// Chart preset
  ///
  /// In en, this message translates to:
  /// **'Monthly total'**
  String get queryPresetMonthlyTotal;

  /// Chart preset
  ///
  /// In en, this message translates to:
  /// **'Count per day'**
  String get queryPresetCountPerDay;

  /// Chart preset
  ///
  /// In en, this message translates to:
  /// **'Latest values'**
  String get queryPresetLatestValues;

  /// Query blocker
  ///
  /// In en, this message translates to:
  /// **'Choose the field to aggregate.'**
  String get queryBlockerOperand;

  /// Query blocker
  ///
  /// In en, this message translates to:
  /// **'Choose the category or period field.'**
  String get queryBlockerCategoryOrPeriod;

  /// Query blocker
  ///
  /// In en, this message translates to:
  /// **'Choose both axes.'**
  String get queryBlockerAxes;

  /// Query blocker
  ///
  /// In en, this message translates to:
  /// **'Choose the category field.'**
  String get queryBlockerCategory;

  /// Query blocker
  ///
  /// In en, this message translates to:
  /// **'Enter the filter value or clear the filter.'**
  String get queryBlockerFilterValue;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'Made elsewhere; not editable here.'**
  String get queryMadeElsewhere;

  /// Query description fallback field
  ///
  /// In en, this message translates to:
  /// **'an expression'**
  String get queryAnExpression;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'{aggregation} of {field}'**
  String queryDescAggregationOf(String aggregation, String field);

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'each record, {x} against {y}'**
  String queryDescSeries(String x, String y);

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'by {field}'**
  String queryDescBy(String field);

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'per day'**
  String get queryDescPerDay;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'per week'**
  String get queryDescPerWeek;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'per month'**
  String get queryDescPerMonth;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'per year'**
  String get queryDescPerYear;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'filtered'**
  String get queryDescFiltered;

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'limit {limit}'**
  String queryDescLimit(int limit);

  /// Query description
  ///
  /// In en, this message translates to:
  /// **'Every record'**
  String get queryDescEveryRecord;

  /// Aggregation
  ///
  /// In en, this message translates to:
  /// **'Count'**
  String get queryAggCount;

  /// Aggregation
  ///
  /// In en, this message translates to:
  /// **'Sum'**
  String get queryAggSum;

  /// Aggregation
  ///
  /// In en, this message translates to:
  /// **'Average'**
  String get queryAggAverage;

  /// Aggregation
  ///
  /// In en, this message translates to:
  /// **'Min'**
  String get queryAggMin;

  /// Aggregation
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get queryAggMax;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Group by'**
  String get queryGroupBy;

  /// Period
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get queryPeriodDay;

  /// Period
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get queryPeriodWeek;

  /// Period
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get queryPeriodMonth;

  /// Period
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get queryPeriodYear;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Category field'**
  String get queryCategoryField;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Date field'**
  String get queryDateField;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Aggregation'**
  String get queryAggregation;

  /// Helper
  ///
  /// In en, this message translates to:
  /// **'Choose a Group by period to aggregate'**
  String get queryAggregationNeedsGroup;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Field to aggregate'**
  String get queryOperandField;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Output scale'**
  String get queryOutputScale;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Rounding policy'**
  String get queryRoundingPolicy;

  /// Rounding
  ///
  /// In en, this message translates to:
  /// **'Half to even'**
  String get queryRoundingHalfEven;

  /// Rounding
  ///
  /// In en, this message translates to:
  /// **'Reject inexact'**
  String get queryRoundingRejectInexact;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'X axis'**
  String get queryXAxis;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Y axis'**
  String get queryYAxis;

  /// Filter field select
  ///
  /// In en, this message translates to:
  /// **'Field'**
  String get queryFilterField;

  /// Filter operator select
  ///
  /// In en, this message translates to:
  /// **'Operator'**
  String get queryFilterOperator;

  /// Filter value input
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get queryFilterValue;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'equals'**
  String get queryOpEquals;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'is not'**
  String get queryOpIsNot;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'greater than'**
  String get queryOpGreaterThan;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'at least'**
  String get queryOpAtLeast;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'less than'**
  String get queryOpLessThan;

  /// Operator
  ///
  /// In en, this message translates to:
  /// **'at most'**
  String get queryOpAtMost;

  /// Query usage
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Used by no widgets} =1{Used by 1 widget} other{Used by {count} widgets}}'**
  String queryUsedBy(int count);

  /// Validation
  ///
  /// In en, this message translates to:
  /// **'Give the query a name.'**
  String get queryNameRequired;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Query name'**
  String get queryName;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'This query was made elsewhere and cannot be edited here.'**
  String get queryNotEditable;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Edit query'**
  String get queryEditTitle;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Save as new query'**
  String get querySaveAsNewTitle;

  /// Default name for copied query
  ///
  /// In en, this message translates to:
  /// **'{name} copy'**
  String queryCopyName(String name);

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Edit this query'**
  String get queryEditThis;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Save as new'**
  String get querySaveAsNew;

  /// Default query name
  ///
  /// In en, this message translates to:
  /// **'Widget query'**
  String get queryDefaultName;

  /// Title of the voice models card
  ///
  /// In en, this message translates to:
  /// **'Voice models'**
  String get modelCardTitle;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Not downloaded'**
  String get modelTagNotDownloaded;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get modelTagDownloading;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get modelTagReconnecting;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Verifying'**
  String get modelTagVerifying;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get modelTagPaused;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get modelTagFailed;

  /// Model state tag
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get modelTagReady;

  /// Speech model role name
  ///
  /// In en, this message translates to:
  /// **'Speech recognition'**
  String get modelRoleSpeech;

  /// Understanding model role name
  ///
  /// In en, this message translates to:
  /// **'Understanding'**
  String get modelRoleUnderstanding;

  /// Speech role inside a sentence
  ///
  /// In en, this message translates to:
  /// **'speech recognition'**
  String get modelRoleSpeechInSentence;

  /// Understanding role inside a sentence
  ///
  /// In en, this message translates to:
  /// **'understanding'**
  String get modelRoleUnderstandingInSentence;

  /// Model language when it covers all languages
  ///
  /// In en, this message translates to:
  /// **'All languages'**
  String get modelAllLanguages;

  /// Card summary, not downloaded
  ///
  /// In en, this message translates to:
  /// **'{language} · {total} total'**
  String modelSummaryTotal(String language, String total);

  /// Card summary while downloading
  ///
  /// In en, this message translates to:
  /// **'{language} · {done} of {total}'**
  String modelSummaryProgress(String language, String done, String total);

  /// Card summary while verifying
  ///
  /// In en, this message translates to:
  /// **'{language} · {total}'**
  String modelSummarySize(String language, String total);

  /// Card summary when paused
  ///
  /// In en, this message translates to:
  /// **'{language} · paused at {done} of {total}'**
  String modelSummaryPaused(String language, String done, String total);

  /// Card summary when failed
  ///
  /// In en, this message translates to:
  /// **'{language} · stopped at {done}'**
  String modelSummaryStopped(String language, String done);

  /// Card summary when the checksum failed
  ///
  /// In en, this message translates to:
  /// **'{language} · check failed'**
  String modelSummaryCheckFailed(String language);

  /// Card summary when ready
  ///
  /// In en, this message translates to:
  /// **'{language} · {total} used on this phone'**
  String modelSummaryReady(String language, String total);

  /// Model row progress
  ///
  /// In en, this message translates to:
  /// **'{stored} of {size}'**
  String modelRowProgress(String stored, String size);

  /// Model row while checking
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get modelRowChecking;

  /// Model row when damaged
  ///
  /// In en, this message translates to:
  /// **'{size} · damaged'**
  String modelRowDamaged(String size);

  /// Hint to use Wi-Fi
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi recommended'**
  String get modelWifiRecommended;

  /// Space needed
  ///
  /// In en, this message translates to:
  /// **'Needs {needed}'**
  String modelNeeds(String needed);

  /// Space needed and free
  ///
  /// In en, this message translates to:
  /// **'Needs {needed} · {free} free on this phone'**
  String modelNeedsWithFree(String needed, String free);

  /// Download button with size
  ///
  /// In en, this message translates to:
  /// **'Download {size}'**
  String modelDownload(String size);

  /// Pause button
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get modelPause;

  /// Resume button
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get modelResume;

  /// Cancel and delete button
  ///
  /// In en, this message translates to:
  /// **'Cancel and delete'**
  String get modelCancelAndDelete;

  /// Percent
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String modelPercent(int percent);

  /// Approximate time left
  ///
  /// In en, this message translates to:
  /// **'about {time}'**
  String modelTimeLeft(String time);

  /// Reconnecting title
  ///
  /// In en, this message translates to:
  /// **'Connection lost — reconnecting…'**
  String get modelReconnectingTitle;

  /// Reconnecting line
  ///
  /// In en, this message translates to:
  /// **'The download resumes where it stopped.'**
  String get modelReconnectingResumes;

  /// Reconnecting hint
  ///
  /// In en, this message translates to:
  /// **'Leaving Fi can pause the network. Keep it open to finish faster.'**
  String get modelReconnectingKeepOpen;

  /// Verifying title
  ///
  /// In en, this message translates to:
  /// **'Checking downloaded data…'**
  String get modelVerifyingTitle;

  /// Progress note when paused
  ///
  /// In en, this message translates to:
  /// **'resumes from here'**
  String get modelResumesFromHere;

  /// Network failure title
  ///
  /// In en, this message translates to:
  /// **'No connection'**
  String get modelNetworkTitle;

  /// Network failure line
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the download server. Check your Wi-Fi, then retry. Downloaded data is kept.'**
  String get modelNetworkLine;

  /// Storage failure title
  ///
  /// In en, this message translates to:
  /// **'Not enough storage'**
  String get modelStorageTitle;

  /// Storage failure line
  ///
  /// In en, this message translates to:
  /// **'Free up {needed} on this phone, then retry.'**
  String modelStorageLine(String needed);

  /// Checksum failure title
  ///
  /// In en, this message translates to:
  /// **'Downloaded file is damaged'**
  String get modelDamagedTitle;

  /// Checksum failure line
  ///
  /// In en, this message translates to:
  /// **'The {role} model failed its check. Retry downloads it again ({size}).'**
  String modelDamagedLine(String role, String size);

  /// IO failure title
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the download'**
  String get modelIoTitle;

  /// IO failure line
  ///
  /// In en, this message translates to:
  /// **'Storage error. Retry; downloaded data is kept.'**
  String get modelIoLine;

  /// Cancel dialog title
  ///
  /// In en, this message translates to:
  /// **'Cancel download?'**
  String get modelCancelDialogTitle;

  /// Cancel dialog body
  ///
  /// In en, this message translates to:
  /// **'Downloaded data ({done}) will be deleted.'**
  String modelCancelDialogBody(String done);

  /// Cancel dialog confirm
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get modelCancelDialogConfirm;

  /// Cancel dialog keep
  ///
  /// In en, this message translates to:
  /// **'Keep downloading'**
  String get modelCancelDialogKeep;

  /// Delete dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete voice models?'**
  String get modelDeleteDialogTitle;

  /// Delete dialog body
  ///
  /// In en, this message translates to:
  /// **'Frees {size}. Voice fill won’t work until you download them again.'**
  String modelDeleteDialogBody(String size);

  /// Keep models button
  ///
  /// In en, this message translates to:
  /// **'Keep models'**
  String get modelKeepModels;

  /// Re-download dialog title
  ///
  /// In en, this message translates to:
  /// **'Re-download voice models?'**
  String get modelRedownloadDialogTitle;

  /// Re-download dialog body
  ///
  /// In en, this message translates to:
  /// **'The models are deleted and downloaded again ({size}).'**
  String modelRedownloadDialogBody(String size);

  /// Re-download confirm
  ///
  /// In en, this message translates to:
  /// **'Re-download'**
  String get modelRedownloadDialogConfirm;

  /// Download offer title
  ///
  /// In en, this message translates to:
  /// **'Download voice models'**
  String get modelOfferTitle;

  /// Download offer line
  ///
  /// In en, this message translates to:
  /// **'{language} · {size} total, one time. Everything runs on this phone.'**
  String modelOfferLine(String language, String size);

  /// Network row, mobile
  ///
  /// In en, this message translates to:
  /// **'You\'re on mobile data'**
  String get modelOnMobileData;

  /// Network row, Wi-Fi
  ///
  /// In en, this message translates to:
  /// **'You\'re on Wi-Fi'**
  String get modelOnWifi;

  /// Storage row
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get modelStorage;

  /// Free space
  ///
  /// In en, this message translates to:
  /// **'{size} free'**
  String modelFree(String size);

  /// Later button
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get modelLater;

  /// Downloading title
  ///
  /// In en, this message translates to:
  /// **'Downloading voice models'**
  String get modelDownloadingTitle;

  /// Short reconnecting title
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get modelReconnectingShort;

  /// Paused title
  ///
  /// In en, this message translates to:
  /// **'Download paused'**
  String get modelPausedTitle;

  /// Download progress line
  ///
  /// In en, this message translates to:
  /// **'{done} of {total} · {percent}%'**
  String modelProgressLine(String done, String total, int percent);

  /// Hint while downloading
  ///
  /// In en, this message translates to:
  /// **'Keep filling by hand. The mic turns on when it\'s ready.'**
  String get modelKeepFilling;

  /// Pause tooltip
  ///
  /// In en, this message translates to:
  /// **'Pause download'**
  String get modelPauseDownload;

  /// Hide tooltip
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get modelHide;

  /// Error title and line
  ///
  /// In en, this message translates to:
  /// **'{title}. {line}'**
  String modelErrorLine(String title, String line);

  /// Help popup title for fieldRequired
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get helpFieldRequiredTitle;

  /// Help popup body for fieldRequired
  ///
  /// In en, this message translates to:
  /// **'A required field must hold a value. New records cannot be saved without it.\n\nTurning this on for a field that existing records do not have marks those records invalid until you fill the field in. They are never deleted, and you can still open and repair them from the record list.\n\nSetting a default avoids that: the default counts as the value for every record that does not have one.'**
  String get helpFieldRequiredBody;

  /// Help popup title for fieldDefault
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get helpFieldDefaultTitle;

  /// Help popup body for fieldDefault
  ///
  /// In en, this message translates to:
  /// **'The value used when a record does not supply one. It fills new records as you create them, and it satisfies the Required rule for existing records that lack the field.\n\nLeave it empty if every record should state its own value.'**
  String get helpFieldDefaultBody;

  /// Help popup title for fieldDecimalScale
  ///
  /// In en, this message translates to:
  /// **'Decimal scale'**
  String get helpFieldDecimalScaleTitle;

  /// Help popup body for fieldDecimalScale
  ///
  /// In en, this message translates to:
  /// **'How many digits are kept after the decimal point. Scale 2 stores 10.25 exactly; scale 0 stores whole numbers only.\n\nValues are stored as exact numbers, never as floating point, so sums and averages do not drift. The scale cannot be changed once records hold a value for this field.'**
  String get helpFieldDecimalScaleBody;

  /// Help popup title for fieldMinMax
  ///
  /// In en, this message translates to:
  /// **'Minimum and Maximum'**
  String get helpFieldMinMaxTitle;

  /// Help popup body for fieldMinMax
  ///
  /// In en, this message translates to:
  /// **'The range a value is allowed to fall in, inclusive on both ends. A record outside the range is rejected when you save it.\n\nLeave either box empty for no limit on that side.'**
  String get helpFieldMinMaxBody;

  /// Help popup title for fieldMinMaxLength
  ///
  /// In en, this message translates to:
  /// **'Minimum and Maximum length'**
  String get helpFieldMinMaxLengthTitle;

  /// Help popup body for fieldMinMaxLength
  ///
  /// In en, this message translates to:
  /// **'How short and how long the text may be, counted in characters.\n\nLeave either box empty for no limit on that side.'**
  String get helpFieldMinMaxLengthBody;

  /// Help popup title for fieldMultiline
  ///
  /// In en, this message translates to:
  /// **'Multiline'**
  String get helpFieldMultilineTitle;

  /// Help popup body for fieldMultiline
  ///
  /// In en, this message translates to:
  /// **'Shows this text field as a box that accepts line breaks instead of a single line. It changes how the field is edited, not what may be stored in it.'**
  String get helpFieldMultilineBody;

  /// Help popup title for fieldSlider
  ///
  /// In en, this message translates to:
  /// **'Show as slider'**
  String get helpFieldSliderTitle;

  /// Help popup body for fieldSlider
  ///
  /// In en, this message translates to:
  /// **'Shows this number field as a slider that moves from the minimum to the maximum, with the picked value beside it. Until a value is picked the track shows no thumb; tap or drag it to pick one, and the number appears beside it.\n\nA row of numbers under the track shows the scale: every step when they all fit, otherwise only the minimum and the maximum at the two ends.\n\nStep sets how far each move goes, for example 10 on a 0 to 100 range. Leave it empty for whole steps of 1. The step must divide the distance from the minimum to the maximum exactly, so the last position lands on the maximum.\n\nAvailable only once both a minimum and a maximum are set. It changes how the field is edited, not what is stored: queries, charts, and the record list still see a number.'**
  String get helpFieldSliderBody;

  /// Help popup title for widgetType
  ///
  /// In en, this message translates to:
  /// **'Widget type'**
  String get helpWidgetTypeTitle;

  /// Help popup body for widgetType
  ///
  /// In en, this message translates to:
  /// **'What the widget draws.\n\nNumber shows one aggregated value, such as a total or a count. Line chart draws a value over time. Bar chart compares one value across categories. Scatter plot places one point per record using two fields as the axes.'**
  String get helpWidgetTypeBody;

  /// Help popup title for widgetUseSavedQuery
  ///
  /// In en, this message translates to:
  /// **'Use a saved query'**
  String get helpWidgetUseSavedQueryTitle;

  /// Help popup body for widgetUseSavedQuery
  ///
  /// In en, this message translates to:
  /// **'On, the widget reuses a query you already saved, and editing that query updates every widget that uses it.\n\nOff, you build the query here and it is saved under the widget title.'**
  String get helpWidgetUseSavedQueryBody;

  /// Help popup title for widgetAggregation
  ///
  /// In en, this message translates to:
  /// **'Aggregation'**
  String get helpWidgetAggregationTitle;

  /// Help popup body for widgetAggregation
  ///
  /// In en, this message translates to:
  /// **'How many records are reduced to one number.\n\nCount counts records and needs no field. Sum, Average, Min, and Max each read one numeric field, chosen below.\n\nWith a Group by period the aggregation is computed once per period rather than once over everything.'**
  String get helpWidgetAggregationBody;

  /// Help popup title for widgetOperandField
  ///
  /// In en, this message translates to:
  /// **'Field to aggregate'**
  String get helpWidgetOperandFieldTitle;

  /// Help popup body for widgetOperandField
  ///
  /// In en, this message translates to:
  /// **'The numeric field the aggregation reads. Only number, decimal, and duration fields can be summed or averaged.\n\nCount ignores this because it counts records rather than values.'**
  String get helpWidgetOperandFieldBody;

  /// Help popup title for widgetOutputScale
  ///
  /// In en, this message translates to:
  /// **'Output scale'**
  String get helpWidgetOutputScaleTitle;

  /// Help popup body for widgetOutputScale
  ///
  /// In en, this message translates to:
  /// **'How many decimal places the average keeps. An average rarely divides evenly, so the result must state its own precision instead of inheriting one.'**
  String get helpWidgetOutputScaleBody;

  /// Help popup title for widgetRounding
  ///
  /// In en, this message translates to:
  /// **'Rounding policy'**
  String get helpWidgetRoundingTitle;

  /// Help popup body for widgetRounding
  ///
  /// In en, this message translates to:
  /// **'What happens when the average does not fit the output scale exactly.\n\nHalf to even rounds to the nearest value and breaks ties toward the even digit, which keeps long runs of numbers unbiased. Reject inexact refuses to show a result rather than round, so you never read a rounded number as an exact one.'**
  String get helpWidgetRoundingBody;

  /// Help popup title for widgetGroupBy
  ///
  /// In en, this message translates to:
  /// **'Group by'**
  String get helpWidgetGroupByTitle;

  /// Help popup body for widgetGroupBy
  ///
  /// In en, this message translates to:
  /// **'Buckets records by calendar period — day, week, month, or year — using the date field you choose, and computes the aggregation once per bucket. Each bucket becomes one point or one bar.\n\nChoose None to aggregate over everything at once, or to group by a category instead of a period.'**
  String get helpWidgetGroupByBody;

  /// Help popup title for widgetDateField
  ///
  /// In en, this message translates to:
  /// **'Date field'**
  String get helpWidgetDateFieldTitle;

  /// Help popup body for widgetDateField
  ///
  /// In en, this message translates to:
  /// **'The date or timestamp used to decide which period a record falls into. Weeks start on Monday and periods are computed in UTC.'**
  String get helpWidgetDateFieldBody;

  /// Help popup title for widgetCategoryField
  ///
  /// In en, this message translates to:
  /// **'Category field'**
  String get helpWidgetCategoryFieldTitle;

  /// Help popup body for widgetCategoryField
  ///
  /// In en, this message translates to:
  /// **'The field whose values become the categories along the axis: one bar or one point per distinct value. Records sharing a value are aggregated together.'**
  String get helpWidgetCategoryFieldBody;

  /// Help popup title for widgetXAxis
  ///
  /// In en, this message translates to:
  /// **'X axis'**
  String get helpWidgetXAxisTitle;

  /// Help popup body for widgetXAxis
  ///
  /// In en, this message translates to:
  /// **'The field plotted horizontally, one point per record. No aggregation happens: each record keeps its own point.'**
  String get helpWidgetXAxisBody;

  /// Help popup title for widgetYAxis
  ///
  /// In en, this message translates to:
  /// **'Y axis'**
  String get helpWidgetYAxisTitle;

  /// Help popup body for widgetYAxis
  ///
  /// In en, this message translates to:
  /// **'The numeric field plotted vertically, one point per record.'**
  String get helpWidgetYAxisBody;

  /// Help popup title for widgetFilter
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get helpWidgetFilterTitle;

  /// Help popup body for widgetFilter
  ///
  /// In en, this message translates to:
  /// **'Restricts the widget to records matching one condition, such as amount greater than 10 or category equals Migraine.\n\nLeave the field set to None to include every record. The filter changes what the widget shows; it never hides or deletes records anywhere else.'**
  String get helpWidgetFilterBody;

  /// Help popup title for widgetUnitSuffix
  ///
  /// In en, this message translates to:
  /// **'Unit suffix'**
  String get helpWidgetUnitSuffixTitle;

  /// Help popup body for widgetUnitSuffix
  ///
  /// In en, this message translates to:
  /// **'Text shown after the value, such as EUR or mg. It is display only: the exact number is unchanged and the suffix is never stored with the data.'**
  String get helpWidgetUnitSuffixBody;

  /// Help popup title for widgetShowPoints
  ///
  /// In en, this message translates to:
  /// **'Show points'**
  String get helpWidgetShowPointsTitle;

  /// Help popup body for widgetShowPoints
  ///
  /// In en, this message translates to:
  /// **'Draws a marker at every data point on the line, which helps when there are only a few points or when gaps matter.'**
  String get helpWidgetShowPointsBody;

  /// Help popup title for widgetAxisLabel
  ///
  /// In en, this message translates to:
  /// **'Y axis label'**
  String get helpWidgetAxisLabelTitle;

  /// Help popup body for widgetAxisLabel
  ///
  /// In en, this message translates to:
  /// **'Text shown beside the vertical axis to name what is being measured, such as \"Hours\" or \"EUR\". Leave it empty for no label.'**
  String get helpWidgetAxisLabelBody;

  /// Help popup title for widgetBarWidth
  ///
  /// In en, this message translates to:
  /// **'Bar width'**
  String get helpWidgetBarWidthTitle;

  /// Help popup body for widgetBarWidth
  ///
  /// In en, this message translates to:
  /// **'How wide each bar is drawn, in logical pixels. Leave it empty to let the chart size the bars to fit.'**
  String get helpWidgetBarWidthBody;

  /// Help popup title for widgetPointRadius
  ///
  /// In en, this message translates to:
  /// **'Point radius'**
  String get helpWidgetPointRadiusTitle;

  /// Help popup body for widgetPointRadius
  ///
  /// In en, this message translates to:
  /// **'How large each plotted point is drawn, in logical pixels. Leave it empty for the default size.'**
  String get helpWidgetPointRadiusBody;

  /// Help popup title for computedFields
  ///
  /// In en, this message translates to:
  /// **'Computed fields'**
  String get helpComputedFieldsTitle;

  /// Help popup body for computedFields
  ///
  /// In en, this message translates to:
  /// **'A computed field derives its value from other fields of the same record, such as amount × rate or ended − started. It is recalculated on this device whenever it is read, so it is never out of date, and only its definition is synchronised, never its values.\n\nUse one for totals with the sign removed, products like price × quantity, or the time between two dates. Queries and widgets can use it like any other field, and editing it changes every query and widget that uses it.'**
  String get helpComputedFieldsBody;

  /// Help popup title for computedFieldResult
  ///
  /// In en, this message translates to:
  /// **'Result type'**
  String get helpComputedFieldResultTitle;

  /// Help popup body for computedFieldResult
  ///
  /// In en, this message translates to:
  /// **'The result type is worked out from the expression; you never pick it.\n\n+ and − need both sides to have the same number of decimals. × adds the decimals of both sides (scale 2 × scale 3 gives scale 5). Whole numbers and decimals cannot be mixed in +, − or ×; turn the number into a decimal instead. Subtracting two dates gives a duration.\n\n÷ always gives a decimal at the scale you choose. \"Round half to even\" rounds the last digit; \"Reject inexact\" leaves the value empty when the answer does not fit exactly.\n\nIf any field used is empty for a record, the result is empty for that record (\"may be empty\").'**
  String get helpComputedFieldResultBody;

  /// Help popup title for querySavedQueries
  ///
  /// In en, this message translates to:
  /// **'Saved queries'**
  String get helpQuerySavedQueriesTitle;

  /// Help popup body for querySavedQueries
  ///
  /// In en, this message translates to:
  /// **'A named query that widgets can reference. Editing one here updates every widget that uses it; the editor states how many widgets that is before you save.\n\nDeleting a query does not delete any record.'**
  String get helpQuerySavedQueriesBody;

  /// Help popup title for pairingStartPairing
  ///
  /// In en, this message translates to:
  /// **'Start pairing'**
  String get helpPairingStartPairingTitle;

  /// Help popup body for pairingStartPairing
  ///
  /// In en, this message translates to:
  /// **'Makes this device discoverable to nearby devices for a short window so the two can exchange trust.\n\nBoth devices must be nearby and on the same network, and both must have pairing on. Nothing is shared until you confirm the same six-digit code on both screens.'**
  String get helpPairingStartPairingBody;

  /// Help popup title for pairingSingleInitiator
  ///
  /// In en, this message translates to:
  /// **'Only one device connects'**
  String get helpPairingSingleInitiatorTitle;

  /// Help popup body for pairingSingleInitiator
  ///
  /// In en, this message translates to:
  /// **'Both devices see each other, but only one may tap Connect. If both tap, the two attempts collide and the pairing fails.\n\nPick either device, tap Connect there, and let the other one wait.'**
  String get helpPairingSingleInitiatorBody;

  /// Help popup title for discoverable
  ///
  /// In en, this message translates to:
  /// **'Discoverable'**
  String get helpDiscoverableTitle;

  /// Help popup body for discoverable
  ///
  /// In en, this message translates to:
  /// **'When on, this device announces itself to your paired devices on the local network and looks for their announcements, so they find each other automatically.\n\nWhen off, it neither announces nor looks. Paired devices can still connect while their address is known, for example a session that is already open or one that dials this device, but a device whose address changed will not be found again until you turn this back on.\n\nPairing a new device is not affected: it uses its own short announcement.'**
  String get helpDiscoverableBody;

  /// Help popup title for syncEnabled
  ///
  /// In en, this message translates to:
  /// **'Sync with paired devices'**
  String get helpSyncEnabledTitle;

  /// Help popup body for syncEnabled
  ///
  /// In en, this message translates to:
  /// **'When on, this device connects to your paired devices and keeps the dataset in sync with them.\n\nWhen off, sync is paused: open sessions close, this device stops connecting, and connections from paired devices are refused. Your pairings and data are kept, and changes sync again once you turn this back on.\n\nPairing a new device still works while sync is paused.'**
  String get helpSyncEnabledBody;

  /// Tooltip of a help button
  ///
  /// In en, this message translates to:
  /// **'About {title}'**
  String helpAboutTooltip(String title);

  /// Reset dialog lead when local data cannot be opened.
  ///
  /// In en, this message translates to:
  /// **'This device\'s local data cannot be opened by this version of the app. Resetting it lets you create a new dataset or join one from another device.'**
  String get bootResetLeadError;

  /// Reset dialog lead from the recovery screen.
  ///
  /// In en, this message translates to:
  /// **'Recovery needs one of your other devices. Resetting instead abandons the dataset recorded on this device; if you own no other device holding it, the set-aside copy is kept on disk but this app cannot read it.'**
  String get recoveryResetLead;

  /// Button after unlocking the keyring.
  ///
  /// In en, this message translates to:
  /// **'Retry after unlocking'**
  String get bootRetryAfterUnlock;

  /// Button/row title to reset local data.
  ///
  /// In en, this message translates to:
  /// **'Reset this device\'s data'**
  String get shellResetData;

  /// Fallback boot state.
  ///
  /// In en, this message translates to:
  /// **'The local collection service is unavailable.'**
  String get bootServiceUnavailable;

  /// Recovery title.
  ///
  /// In en, this message translates to:
  /// **'Recovery needs another device'**
  String get recoveryNeedsDevice;

  /// Quarantine banner.
  ///
  /// In en, this message translates to:
  /// **'Data found on this device was set aside because its dataset record was missing. Nothing was deleted: joining the same dataset from another device restores it.'**
  String get onboardQuarantined;

  /// Create button busy.
  ///
  /// In en, this message translates to:
  /// **'Creating…'**
  String get onboardCreating;

  /// Sidebar status second line; reach is sidebarNoneNearby or sidebarConnected.
  ///
  /// In en, this message translates to:
  /// **'{count} paired · {reach}'**
  String sidebarPairedSummary(int count, String reach);

  /// No reachable devices.
  ///
  /// In en, this message translates to:
  /// **'none nearby'**
  String get sidebarNoneNearby;

  /// Reachable device count.
  ///
  /// In en, this message translates to:
  /// **'{count} connected'**
  String sidebarConnectedCount(int count);

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get devicesStatusOffline;

  /// Aggregate sync status searching.
  ///
  /// In en, this message translates to:
  /// **'Looking for paired devices'**
  String get devicesStatusLooking;

  /// Peer sync status.
  ///
  /// In en, this message translates to:
  /// **'Searching'**
  String get devicesStatusSearching;

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get devicesStatusConnected;

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get devicesStatusSyncing;

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get devicesStatusSynced;

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get devicesStatusError;

  /// Sync status.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get devicesStatusPaused;

  /// Revoked device tag.
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get devicesStatusRevoked;

  /// Devices page intro.
  ///
  /// In en, this message translates to:
  /// **'Devices you trust sync this dataset directly with each other.'**
  String get devicesIntro;

  /// Rotation error; error is raw.
  ///
  /// In en, this message translates to:
  /// **'The device was revoked, but the discovery secret could not be rotated: {error}'**
  String devicesRotationError(String error);

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Retry rotation'**
  String get devicesRetryRotation;

  /// Fallback peer name.
  ///
  /// In en, this message translates to:
  /// **'the other device'**
  String get devicesOtherDevice;

  /// Section label.
  ///
  /// In en, this message translates to:
  /// **'Trusted devices · {count}'**
  String devicesTrustedHeading(int count);

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Pair device'**
  String get devicesPairDevice;

  /// Section label.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get devicesThisDevice;

  /// Menu tooltip.
  ///
  /// In en, this message translates to:
  /// **'Device actions'**
  String get devicesActions;

  /// Menu item.
  ///
  /// In en, this message translates to:
  /// **'Revoke / unpair'**
  String get devicesRevokeUnpair;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'Log copied'**
  String get devicesLogCopied;

  /// Dialog title.
  ///
  /// In en, this message translates to:
  /// **'Rename device'**
  String get devicesRenameTitle;

  /// Dialog title.
  ///
  /// In en, this message translates to:
  /// **'Revoke {name}?'**
  String devicesRevokeTitle(String name);

  /// Dialog body.
  ///
  /// In en, this message translates to:
  /// **'It stops syncing with this device right away. It stays in the list as revoked, and you can pair it again later.'**
  String get devicesRevokeBody;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get devicesRevoke;

  /// Dialog title.
  ///
  /// In en, this message translates to:
  /// **'Delete revoked device?'**
  String get devicesDeleteTitle;

  /// Dialog body.
  ///
  /// In en, this message translates to:
  /// **'Removes {name} from this list. It can be paired again.'**
  String devicesDeleteBody(String name);

  /// Section label.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get devicesConnections;

  /// Switch title.
  ///
  /// In en, this message translates to:
  /// **'Discoverable'**
  String get devicesDiscoverable;

  /// Switch subtitle.
  ///
  /// In en, this message translates to:
  /// **'Announce this device to paired devices on the local network.'**
  String get devicesDiscoverableSubtitle;

  /// Switch title.
  ///
  /// In en, this message translates to:
  /// **'Sync with paired devices'**
  String get devicesSyncEnabled;

  /// Switch subtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to and accept connections from paired devices.'**
  String get devicesSyncEnabledSubtitle;

  /// Empty state title.
  ///
  /// In en, this message translates to:
  /// **'No devices paired yet'**
  String get devicesNoneYet;

  /// Empty state body (phone).
  ///
  /// In en, this message translates to:
  /// **'Start pairing on both devices while they\'re nearby.'**
  String get devicesNoneBodyPhone;

  /// Empty state body.
  ///
  /// In en, this message translates to:
  /// **'Start pairing on both devices while they\'re nearby. Pairing turns itself off after 2 minutes.'**
  String get devicesNoneBody;

  /// Paired banner.
  ///
  /// In en, this message translates to:
  /// **'Paired with {name}. The first sync starts automatically.'**
  String devicesPairedBanner(String name);

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Pair another'**
  String get devicesPairAnother;

  /// Tooltip.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get devicesDismiss;

  /// Title of This device without an identity.
  ///
  /// In en, this message translates to:
  /// **'Networking is not set up'**
  String get devicesNetworkingMissing;

  /// Snackbar.
  ///
  /// In en, this message translates to:
  /// **'ID copied'**
  String get devicesIdCopied;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Copy ID'**
  String get devicesCopyId;

  /// Reset row subtitle.
  ///
  /// In en, this message translates to:
  /// **'Abandon the dataset here to create a new one or join another device\'s. Your device identity is kept.'**
  String get devicesResetBody;

  /// Details label.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get devicesFactState;

  /// Details label.
  ///
  /// In en, this message translates to:
  /// **'Endpoint'**
  String get devicesFactEndpoint;

  /// Details label.
  ///
  /// In en, this message translates to:
  /// **'Last attempt'**
  String get devicesFactLastAttempt;

  /// Details label.
  ///
  /// In en, this message translates to:
  /// **'Sync port'**
  String get devicesFactSyncPort;

  /// Sync port not bound.
  ///
  /// In en, this message translates to:
  /// **'not bound'**
  String get devicesNotBound;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get devicesReconnect;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Copy log'**
  String get devicesCopyLog;

  /// Log heading.
  ///
  /// In en, this message translates to:
  /// **'Connection log · {count, plural, =1{1 event} other{{count} events}}'**
  String devicesLogHeading(int count);

  /// Log filter.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get devicesLogAll;

  /// Log filter.
  ///
  /// In en, this message translates to:
  /// **'Pairing'**
  String get devicesLogPairing;

  /// Log filter.
  ///
  /// In en, this message translates to:
  /// **'Peer'**
  String get devicesLogPeer;

  /// Empty log.
  ///
  /// In en, this message translates to:
  /// **'No events.'**
  String get devicesNoEvents;

  /// Pairing card title.
  ///
  /// In en, this message translates to:
  /// **'Pair a device'**
  String get pairingTitle;

  /// Idle body.
  ///
  /// In en, this message translates to:
  /// **'Pairing is off. Start it only when both devices are nearby.'**
  String get pairingIdleBody;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Start pairing'**
  String get pairingStart;

  /// Note shown while Discoverable is off.
  ///
  /// In en, this message translates to:
  /// **'Discovery is off — pairing still works.'**
  String get pairingDiscoveryOffNote;

  /// Shown when every candidate is already paired.
  ///
  /// In en, this message translates to:
  /// **'All nearby devices are already paired.'**
  String get pairingAlreadyPaired;

  /// No candidates.
  ///
  /// In en, this message translates to:
  /// **'No nearby pairing candidates yet.'**
  String get pairingNoCandidates;

  /// Candidate action.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get pairingConnect;

  /// Button that leaves pairing mode.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get pairingStop;

  /// State.
  ///
  /// In en, this message translates to:
  /// **'Connecting securely…'**
  String get pairingConnecting;

  /// State.
  ///
  /// In en, this message translates to:
  /// **'Device paired successfully.'**
  String get pairingSuccess;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Pair another device'**
  String get pairingAnother;

  /// Button.
  ///
  /// In en, this message translates to:
  /// **'Pair a different device'**
  String get pairingDifferentDevice;

  /// Failure.
  ///
  /// In en, this message translates to:
  /// **'Your login keyring is locked, so this device could not save the pairing. Unlock the keyring, then retry — the other device may already show this one as paired.'**
  String get pairingKeyringLocked;

  /// Reset lead.
  ///
  /// In en, this message translates to:
  /// **'To join the other device\'s dataset, this device\'s local data must be reset first.'**
  String get pairingResetLead;

  /// Dialog title.
  ///
  /// In en, this message translates to:
  /// **'Reset this device\'s data?'**
  String get resetTitle;

  /// Trusted-device count in the reset confirmation.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No trusted devices are recorded.} =1{1 trusted device is kept and can be paired again.} other{{count} trusted devices are kept and can be paired again.}}'**
  String resetTrustedCount(int count);

  /// Destructive reset action.
  ///
  /// In en, this message translates to:
  /// **'Reset data'**
  String get resetConfirm;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get fieldTypeText;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Integer'**
  String get fieldTypeInteger;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Decimal'**
  String get fieldTypeDecimal;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Boolean'**
  String get fieldTypeBoolean;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get fieldTypeDate;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Date & time'**
  String get fieldTypeDateTime;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get fieldTypeDuration;

  /// Field kind name
  ///
  /// In en, this message translates to:
  /// **'Choice'**
  String get fieldTypeChoice;

  /// Boolean value option
  ///
  /// In en, this message translates to:
  /// **'True'**
  String get inputTrue;

  /// Boolean value option
  ///
  /// In en, this message translates to:
  /// **'False'**
  String get inputFalse;

  /// Date input hint on phones
  ///
  /// In en, this message translates to:
  /// **'Pick a date'**
  String get inputPickDate;

  /// Date-time input hint on phones
  ///
  /// In en, this message translates to:
  /// **'Pick date & time'**
  String get inputPickDateTime;

  /// Quick action filling today's date
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get inputToday;

  /// Quick action filling the current time
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get inputNow;

  /// Hint of an empty value input
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get inputEmpty;

  /// Collection menu item
  ///
  /// In en, this message translates to:
  /// **'Import CSV…'**
  String get collectionsImportCsv;

  /// Collection menu item
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get collectionsExportCsv;

  /// Collection menu item
  ///
  /// In en, this message translates to:
  /// **'Export JSON'**
  String get collectionsExportJson;

  /// Delete action that asks first
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get collectionsDeleteEllipsis;

  /// Sort order
  ///
  /// In en, this message translates to:
  /// **'Last edited'**
  String get collectionsSortLastEdited;

  /// Sort order / name label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get collectionsSortName;

  /// Sort menu tooltip
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get collectionsSort;

  /// Collections list header
  ///
  /// In en, this message translates to:
  /// **'Collections'**
  String get collectionsTitle;

  /// Transfer menu tooltip
  ///
  /// In en, this message translates to:
  /// **'Import and export'**
  String get collectionsImportExport;

  /// Transfer menu item
  ///
  /// In en, this message translates to:
  /// **'Import JSON…'**
  String get collectionsImportJson;

  /// Transfer menu item
  ///
  /// In en, this message translates to:
  /// **'Export all'**
  String get collectionsExportAll;

  /// Transfer menu item
  ///
  /// In en, this message translates to:
  /// **'Export selected…'**
  String get collectionsExportSelected;

  /// Button and dialog title
  ///
  /// In en, this message translates to:
  /// **'New collection'**
  String get collectionsNewCollection;

  /// Empty list
  ///
  /// In en, this message translates to:
  /// **'Create a collection to start shaping your data.'**
  String get collectionsEmpty;

  /// Record count
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record} other{{count} records}}'**
  String collectionsRecordCount(int count);

  /// Field count
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 field} other{{count} fields}}'**
  String collectionsFieldCount(int count);

  /// Incomplete record count
  ///
  /// In en, this message translates to:
  /// **'{count} incomplete'**
  String collectionsIncomplete(int count);

  /// Subtitle part
  ///
  /// In en, this message translates to:
  /// **'edited {time}'**
  String collectionsEditedLower(String time);

  /// Row menu tooltip
  ///
  /// In en, this message translates to:
  /// **'Collection actions'**
  String get collectionsActions;

  /// Snackbar
  ///
  /// In en, this message translates to:
  /// **'Exported to {name}'**
  String collectionsExportedTo(String name);

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Export collections'**
  String get collectionsExportTitle;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String collectionsDeleteTitle(String name);

  /// Delete dialog body
  ///
  /// In en, this message translates to:
  /// **'Its records, widgets and saved queries are deleted with it.'**
  String get collectionsDeleteGeneric;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Rename collection'**
  String get collectionsRenameTitle;

  /// Input label
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get collectionsDescription;

  /// Default name of a copy
  ///
  /// In en, this message translates to:
  /// **'{name} (copy)'**
  String collectionsCopyName(String name);

  /// Delete sentence part
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record} other{{count} records}}'**
  String collectionsContentsRecords(int count);

  /// Delete sentence part
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 widget} other{{count} widgets}}'**
  String collectionsContentsWidgets(int count);

  /// Delete sentence part
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 saved query} other{{count} saved queries}}'**
  String collectionsContentsSavedQueries(int count);

  /// Delete dialog body
  ///
  /// In en, this message translates to:
  /// **'This collection is empty.'**
  String get collectionsContentsEmpty;

  /// List join
  ///
  /// In en, this message translates to:
  /// **'{list} and {last}'**
  String collectionsContentsJoin(String list, String last);

  /// Delete dialog body
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{{list} is deleted with it.} other{{list} are deleted with it.}}'**
  String collectionsContentsDeleted(int total, String list);

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Back to collections'**
  String get recordsBackToCollections;

  /// Breadcrumb
  ///
  /// In en, this message translates to:
  /// **'Collections  /'**
  String get recordsBreadcrumb;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Schema'**
  String get recordsSchema;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Queries'**
  String get recordsQueries;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get recordsSelect;

  /// Button and title
  ///
  /// In en, this message translates to:
  /// **'New record'**
  String get recordsNewRecord;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get recordsMoreActions;

  /// Menu item
  ///
  /// In en, this message translates to:
  /// **'Select records'**
  String get recordsSelectRecords;

  /// Menu item
  ///
  /// In en, this message translates to:
  /// **'Collection actions…'**
  String get recordsCollectionActions;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Records'**
  String get recordsSection;

  /// Empty state
  ///
  /// In en, this message translates to:
  /// **'No records yet.'**
  String get recordsEmpty;

  /// Floating button label
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get recordsFab;

  /// Card footer
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{+ 1 more field} other{+ {count} more fields}}'**
  String recordsMoreFields(int count);

  /// Tag on a record a clone just created
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get recordsCloneBadge;

  /// Semantics label of the Clone tag
  ///
  /// In en, this message translates to:
  /// **'Recently cloned'**
  String get recordsCloneBadgeSemantics;

  /// Tag
  ///
  /// In en, this message translates to:
  /// **'Incomplete'**
  String get recordsIncomplete;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Delete record'**
  String get recordsDeleteRecord;

  /// Sheet title
  ///
  /// In en, this message translates to:
  /// **'Collection schema'**
  String get recordsSchemaTitle;

  /// Footer note
  ///
  /// In en, this message translates to:
  /// **'Long-press to reorder'**
  String get recordsReorderPhone;

  /// Footer note
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder · click a field to edit'**
  String get recordsReorderDesktop;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Add field'**
  String get recordsAddField;

  /// Computed field note
  ///
  /// In en, this message translates to:
  /// **'Made by a newer version (expression v{version}); not editable here'**
  String recordsComputedNewer(String version);

  /// Computed field note
  ///
  /// In en, this message translates to:
  /// **'Uses operations this editor does not offer; not editable here'**
  String get recordsComputedUnsupported;

  /// Computed field tag part
  ///
  /// In en, this message translates to:
  /// **'may be empty'**
  String get recordsMayBeEmpty;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Edit computed field'**
  String get recordsEditComputed;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove computed field'**
  String get recordsRemoveComputed;

  /// Sheet title
  ///
  /// In en, this message translates to:
  /// **'Computed fields & queries'**
  String get recordsComputedSheetTitle;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Computed fields'**
  String get recordsComputedFields;

  /// Section description
  ///
  /// In en, this message translates to:
  /// **'Calculated per record from other fields.'**
  String get recordsComputedFieldsHint;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Add computed field'**
  String get recordsAddComputed;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Saved queries'**
  String get recordsSavedQueries;

  /// Section description
  ///
  /// In en, this message translates to:
  /// **'Aggregates across records. Widgets can reuse them.'**
  String get recordsSavedQueriesHint;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Edit query'**
  String get recordsEditQuery;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove query'**
  String get recordsRemoveQuery;

  /// Query usage
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{used by no widgets} =1{used by 1 widget} other{used by {count} widgets}}'**
  String recordsUsedBy(int count);

  /// Selection count
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String recordsSelected(int count);

  /// Context label
  ///
  /// In en, this message translates to:
  /// **'in {name}'**
  String recordsInCollection(String name);

  /// Select every record the view shows
  ///
  /// In en, this message translates to:
  /// **'{n, plural, other{Select all {n}}}'**
  String recordsSelectAll(int n);

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Edit field'**
  String get recordsEditField;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete {count} records?'**
  String recordsBatchDeleteTitle(int count);

  /// Dialog body
  ///
  /// In en, this message translates to:
  /// **'Every selected record is deleted in one step.'**
  String get recordsBatchDeleteBody;

  /// Toast after a batch delete
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Deleted 1 record} other{Deleted {count} records}}'**
  String recordsDeletedSnack(int count);

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Set {field} on {count} records?'**
  String recordsBatchSetTitle(String field, int count);

  /// Dialog body
  ///
  /// In en, this message translates to:
  /// **'Every selected record is updated in one step.'**
  String get recordsBatchSetBody;

  /// Form title
  ///
  /// In en, this message translates to:
  /// **'Edit field on {count} records'**
  String recordsBatchEditTitle(int count);

  /// Input label
  ///
  /// In en, this message translates to:
  /// **'Field'**
  String get recordsField;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get recordsContinue;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Discard this record?'**
  String get recordDiscardTitle;

  /// Dialog body
  ///
  /// In en, this message translates to:
  /// **'Voice processing will stop and the fields you changed will be lost.'**
  String get recordDiscardBody;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get recordDiscard;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get recordKeepEditing;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete this record?'**
  String get recordDeleteTitle;

  /// Dialog body
  ///
  /// In en, this message translates to:
  /// **'It is removed from the collection.'**
  String get recordDeleteBody;

  /// Context label part
  ///
  /// In en, this message translates to:
  /// **'created {date}'**
  String recordCreated(String date);

  /// Form title
  ///
  /// In en, this message translates to:
  /// **'Edit record'**
  String get recordEditTitle;

  /// Form title with missing count
  ///
  /// In en, this message translates to:
  /// **'{title} · {count, plural, =1{1 field needed} other{{count} fields needed}}'**
  String recordTitleNeeded(String title, int count);

  /// Footer hint
  ///
  /// In en, this message translates to:
  /// **'* Required · Ctrl+Enter to save'**
  String get recordFooterHint;

  /// Menu item
  ///
  /// In en, this message translates to:
  /// **'Delete record…'**
  String get recordDeleteRecordEllipsis;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Save record'**
  String get recordSave;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get recordSaveChanges;

  /// Table hint
  ///
  /// In en, this message translates to:
  /// **'Scroll for more columns →'**
  String get recordScrollMore;

  /// Incomplete line
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record is missing a required field} other{{count} records are missing a required field}}'**
  String recordIncompleteLead(int count);

  /// Incomplete line action
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Tap it to finish.} other{Tap one to finish.}}'**
  String recordTapToFinish(int count);

  /// Incomplete line action
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Click it to finish.} other{Click one to finish.}}'**
  String recordClickToFinish(int count);

  /// Error summary
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Couldn\'t save. 1 field needs attention.} other{Couldn\'t save. {count} fields need attention.}}'**
  String formCouldntSave(int count);

  /// Screen reader label
  ///
  /// In en, this message translates to:
  /// **'{name}, required'**
  String formRequiredSemantics(String name);

  /// Legend after the asterisk
  ///
  /// In en, this message translates to:
  /// **' required'**
  String get formRequiredLegend;

  /// Field note
  ///
  /// In en, this message translates to:
  /// **'Needed to complete this record'**
  String get formNeeded;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get widgetDashboard;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Reorder'**
  String get widgetReorder;

  /// Button / title
  ///
  /// In en, this message translates to:
  /// **'Add widget'**
  String get widgetAdd;

  /// Title
  ///
  /// In en, this message translates to:
  /// **'Edit widget'**
  String get widgetEdit;

  /// Empty state
  ///
  /// In en, this message translates to:
  /// **'No widgets yet. Add one to summarize this collection.'**
  String get widgetEmptyDashboard;

  /// Tile summary
  ///
  /// In en, this message translates to:
  /// **'{description} · all records'**
  String widgetAllRecords(String description);

  /// Validation
  ///
  /// In en, this message translates to:
  /// **'Give the widget a title.'**
  String get widgetTitleRequired;

  /// Validation
  ///
  /// In en, this message translates to:
  /// **'Choose a saved query.'**
  String get widgetSavedQueryRequired;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Widget type'**
  String get widgetType;

  /// Unsupported widget type line
  ///
  /// In en, this message translates to:
  /// **'Widget type: {type}'**
  String widgetTypeValue(String type);

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'This build cannot render this widget. Title, query, size, and order stay editable and its configuration is preserved untouched.'**
  String get widgetUnsupportedNotice;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get widgetTitle;

  /// Switch
  ///
  /// In en, this message translates to:
  /// **'Use a saved query'**
  String get widgetUseSavedQuery;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Saved query'**
  String get widgetSavedQuery;

  /// Section
  ///
  /// In en, this message translates to:
  /// **'Presentation'**
  String get widgetPresentation;

  /// Notice
  ///
  /// In en, this message translates to:
  /// **'Configuration version {version} is preserved as is.'**
  String widgetConfigVersionPreserved(String version);

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get widgetSize;

  /// Size segment
  ///
  /// In en, this message translates to:
  /// **'Full'**
  String get widgetSizeFull;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get widgetRemove;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove widget'**
  String get widgetRemoveTooltip;

  /// Preview heading
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get widgetUntitled;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get widgetPreview;

  /// Preview placeholder
  ///
  /// In en, this message translates to:
  /// **'Choose the data to show'**
  String get widgetChooseData;

  /// Size hint
  ///
  /// In en, this message translates to:
  /// **'Small spans 1 of 4 columns.'**
  String get widgetSizeSmallHint;

  /// Size hint
  ///
  /// In en, this message translates to:
  /// **'Medium spans 2 of 4 columns.'**
  String get widgetSizeMediumHint;

  /// Size hint
  ///
  /// In en, this message translates to:
  /// **'Large spans 3 of 4 columns.'**
  String get widgetSizeLargeHint;

  /// Size hint
  ///
  /// In en, this message translates to:
  /// **'Full spans all 4 columns.'**
  String get widgetSizeFullHint;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Unit suffix (optional)'**
  String get widgetUnitSuffix;

  /// Helper
  ///
  /// In en, this message translates to:
  /// **'Shown after the exact value, for example \"EUR\".'**
  String get widgetUnitSuffixHelper;

  /// Switch
  ///
  /// In en, this message translates to:
  /// **'Show points'**
  String get widgetShowPoints;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Y axis label (optional)'**
  String get widgetYAxisLabel;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Bar width (optional)'**
  String get widgetBarWidth;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Point radius (optional)'**
  String get widgetPointRadius;

  /// Widget type name
  ///
  /// In en, this message translates to:
  /// **'Aggregate number'**
  String get widgetTypeAggregateNumber;

  /// Widget type name
  ///
  /// In en, this message translates to:
  /// **'Line chart'**
  String get widgetTypeLineChart;

  /// Widget type name
  ///
  /// In en, this message translates to:
  /// **'Bar chart'**
  String get widgetTypeBarChart;

  /// Widget type name
  ///
  /// In en, this message translates to:
  /// **'Scatter plot'**
  String get widgetTypeScatterPlot;

  /// Voice tip title and mic label
  ///
  /// In en, this message translates to:
  /// **'Fill by voice'**
  String get voiceFillByVoice;

  /// Voice tip line
  ///
  /// In en, this message translates to:
  /// **'Tap the mic below and say the details. You review before saving.'**
  String get voiceTipLine;

  /// Tooltip to dismiss the voice tip
  ///
  /// In en, this message translates to:
  /// **'Dismiss tip'**
  String get voiceDismissTip;

  /// Primer title
  ///
  /// In en, this message translates to:
  /// **'Speak to fill records'**
  String get voicePrimerTitle;

  /// Voice privacy line
  ///
  /// In en, this message translates to:
  /// **'Audio is processed on this device and never saved.'**
  String get voicePrivacyLine;

  /// Primer line
  ///
  /// In en, this message translates to:
  /// **'Next, Android will ask for microphone access.'**
  String get voicePrimerNext;

  /// Not now button
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get voiceNotNow;

  /// Continue button
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get voiceContinue;

  /// Semantics label of the download bar
  ///
  /// In en, this message translates to:
  /// **'Download progress'**
  String get voiceDownloadProgressLabel;

  /// Listening panel title
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get voiceListening;

  /// Listening hint with an example utterance.
  ///
  /// In en, this message translates to:
  /// **'Try: “{example}”'**
  String voiceTry(String example);

  /// Listening hint
  ///
  /// In en, this message translates to:
  /// **'Tap stop when done, or hold the mic to talk'**
  String get voiceListeningHint;

  /// Semantics label while filling
  ///
  /// In en, this message translates to:
  /// **'Filling fields'**
  String get voiceFillingFields;

  /// Semantics label while transcribing
  ///
  /// In en, this message translates to:
  /// **'Transcribing'**
  String get voiceTranscribing;

  /// Processing step done
  ///
  /// In en, this message translates to:
  /// **'Transcribed'**
  String get voiceTranscribed;

  /// Processing step
  ///
  /// In en, this message translates to:
  /// **'Transcribing…'**
  String get voiceTranscribingStep;

  /// Processing step
  ///
  /// In en, this message translates to:
  /// **'Filling fields…'**
  String get voiceFillingFieldsStep;

  /// Processing duration hint
  ///
  /// In en, this message translates to:
  /// **'Usually 4–8 seconds'**
  String get voiceUsuallySeconds;

  /// Heard toggle
  ///
  /// In en, this message translates to:
  /// **'Heard'**
  String get voiceHeard;

  /// A voice transcript in quotes, on the processing panel and the Nothing matched panel's Heard block.
  ///
  /// In en, this message translates to:
  /// **'“{transcript}”'**
  String voiceQuotedTranscript(String transcript);

  /// Heard popover label
  ///
  /// In en, this message translates to:
  /// **'HEARD'**
  String get voiceHeardCaps;

  /// Semantics label of the heard popover
  ///
  /// In en, this message translates to:
  /// **'What was heard'**
  String get voiceWhatWasHeard;

  /// Clear field button
  ///
  /// In en, this message translates to:
  /// **'Clear field'**
  String get voiceClearField;

  /// Ordinal 1
  ///
  /// In en, this message translates to:
  /// **'1st'**
  String get voiceOrdinalFirst;

  /// Ordinal 2
  ///
  /// In en, this message translates to:
  /// **'2nd'**
  String get voiceOrdinalSecond;

  /// Ordinal 3
  ///
  /// In en, this message translates to:
  /// **'3rd'**
  String get voiceOrdinalThird;

  /// Ordinal n
  ///
  /// In en, this message translates to:
  /// **'{n}th'**
  String voiceOrdinalOther(int n);

  /// Filled fields count
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Filled 1 field} other{Filled {count} fields}}'**
  String voiceFilledCount(int count);

  /// Filled panel hint
  ///
  /// In en, this message translates to:
  /// **'Check the fields, then save.'**
  String get voiceCheckThenSave;

  /// Speak again button
  ///
  /// In en, this message translates to:
  /// **'Speak again'**
  String get voiceSpeakAgain;

  /// Asking round
  ///
  /// In en, this message translates to:
  /// **'{round} of {max}'**
  String voiceRound(int round, int max);

  /// Need panel line
  ///
  /// In en, this message translates to:
  /// **'{filled}. Say the rest, or type into the marked fields.'**
  String voiceNeedLine(String filled);

  /// Answer by voice button
  ///
  /// In en, this message translates to:
  /// **'Answer by voice'**
  String get voiceAnswerByVoice;

  /// Exhausted headline
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t get the {fields}'**
  String voiceCouldntGet(String fields);

  /// Exhausted line
  ///
  /// In en, this message translates to:
  /// **'Type it in the marked field, then save. The mic still works if you want to try again.'**
  String get voiceExhaustedLine;

  /// Follow-up headline
  ///
  /// In en, this message translates to:
  /// **'Updated {fields}'**
  String voiceUpdated(String fields);

  /// Speaking panel label
  ///
  /// In en, this message translates to:
  /// **'Speaking'**
  String get voiceSpeaking;

  /// Mute tooltip
  ///
  /// In en, this message translates to:
  /// **'Mute spoken feedback'**
  String get voiceMute;

  /// Dismiss button
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get voiceDismiss;

  /// Open settings button
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get voiceOpenSettings;

  /// Settings button
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get voiceSettings;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Didn\'t hear anything'**
  String get voiceErrorNoSpeechTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Check the mic isn\'t covered, then try again.'**
  String get voiceErrorNoSpeechLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Nothing matched'**
  String get voiceErrorNothingMatchedTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'I couldn\'t match anything to this collection\'s fields. Try naming a field, like “amount 12.50”.'**
  String get voiceErrorNothingMatchedLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Microphone access is off'**
  String get voiceErrorPermissionDeniedTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Allow microphone access in Android settings to fill by voice. You can keep typing.'**
  String get voiceErrorPermissionDeniedLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Microphone is busy'**
  String get voiceErrorMicBusyTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Another app is using the microphone. Close it, then try again.'**
  String get voiceErrorMicBusyLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Voice model couldn\'t load'**
  String get voiceErrorModelLoadFailedTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'The model file may be damaged. Retry, or re-download it in Settings.'**
  String get voiceErrorModelLoadFailedLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Not enough memory'**
  String get voiceErrorLowMemoryTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Close other apps and try again. Your form is kept.'**
  String get voiceErrorLowMemoryLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Recording stopped'**
  String get voiceErrorInterruptedBackgroundTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Fi went to the background, so recording stopped. Nothing was kept.'**
  String get voiceErrorInterruptedBackgroundLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Stopped for a call'**
  String get voiceErrorInterruptedCallTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Recording stopped when a call came in. Nothing was kept.'**
  String get voiceErrorInterruptedCallLine;

  /// Error title
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get voiceErrorCancelledTitle;

  /// Error line
  ///
  /// In en, this message translates to:
  /// **'Nothing was kept.'**
  String get voiceErrorCancelledLine;

  /// Mic label
  ///
  /// In en, this message translates to:
  /// **'Stop listening'**
  String get voiceMicStopListening;

  /// Mic label
  ///
  /// In en, this message translates to:
  /// **'Processing speech'**
  String get voiceMicProcessing;

  /// Mic label
  ///
  /// In en, this message translates to:
  /// **'Voice model downloading, {percent} percent'**
  String voiceMicDownloading(int percent);

  /// Settings page title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Desktop settings subtitle
  ///
  /// In en, this message translates to:
  /// **'Preferences for this computer.'**
  String get settingsSubtitle;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get settingsVoiceInput;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Microphone'**
  String get settingsMicrophone;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// About row
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get settingsVersion;

  /// About row
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsNetwork;

  /// Network summary; numbers are ports
  ///
  /// In en, this message translates to:
  /// **'Local network and tailnet · UDP {first}–{last} · mDNS {mdns}'**
  String settingsNetworkSummary(int first, int last, int mdns);

  /// Microphone row
  ///
  /// In en, this message translates to:
  /// **'Microphone access'**
  String get settingsMicAccess;

  /// Mic status
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get settingsMicAllowed;

  /// Mic status
  ///
  /// In en, this message translates to:
  /// **'Not allowed yet'**
  String get settingsMicNotAllowed;

  /// Mic detail
  ///
  /// In en, this message translates to:
  /// **'Fi asks the first time you use voice.'**
  String get settingsMicAsksFirst;

  /// Mic status
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingsMicOff;

  /// Mic detail
  ///
  /// In en, this message translates to:
  /// **'Turn it on in Android settings to fill by voice.'**
  String get settingsMicTurnOn;

  /// Mic status
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get settingsMicUnknown;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Android settings'**
  String get settingsAndroidSettings;

  /// Hands-free row
  ///
  /// In en, this message translates to:
  /// **'Hands-free spoken feedback'**
  String get settingsHandsFree;

  /// Hands-free detail
  ///
  /// In en, this message translates to:
  /// **'Speaks the “still need” question and a short confirmation'**
  String get settingsHandsFreeDetail;

  /// Snackbar
  ///
  /// In en, this message translates to:
  /// **'Not enough storage: {size} needed.'**
  String settingsNotEnoughStorage(String size);

  /// Snackbar
  ///
  /// In en, this message translates to:
  /// **'Finish the voice fill in progress first.'**
  String get settingsFinishVoiceFirst;

  /// Snackbar
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change the voice models. Try again.'**
  String get settingsCouldntChangeModels;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Multiline'**
  String get fieldEditorChipMultiline;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Length limits'**
  String get fieldEditorChipLengthLimits;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Range'**
  String get fieldEditorChipRange;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Show as slider'**
  String get fieldEditorChipSlider;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Date range'**
  String get fieldEditorChipDateRange;

  /// Field editor option chip
  ///
  /// In en, this message translates to:
  /// **'Default value'**
  String get fieldEditorChipDefaultValue;

  /// Schema row detail for a multiline text field
  ///
  /// In en, this message translates to:
  /// **'multiline'**
  String get fieldEditorSummaryMultiline;

  /// Schema row detail: decimal places of a decimal field
  ///
  /// In en, this message translates to:
  /// **'{scale} dp'**
  String fieldEditorSummaryScale(int scale);

  /// Length constraint with only a minimum
  ///
  /// In en, this message translates to:
  /// **'at least {min}'**
  String fieldEditorAtLeast(int min);

  /// Length constraint with only a maximum
  ///
  /// In en, this message translates to:
  /// **'at most {max}'**
  String fieldEditorAtMost(int max);

  /// Tooltip closing an option block
  ///
  /// In en, this message translates to:
  /// **'Turn off {option}'**
  String fieldEditorTurnOff(String option);

  /// Slider step error
  ///
  /// In en, this message translates to:
  /// **'Step must be a positive whole number'**
  String get fieldEditorStepPositive;

  /// Slider step error
  ///
  /// In en, this message translates to:
  /// **'Step must divide the range.'**
  String get fieldEditorStepDivides;

  /// Closes a help popup
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get helpGotIt;

  /// Field summary suffix for an Integer shown as a slider
  ///
  /// In en, this message translates to:
  /// **'slider'**
  String get fieldSummarySlider;

  /// Default length error
  ///
  /// In en, this message translates to:
  /// **'Default must be exactly {min} characters.'**
  String fieldEditorDefaultExactLength(int min);

  /// Default length error
  ///
  /// In en, this message translates to:
  /// **'Default must be {min}–{max} characters.'**
  String fieldEditorDefaultLengthBetween(int min, int max);

  /// Default length error
  ///
  /// In en, this message translates to:
  /// **'Default must be at least {min} characters.'**
  String fieldEditorDefaultMinLength(int min);

  /// Default length error
  ///
  /// In en, this message translates to:
  /// **'Default must be at most {max} characters.'**
  String fieldEditorDefaultMaxLength(int max);

  /// Default range error
  ///
  /// In en, this message translates to:
  /// **'Default must be between {low} and {high}.'**
  String fieldEditorDefaultBetween(String low, String high);

  /// Default range error
  ///
  /// In en, this message translates to:
  /// **'Default must be at least {low}.'**
  String fieldEditorDefaultAtLeast(String low);

  /// Default range error
  ///
  /// In en, this message translates to:
  /// **'Default must be at most {high}.'**
  String fieldEditorDefaultAtMost(String high);

  /// Confirmation dialog title
  ///
  /// In en, this message translates to:
  /// **'Make “{name}” required?'**
  String fieldEditorMakeRequiredTitle(String name);

  /// Confirmation dialog body
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record has no value and will be marked incomplete.} other{{count} records have no value and will be marked incomplete.}}'**
  String fieldEditorMakeRequiredBody(int count);

  /// Confirm button
  ///
  /// In en, this message translates to:
  /// **'Make required'**
  String get fieldEditorMakeRequired;

  /// Safe button of the make-required confirm
  ///
  /// In en, this message translates to:
  /// **'Keep optional'**
  String get fieldEditorKeepOptional;

  /// Dialog title deleting a used option
  ///
  /// In en, this message translates to:
  /// **'Delete option “{label}”?'**
  String fieldEditorDeleteOptionTitle(String label);

  /// Dialog body deleting a used option
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record uses it and keeps it. It can\'t be picked for new records.} other{{count} records use it and keep it. It can\'t be picked for new records.}}'**
  String fieldEditorDeleteOptionBody(int count);

  /// Safe button of the delete-option confirm
  ///
  /// In en, this message translates to:
  /// **'Keep option'**
  String get fieldEditorKeepOption;

  /// Field editor header
  ///
  /// In en, this message translates to:
  /// **'New field'**
  String get fieldEditorNewField;

  /// Field name input label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get fieldEditorName;

  /// Field name input hint
  ///
  /// In en, this message translates to:
  /// **'e.g. note'**
  String get fieldEditorNameHint;

  /// Section label
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get fieldEditorType;

  /// Input label
  ///
  /// In en, this message translates to:
  /// **'Decimal scale'**
  String get fieldEditorDecimalScale;

  /// Hint under chips
  ///
  /// In en, this message translates to:
  /// **'Show as slider needs a range with both ends.'**
  String get fieldEditorSliderNeedsRange;

  /// Save button for a new field
  ///
  /// In en, this message translates to:
  /// **'Add field'**
  String get fieldEditorAddField;

  /// Save button for an existing field
  ///
  /// In en, this message translates to:
  /// **'Save field'**
  String get fieldEditorSaveField;

  /// Delete field action
  ///
  /// In en, this message translates to:
  /// **'Delete field'**
  String get fieldEditorDeleteField;

  /// Delete-field confirm title
  ///
  /// In en, this message translates to:
  /// **'Delete field “{name}”?'**
  String fieldEditorDeleteFieldTitle(String name);

  /// Delete-field confirm body; count is records holding a value
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Removes the field from the schema.} =1{Removes the field from the schema. 1 record loses its value for it.} other{Removes the field from the schema. {count} records lose their value for it.}}'**
  String fieldEditorDeleteFieldBody(int count);

  /// Safe button of the delete-field confirm
  ///
  /// In en, this message translates to:
  /// **'Keep field'**
  String get fieldEditorKeepField;

  /// Tooltip of a schema row delete icon
  ///
  /// In en, this message translates to:
  /// **'Delete field {name}'**
  String fieldEditorDeleteFieldNamed(String name);

  /// Warning when turning Required on
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record has no value for this field and will be marked incomplete.} other{{count} records have no value for this field and will be marked incomplete.}}'**
  String fieldEditorRequiredWarning(int count);

  /// Input label
  ///
  /// In en, this message translates to:
  /// **'Min characters'**
  String get fieldEditorMinCharacters;

  /// Input label
  ///
  /// In en, this message translates to:
  /// **'Max characters'**
  String get fieldEditorMaxCharacters;

  /// Date range lower bound label
  ///
  /// In en, this message translates to:
  /// **'Earliest'**
  String get fieldEditorEarliest;

  /// Date range upper bound label
  ///
  /// In en, this message translates to:
  /// **'Latest'**
  String get fieldEditorLatest;

  /// Range lower bound label
  ///
  /// In en, this message translates to:
  /// **'Minimum'**
  String get fieldEditorMinimum;

  /// Range upper bound label
  ///
  /// In en, this message translates to:
  /// **'Maximum'**
  String get fieldEditorMaximum;

  /// Slider step input label
  ///
  /// In en, this message translates to:
  /// **'Step (optional)'**
  String get fieldEditorStepOptional;

  /// Default slot label for a date field
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get fieldEditorDate;

  /// Default slot label
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get fieldEditorDefault;

  /// Relative date default mode
  ///
  /// In en, this message translates to:
  /// **'Day of creation'**
  String get fieldEditorDayOfCreation;

  /// Fixed date default mode
  ///
  /// In en, this message translates to:
  /// **'Fixed date'**
  String get fieldEditorFixedDate;

  /// Unit after a relative day count
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get fieldEditorDays;

  /// Section label with option count
  ///
  /// In en, this message translates to:
  /// **'Options · {count}'**
  String fieldEditorOptionsCount(int count);

  /// Example option name when none was deleted
  ///
  /// In en, this message translates to:
  /// **'option'**
  String get fieldEditorOptionFallback;

  /// Option input hint
  ///
  /// In en, this message translates to:
  /// **'Option label'**
  String get fieldEditorOptionLabel;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Delete option'**
  String get fieldEditorDeleteOption;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Add option'**
  String get fieldEditorAddOption;

  /// Note under the options list
  ///
  /// In en, this message translates to:
  /// **'Records that already use a deleted option keep it. It shows as “{example} (deleted)” and can\'t be picked for new records.'**
  String fieldEditorDeletedOptionNote(String example);

  /// Field screen subtitle
  ///
  /// In en, this message translates to:
  /// **'Field in {collection}'**
  String fieldEditorFieldIn(String collection);

  /// Overflow menu tooltip
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get fieldEditorMore;

  /// Renderer failure
  ///
  /// In en, this message translates to:
  /// **'This widget could not be rendered: {error}'**
  String widgetCouldNotRender(String error);

  /// Title fallback
  ///
  /// In en, this message translates to:
  /// **'Untitled widget'**
  String get widgetUntitledWidget;

  /// Headline
  ///
  /// In en, this message translates to:
  /// **'Unsupported widget'**
  String get widgetUnsupported;

  /// Unsupported widget explanation
  ///
  /// In en, this message translates to:
  /// **'This widget was created by another device or a newer version. Its configuration is preserved and can be renamed, reordered, or removed.'**
  String get widgetUnsupportedExplanation;

  /// Typed edits kept
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Your edit to {names} was kept.} other{Your edits to {names} were kept.}}'**
  String voiceKept(int count, String names);

  /// Expression leaf issue
  ///
  /// In en, this message translates to:
  /// **'Pick a field.'**
  String get exprPickFieldIssue;

  /// Expression leaf issue
  ///
  /// In en, this message translates to:
  /// **'Enter a whole number.'**
  String get exprWholeNumberIssue;

  /// Expression leaf issue
  ///
  /// In en, this message translates to:
  /// **'Enter a number with at most {scale} decimals.'**
  String exprDecimalsIssue(int scale);

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Integer'**
  String get exprTypeInteger;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Decimal, scale {scale}'**
  String exprTypeDecimal(int scale);

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get exprTypeDuration;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get exprTypeDate;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Date & time'**
  String get exprTypeDateTime;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Boolean'**
  String get exprTypeBoolean;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get exprTypeText;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Choice'**
  String get exprTypeChoice;

  /// Value type
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get exprTypeEmpty;

  /// Formula placeholder
  ///
  /// In en, this message translates to:
  /// **'field?'**
  String get exprSlotField;

  /// Formula placeholder
  ///
  /// In en, this message translates to:
  /// **'number?'**
  String get exprSlotNumber;

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 term still needs a value} other{{count} terms still need a value}}'**
  String exprTermsMissing(int count);

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'Result: not valid, see the highlighted part'**
  String get exprResultInvalid;

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'Result: checking…'**
  String get exprResultChecking;

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'Result: {type}'**
  String exprResultType(String type);

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'Result: {type} · may be empty'**
  String exprResultTypeMaybeEmpty(String type);

  /// Result line
  ///
  /// In en, this message translates to:
  /// **'Result: unknown'**
  String get exprResultUnknown;

  /// Tooltip / chip
  ///
  /// In en, this message translates to:
  /// **'Absolute value'**
  String get exprAbsoluteValue;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Add operator'**
  String get exprAddOperator;

  /// Segment
  ///
  /// In en, this message translates to:
  /// **'Field'**
  String get exprField;

  /// Segment / label
  ///
  /// In en, this message translates to:
  /// **'Number'**
  String get exprNumber;

  /// Segment: the term is a function (absolute value or division)
  ///
  /// In en, this message translates to:
  /// **'Function'**
  String get exprFunction;

  /// Function choice
  ///
  /// In en, this message translates to:
  /// **'Divide'**
  String get exprDivide;

  /// Button appending a term to the formula
  ///
  /// In en, this message translates to:
  /// **'Add term'**
  String get exprAddTerm;

  /// Drag handle tooltip on a term
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder'**
  String get exprDragTerm;

  /// Tooltip of ✕ on a term
  ///
  /// In en, this message translates to:
  /// **'Remove term'**
  String get exprRemoveTerm;

  /// No description provided for @exprCannotAdd.
  ///
  /// In en, this message translates to:
  /// **'Can\'t add a {right} to a {left}.'**
  String exprCannotAdd(String right, String left);

  /// No description provided for @exprCannotSubtract.
  ///
  /// In en, this message translates to:
  /// **'Can\'t subtract a {right} from a {left}.'**
  String exprCannotSubtract(String right, String left);

  /// No description provided for @exprCannotMultiply.
  ///
  /// In en, this message translates to:
  /// **'Can\'t multiply a {left} by a {right}.'**
  String exprCannotMultiply(String left, String right);

  /// No description provided for @exprCannotDivide.
  ///
  /// In en, this message translates to:
  /// **'Can\'t divide a {left} by a {right}.'**
  String exprCannotDivide(String left, String right);

  /// Hint
  ///
  /// In en, this message translates to:
  /// **'Pick a field'**
  String get exprPickField;

  /// Scale option
  ///
  /// In en, this message translates to:
  /// **'Whole'**
  String get exprWhole;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove operator (keep the left side)'**
  String get exprRemoveOperator;

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Scale'**
  String get exprScale;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Fewer decimals'**
  String get exprFewerDecimals;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'More decimals'**
  String get exprMoreDecimals;

  /// Rounding
  ///
  /// In en, this message translates to:
  /// **'Round half to even'**
  String get exprRoundHalfEven;

  /// Absolute value of
  ///
  /// In en, this message translates to:
  /// **'of'**
  String get exprOf;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove absolute value'**
  String get exprRemoveAbsolute;

  /// Title
  ///
  /// In en, this message translates to:
  /// **'New computed field'**
  String get computedNewTitle;

  /// Title
  ///
  /// In en, this message translates to:
  /// **'Edit computed field'**
  String get computedEditTitle;

  /// Context label
  ///
  /// In en, this message translates to:
  /// **'in {collection}'**
  String computedInCollection(String collection);

  /// Label
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get computedName;

  /// Hint
  ///
  /// In en, this message translates to:
  /// **'e.g. difference'**
  String get computedNameHint;

  /// Duration input hint; examples are invariant duration syntax.
  ///
  /// In en, this message translates to:
  /// **'e.g. {first} or {second}'**
  String inputDurationHint(String first, String second);

  /// Duration input error; example is invariant duration syntax.
  ///
  /// In en, this message translates to:
  /// **'Use units like {example}'**
  String inputDurationUnparsed(String example);

  /// Spoken and shown line listing required fields still empty.
  ///
  /// In en, this message translates to:
  /// **'Still need: {names}'**
  String voiceStillNeed(String names);

  /// Spoken line after a voice turn fills fields.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 field filled.} other{{count} fields filled.}} Tap Save record when ready.'**
  String voiceSpokenFilled(int count);

  /// Name of a speech model; language is a language code.
  ///
  /// In en, this message translates to:
  /// **'{language, select, es{Whisper Base (Spanish)} other{Whisper Base (English)}}'**
  String modelSpeechLabel(String language);

  /// Shown instead of a size for a model already stored.
  ///
  /// In en, this message translates to:
  /// **'On this phone'**
  String get modelOnThisPhone;

  /// Download offer when part of the set is stored; language is the language name.
  ///
  /// In en, this message translates to:
  /// **'{language} · {size} to download, one time. Everything runs on this phone.'**
  String modelOfferToDownload(String language, String size);

  /// Status tag when some models of the set are stored.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 model missing} other{{count} models missing}}'**
  String modelMissingTag(int count);

  /// Model card summary when some models are stored.
  ///
  /// In en, this message translates to:
  /// **'{language} · {size} to download'**
  String modelSummaryToDownload(String language, String size);

  /// Label above speech models of other languages.
  ///
  /// In en, this message translates to:
  /// **'Other languages'**
  String get modelOtherLanguages;

  /// Delete speech model dialog title.
  ///
  /// In en, this message translates to:
  /// **'Delete this speech model?'**
  String get modelDeleteSpeechTitle;

  /// Delete speech model dialog body.
  ///
  /// In en, this message translates to:
  /// **'Frees {size}. {language} voice input won\'t work until you download it again.'**
  String modelDeleteSpeechBody(String size, String language);

  /// Button that keeps the speech model.
  ///
  /// In en, this message translates to:
  /// **'Keep model'**
  String get modelKeepModel;

  /// Settings line when the speech model of the voice language is missing; language is the language name, lang its code.
  ///
  /// In en, this message translates to:
  /// **'Voice input: {language} — needs {lang, select, es{Spanish} other{English}} speech model ({size})'**
  String voiceNeedsSpeechModel(String language, String lang, String size);

  /// Language section line about voice input.
  ///
  /// In en, this message translates to:
  /// **'Voice input follows the app language'**
  String get langVoiceFollows;

  /// Language section line when the voice models are ready.
  ///
  /// In en, this message translates to:
  /// **'Voice input follows the app language · {lang, select, es{Spanish} other{English}} models ready'**
  String langVoiceReady(String lang);

  /// Language section offer title.
  ///
  /// In en, this message translates to:
  /// **'Download {lang, select, es{Spanish} other{English}} speech model · {size}'**
  String langVoiceOfferTitle(String lang, String size);

  /// Language section offer body.
  ///
  /// In en, this message translates to:
  /// **'Voice input follows the app language. Understanding ({size}) is already on this phone.'**
  String langVoiceOfferBody(String size);

  /// Button that downloads the speech model the app language needs.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get langVoiceDownload;

  /// Error tag on a device row whose last connection attempt failed to reach it.
  ///
  /// In en, this message translates to:
  /// **'Not reachable'**
  String get peerNotReachable;

  /// Error tag on a device row whose last attempt failed a trust or TLS check.
  ///
  /// In en, this message translates to:
  /// **'Can\'t verify'**
  String get peerCantVerify;

  /// Problem line when no address is known for the device.
  ///
  /// In en, this message translates to:
  /// **'Not found on your network'**
  String get peerNotFound;

  /// Problem line when the device did not answer at the address tried.
  ///
  /// In en, this message translates to:
  /// **'Didn\'t answer at its last address'**
  String get peerNoAnswer;

  /// Problem line after a trust or TLS failure.
  ///
  /// In en, this message translates to:
  /// **'It no longer recognizes this device'**
  String get peerNotRecognized;

  /// Device row line combining the problem and when it last synced.
  ///
  /// In en, this message translates to:
  /// **'{problem} · Last synced {time}'**
  String peerLastSynced(String problem, String time);

  /// Device row line for a problem device that never synced.
  ///
  /// In en, this message translates to:
  /// **'{problem} · Never synced'**
  String peerNeverSynced(String problem);

  /// Guidance under a device that cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Make sure both devices are on the same Wi-Fi and Fi is open on the other device. Fi keeps trying on its own.'**
  String get peerGuidanceReach;

  /// Guidance under a device that cannot be verified.
  ///
  /// In en, this message translates to:
  /// **'The other device may have been reset or may have unpaired this one. Pair again on both devices.'**
  String get peerGuidanceVerify;

  /// Button that retries the connection to a device now.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get peerTryAgain;

  /// Button that starts pairing mode again.
  ///
  /// In en, this message translates to:
  /// **'Pair again'**
  String get peerPairAgain;

  /// Button that opens the Connect by address dialog.
  ///
  /// In en, this message translates to:
  /// **'Connect by address…'**
  String get peerConnectByAddress;

  /// Title of the Connect by address dialog.
  ///
  /// In en, this message translates to:
  /// **'Connect by address'**
  String get connectAddressTitle;

  /// Lead line of the Connect by address dialog, naming the device.
  ///
  /// In en, this message translates to:
  /// **'Reach {name} directly when it isn\'t found on the network. It must already be paired.'**
  String connectAddressLead(String name);

  /// Label of the address field.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get connectAddressField;

  /// Help line under the address field.
  ///
  /// In en, this message translates to:
  /// **'Find it on the other device under Settings › About › This device.'**
  String get connectAddressHelp;

  /// Button that dials the typed address.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectAddressConnect;

  /// Shown while the dial runs.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectAddressConnecting;

  /// Confirmation after a successful connect by address.
  ///
  /// In en, this message translates to:
  /// **'Connected to {name}'**
  String connectAddressConnected(String name);

  /// Field error for an address that does not parse.
  ///
  /// In en, this message translates to:
  /// **'Enter an IPv4 address like 192.168.0.165, optionally followed by :port.'**
  String get connectAddressInvalid;

  /// Field error for an address outside the local network and tailnet.
  ///
  /// In en, this message translates to:
  /// **'Use an address on your local network or tailnet, like 192.168.x.x or 100.x.x.x.'**
  String get connectAddressNotLocal;

  /// Error when nothing answered at the typed address.
  ///
  /// In en, this message translates to:
  /// **'No answer at {address}. Check the address and that Fi is open on the other device.'**
  String connectAddressNoAnswer(String address);

  /// Error when another device answered at the typed address.
  ///
  /// In en, this message translates to:
  /// **'The device at {address} isn\'t {name}.'**
  String connectAddressWrongDevice(String address, String name);

  /// Error when sync is paused.
  ///
  /// In en, this message translates to:
  /// **'Sync with paired devices is off. Turn it on to connect.'**
  String get connectAddressPaused;

  /// About row listing this device's sync addresses.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get aboutThisDevice;

  /// About row value when this device has neither a local-network nor a tailnet address.
  ///
  /// In en, this message translates to:
  /// **'Not on a local network or tailnet'**
  String get aboutNotOnLocalNetwork;

  /// Confirmation after copying an address.
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get aboutAddressCopied;

  /// Tooltip of the copy-address button.
  ///
  /// In en, this message translates to:
  /// **'Copy address'**
  String get aboutCopyAddress;

  /// Details label of the failure code.
  ///
  /// In en, this message translates to:
  /// **'Failure code'**
  String get devicesFailureCode;

  /// Label of a local-network address in About.
  ///
  /// In en, this message translates to:
  /// **'LAN'**
  String get aboutNetworkLan;

  /// Label of a tailnet address in About.
  ///
  /// In en, this message translates to:
  /// **'Tailnet'**
  String get aboutNetworkTailnet;

  /// Button in the ready voice models card that re-downloads the models.
  ///
  /// In en, this message translates to:
  /// **'Re-download'**
  String get modelRedownloadShort;

  /// Button in the ready voice models card that deletes the models.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get modelDeleteShort;

  /// Voice sheet download card title after a failure.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get modelFailedTitle;

  /// Progress line of a paused or failed download.
  ///
  /// In en, this message translates to:
  /// **'{done} of {total} kept'**
  String modelKeptLine(String done, String total);

  /// Voice sheet download card line while reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Connection lost — the download resumes where it stopped.'**
  String get modelReconnectingResumesLong;

  /// Muted line under the listening hint stating the recording cap.
  ///
  /// In en, this message translates to:
  /// **'Stops on its own after {seconds} seconds.'**
  String voiceListeningCap(int seconds);

  /// Clone collection action
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get collectionsClone;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Clone collection'**
  String get collectionsCloneTitle;

  /// Clone dialog primary
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get collectionsCloneAction;

  /// Export picker line
  ///
  /// In en, this message translates to:
  /// **'Choose what goes in the file'**
  String get collectionsExportLine;

  /// Export picker primary
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Export 1 collection} other{Export {count} collections}}'**
  String collectionsExportCount(int count);

  /// Export picker primary on a phone
  ///
  /// In en, this message translates to:
  /// **'Export {count}'**
  String collectionsExportCountShort(int count);

  /// Menu group label
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get collectionsImportGroup;

  /// Inline rename hint
  ///
  /// In en, this message translates to:
  /// **'Enter to save · Esc to cancel'**
  String get collectionsRenameHint;

  /// Import place: a CSV row and column.
  ///
  /// In en, this message translates to:
  /// **'row {row}, column “{column}”'**
  String importPlaceRowColumn(int row, String column);

  /// Toast action closing an abort
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get outcomeDismiss;

  /// Batch edit value label
  ///
  /// In en, this message translates to:
  /// **'New value'**
  String get recordsNewValue;

  /// Batch edit value helper
  ///
  /// In en, this message translates to:
  /// **'Uses the same control as the record form.'**
  String get recordsNewValueHelp;

  /// Batch set confirm primary
  ///
  /// In en, this message translates to:
  /// **'Set {field}'**
  String recordsSetField(String field);

  /// Batch delete confirm primary
  ///
  /// In en, this message translates to:
  /// **'Keep records'**
  String get recordsKeepRecords;

  /// Toast after a batch set
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Set {field} on 1 record} other{Set {field} on {count} records}}'**
  String recordsSetSnack(String field, int count);

  /// Date range error, minimum only
  ///
  /// In en, this message translates to:
  /// **'Must be on or after {date}'**
  String issueDateMin(String date);

  /// Date range error, maximum only
  ///
  /// In en, this message translates to:
  /// **'Must be on or before {date}'**
  String issueDateMax(String date);

  /// Menu group label
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get collectionsExport;

  /// Import place: a CSV header column.
  ///
  /// In en, this message translates to:
  /// **'the header, column “{column}”'**
  String importPlaceHeaderColumn(String column);

  /// Tooltip of a tile's ⋮ button
  ///
  /// In en, this message translates to:
  /// **'Widget actions'**
  String get widgetMenuTooltip;

  /// Tile menu action
  ///
  /// In en, this message translates to:
  /// **'Remove…'**
  String get widgetMenuRemove;

  /// Confirm title
  ///
  /// In en, this message translates to:
  /// **'Remove widget “{title}”?'**
  String widgetRemoveConfirmTitle(String title);

  /// Confirm body
  ///
  /// In en, this message translates to:
  /// **'Its saved query and the records stay.'**
  String get widgetRemoveConfirmBody;

  /// Confirm safe action
  ///
  /// In en, this message translates to:
  /// **'Keep widget'**
  String get widgetKeep;

  /// Reorder mode button
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get widgetMoveUp;

  /// Reorder mode button
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get widgetMoveDown;

  /// Drag handle tooltip
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder'**
  String get widgetDragToReorder;

  /// Empty widget tile
  ///
  /// In en, this message translates to:
  /// **'No records match yet'**
  String get widgetNoRecordsMatch;

  /// Widget form section heading
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get widgetData;

  /// Query source segment
  ///
  /// In en, this message translates to:
  /// **'Define here'**
  String get widgetDefineHere;

  /// Label above the filter row
  ///
  /// In en, this message translates to:
  /// **'Only records where'**
  String get queryOnlyRecordsWhere;

  /// Equality operator inside a filter chip
  ///
  /// In en, this message translates to:
  /// **'is'**
  String get queryOpIs;

  /// Filter condition chip, e.g. Type is headache
  ///
  /// In en, this message translates to:
  /// **'{field} {operator} {value}'**
  String queryFilterChip(String field, String operator, String value);

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Add filter'**
  String get queryAddFilter;

  /// Button / tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove filter'**
  String get queryRemoveFilter;

  /// Button
  ///
  /// In en, this message translates to:
  /// **'Add query'**
  String get recordsAddQuery;

  /// Query editor title
  ///
  /// In en, this message translates to:
  /// **'New query'**
  String get queryNewTitle;

  /// Query editor subtitle
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Used by 1 widget · changes apply there too} other{Used by {count} widgets · changes apply there too}}'**
  String queryUsedByApplies(int count);

  /// Live query result label
  ///
  /// In en, this message translates to:
  /// **'Result now'**
  String get queryResultNow;

  /// Live result of a series query
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 point} other{{count} points}}'**
  String queryResultPoints(int count);

  /// Confirm title
  ///
  /// In en, this message translates to:
  /// **'Delete query “{name}”?'**
  String queryDeleteConfirmTitle(String name);

  /// Confirm body
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 widget uses it and will show an error until you edit it.} other{{count} widgets use it and will show an error until you edit them.}}'**
  String queryDeleteConfirmBody(int count);

  /// Confirm destructive action
  ///
  /// In en, this message translates to:
  /// **'Delete query'**
  String get queryDelete;

  /// Confirm safe action
  ///
  /// In en, this message translates to:
  /// **'Keep query'**
  String get queryKeep;

  /// Line under the no-identity title.
  ///
  /// In en, this message translates to:
  /// **'This device has no identity for pairing yet.'**
  String get devicesNetworkingMissingBody;

  /// Muted line under this device's pairing name.
  ///
  /// In en, this message translates to:
  /// **'Name other devices see when pairing'**
  String get devicesLocalNameHint;

  /// Rename dialog line.
  ///
  /// In en, this message translates to:
  /// **'Only changes the name on this device'**
  String get devicesRenameSubtitle;

  /// Field label.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get devicesNameLabel;

  /// Safe action of the revoke dialog.
  ///
  /// In en, this message translates to:
  /// **'Keep device'**
  String get devicesKeepDevice;

  /// Safe action of the delete dialog.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get devicesKeep;

  /// Shown under a switch whose toggle failed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change this. Try again.'**
  String get devicesSwitchError;

  /// Row line while sync is paused.
  ///
  /// In en, this message translates to:
  /// **'Paused on this device · last synced {time}'**
  String devicesPausedSynced(String time);

  /// Row line while sync is paused and the peer never synced.
  ///
  /// In en, this message translates to:
  /// **'Paused on this device · never synced'**
  String get devicesPausedNever;

  /// Sidebar line under the Paused status.
  ///
  /// In en, this message translates to:
  /// **'sync is off'**
  String get sidebarSyncOff;

  /// Sidebar line while pairing mode is active.
  ///
  /// In en, this message translates to:
  /// **'pairing open'**
  String get sidebarPairingOpen;

  /// Devices status chip while paused, wide.
  ///
  /// In en, this message translates to:
  /// **'Paused · sync with paired devices is off'**
  String get devicesChipPaused;

  /// Devices status chip while paused, phone.
  ///
  /// In en, this message translates to:
  /// **'Paused · sync is off'**
  String get devicesChipPausedShort;

  /// Details label after a failed attempt.
  ///
  /// In en, this message translates to:
  /// **'Last endpoint'**
  String get devicesFactLastEndpoint;

  /// Sync port value.
  ///
  /// In en, this message translates to:
  /// **'UDP {port}'**
  String devicesUdpPort(int port);

  /// Pairing card title while discoverable.
  ///
  /// In en, this message translates to:
  /// **'Pairing is open'**
  String get pairingOpen;

  /// Countdown line; time is m:ss.
  ///
  /// In en, this message translates to:
  /// **'{time} left of 2:00 · start it on the other device too'**
  String pairingTimeLeft(String time);

  /// Candidate list heading.
  ///
  /// In en, this message translates to:
  /// **'Nearby · {count}'**
  String pairingNearby(int count);

  /// Muted line under the candidates.
  ///
  /// In en, this message translates to:
  /// **'Devices you\'ve already paired are hidden.'**
  String get pairingHiddenPaired;

  /// End card title.
  ///
  /// In en, this message translates to:
  /// **'Pairing expired'**
  String get pairingExpiredTitle;

  /// End card body.
  ///
  /// In en, this message translates to:
  /// **'Pairing closed after 2 minutes. Start it again on both devices when they\'re nearby.'**
  String get pairingExpiredBody;

  /// End card title.
  ///
  /// In en, this message translates to:
  /// **'Pairing rejected'**
  String get pairingRejectedTitle;

  /// End card body.
  ///
  /// In en, this message translates to:
  /// **'The code was rejected. Nothing was paired.'**
  String get pairingRejectedBody;

  /// Code confirmation title.
  ///
  /// In en, this message translates to:
  /// **'Confirm the code'**
  String get pairingConfirmTitle;

  /// Code confirmation instruction.
  ///
  /// In en, this message translates to:
  /// **'Check the same code shows on the other device, then confirm on both.'**
  String get pairingConfirmInstruction;

  /// Code confirmation subtitle when the peer name is known.
  ///
  /// In en, this message translates to:
  /// **'Pairing with {name}'**
  String pairingWith(String name);

  /// Label over the peer DeviceId.
  ///
  /// In en, this message translates to:
  /// **'Device ID of {name}'**
  String pairingPeerIdOf(String name);

  /// Secondary action of the code confirmation.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get pairingReject;

  /// Primary action of the code confirmation.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get pairingConfirm;

  /// Title while committing.
  ///
  /// In en, this message translates to:
  /// **'Saving trust…'**
  String get pairingSavingTrust;

  /// Instruction when the keyring is locked at commit.
  ///
  /// In en, this message translates to:
  /// **'Unlock your desktop keyring, then retry.'**
  String get pairingKeyringLine;

  /// Reset consequences.
  ///
  /// In en, this message translates to:
  /// **'This deletes the only copy of the dataset on this device. Other devices keep their copies and are not told about the reset. If this is the only device, the data is permanently lost.'**
  String get resetParagraph;

  /// Reset checkbox.
  ///
  /// In en, this message translates to:
  /// **'I understand this can\'t be undone'**
  String get resetAcknowledge;

  /// Safe reset action.
  ///
  /// In en, this message translates to:
  /// **'Keep data'**
  String get resetKeep;

  /// Onboarding title.
  ///
  /// In en, this message translates to:
  /// **'Set up this device'**
  String get setupTitle;

  /// Onboarding lead.
  ///
  /// In en, this message translates to:
  /// **'Your data stays on your devices. Pick how this one starts.'**
  String get setupLead;

  /// Create choice card title.
  ///
  /// In en, this message translates to:
  /// **'Create a new dataset'**
  String get setupCreateTitle;

  /// Create choice card body.
  ///
  /// In en, this message translates to:
  /// **'Start fresh. You can pair other devices later.'**
  String get setupCreateBody;

  /// Why the Create card is locked.
  ///
  /// In en, this message translates to:
  /// **'Not available while pairing is open. Stop pairing to create one instead.'**
  String get setupCreateLocked;

  /// Join choice card and Join view title.
  ///
  /// In en, this message translates to:
  /// **'Join an existing dataset'**
  String get setupJoinTitle;

  /// Join choice card body.
  ///
  /// In en, this message translates to:
  /// **'Copy the dataset from one of your other devices.'**
  String get setupJoinBody;

  /// Join card precondition.
  ///
  /// In en, this message translates to:
  /// **'The other device must already have a dataset.'**
  String get setupJoinNeedsDataset;

  /// Join card precondition.
  ///
  /// In en, this message translates to:
  /// **'Start the connection from only one of the two devices.'**
  String get setupJoinOneSide;

  /// Pairing status row under the choice cards.
  ///
  /// In en, this message translates to:
  /// **'Pairing is open · {time} left'**
  String setupPairingStatus(String time);

  /// Pairing status row hint.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your other device. Tap Connect on one device only.'**
  String get setupPairingWaiting;

  /// Stop button in the pairing status row.
  ///
  /// In en, this message translates to:
  /// **'Stop pairing'**
  String get setupStopPairing;

  /// Join view lead.
  ///
  /// In en, this message translates to:
  /// **'Start pairing on the other device too. Tap Connect on one device only.'**
  String get joinLead;

  /// Both-rootless failure title.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t join'**
  String get couldntJoinTitle;

  /// Both-rootless failure body.
  ///
  /// In en, this message translates to:
  /// **'The other device has no dataset yet. Create one there first, or create one here.'**
  String get couldntJoinBody;

  /// Joining title with the peer name.
  ///
  /// In en, this message translates to:
  /// **'Joining “{name}”'**
  String joiningTitleNamed(String name);

  /// Joining title without a peer name.
  ///
  /// In en, this message translates to:
  /// **'Joining the other device'**
  String get joiningTitle;

  /// Joining body with the peer name.
  ///
  /// In en, this message translates to:
  /// **'Copying the dataset from {name}. Keep both devices open until this finishes.'**
  String joiningBodyNamed(String name);

  /// Joining body without a peer name.
  ///
  /// In en, this message translates to:
  /// **'Copying the dataset from the other device. Keep both devices open until this finishes.'**
  String get joiningBody;

  /// Root-mismatch screen title.
  ///
  /// In en, this message translates to:
  /// **'This device has a different dataset'**
  String get mismatchTitle;

  /// Root-mismatch body with the peer name.
  ///
  /// In en, this message translates to:
  /// **'“{name}” uses another dataset than this device. Devices can only sync when they share the same one.'**
  String mismatchBodyNamed(String name);

  /// Root-mismatch body without a peer name.
  ///
  /// In en, this message translates to:
  /// **'The other device uses another dataset than this device. Devices can only sync when they share the same one.'**
  String get mismatchBody;

  /// Root-mismatch second paragraph.
  ///
  /// In en, this message translates to:
  /// **'To join it, reset this device\'s data first. The collections on this device will be deleted; the other device keeps its data.'**
  String get mismatchResetNote;

  /// Secondary action opening the reset confirmation.
  ///
  /// In en, this message translates to:
  /// **'Reset this device\'s data…'**
  String get resetDataEllipsis;

  /// Fatal start title.
  ///
  /// In en, this message translates to:
  /// **'Fi couldn\'t start'**
  String get fatalTitle;

  /// Fatal body for reset-resolvable errors.
  ///
  /// In en, this message translates to:
  /// **'This device\'s local data can\'t be opened. Retrying won\'t fix it. Resetting deletes this device\'s copy; your other devices keep theirs.'**
  String get fatalResetBody;

  /// Copies Rust's error message.
  ///
  /// In en, this message translates to:
  /// **'Copy details'**
  String get fatalCopyDetails;

  /// Confirmation after Copy details.
  ///
  /// In en, this message translates to:
  /// **'Details copied'**
  String get fatalDetailsCopied;

  /// Recovery in progress title.
  ///
  /// In en, this message translates to:
  /// **'Recovering this device\'s data'**
  String get recoveringTitle;

  /// Recovery in progress body.
  ///
  /// In en, this message translates to:
  /// **'Fi is getting the dataset back from your other devices. Keep them open.'**
  String get recoveringBody;

  /// Recovery needs another device body.
  ///
  /// In en, this message translates to:
  /// **'This device\'s copy of the dataset is damaged. Open Fi on a paired device on the same network to restore it, or reset.'**
  String get recoveryNeedsDeviceBody;

  /// Banner title, keyring locked.
  ///
  /// In en, this message translates to:
  /// **'Sync is off: the desktop keyring is locked'**
  String get deferredLockedTitle;

  /// Banner body, keyring locked.
  ///
  /// In en, this message translates to:
  /// **'Fi keeps this device\'s keys in the desktop keyring. Unlock it, then retry. Your data here still works.'**
  String get deferredLockedBody;

  /// Banner title, no keyring.
  ///
  /// In en, this message translates to:
  /// **'Sync is off: no keyring is available'**
  String get deferredNoKeyringTitle;

  /// Banner body, no keyring.
  ///
  /// In en, this message translates to:
  /// **'Install and unlock a desktop keyring (GNOME Keyring or KWallet), then retry.'**
  String get deferredNoKeyringBody;

  /// Banner title, ports in use.
  ///
  /// In en, this message translates to:
  /// **'Sync is off: UDP {first}–{last} are in use'**
  String deferredPortsTitle(int first, int last);

  /// Banner body, ports in use.
  ///
  /// In en, this message translates to:
  /// **'Another program or another copy of Fi is using these ports. Your data here still works.'**
  String get deferredPortsBody;

  /// Sidebar cause line.
  ///
  /// In en, this message translates to:
  /// **'keyring locked'**
  String get sidebarCauseLocked;

  /// Sidebar cause line.
  ///
  /// In en, this message translates to:
  /// **'no keyring'**
  String get sidebarCauseNoKeyring;

  /// Sidebar cause line.
  ///
  /// In en, this message translates to:
  /// **'ports in use'**
  String get sidebarCausePorts;

  /// Record clone action
  ///
  /// In en, this message translates to:
  /// **'Clone'**
  String get recordsClone;

  /// Context line of a new record cloned from another
  ///
  /// In en, this message translates to:
  /// **'Clone of ‘{title}’'**
  String recordsCloneOf(String title);

  /// Feedback after cloning selected records
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Cloned 1 record} other{Cloned {count} records}}'**
  String recordsClonedSnack(int count);

  /// Tooltip of a record row's actions menu
  ///
  /// In en, this message translates to:
  /// **'Record actions'**
  String get recordsActions;

  /// Snackbar action that reverts the last action
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get commonUndo;

  /// Field dictation mic label
  ///
  /// In en, this message translates to:
  /// **'Dictate into {field}'**
  String dictationMicLabel(String field);

  /// Field dictation listening state
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get dictationListening;

  /// Announced when field dictation starts listening
  ///
  /// In en, this message translates to:
  /// **'Listening into {field}'**
  String dictationListeningAnnounce(String field);

  /// Field dictation state while speech is turned into text, before cleanup
  ///
  /// In en, this message translates to:
  /// **'Transcribing…'**
  String get dictationTranscribing;

  /// Field dictation processing state
  ///
  /// In en, this message translates to:
  /// **'Cleaning up…'**
  String get dictationCleaningUp;

  /// Text button on the Cleaning up state: use the raw transcript without cleanup
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get dictationSkip;

  /// Screen-reader label of the Skip button on the Cleaning up state
  ///
  /// In en, this message translates to:
  /// **'Skip cleanup'**
  String get dictationSkipLabel;

  /// Dictated review sheet title
  ///
  /// In en, this message translates to:
  /// **'Dictated'**
  String get dictatedTitle;

  /// Dictated review sheet subtitle
  ///
  /// In en, this message translates to:
  /// **'into {field}'**
  String dictatedInto(String field);

  /// The cleaned dictation version
  ///
  /// In en, this message translates to:
  /// **'Cleaned'**
  String get dictatedCleaned;

  /// Tag on the default dictation version
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get dictatedDefault;

  /// The raw dictation version
  ///
  /// In en, this message translates to:
  /// **'As heard'**
  String get dictatedAsHeard;

  /// Shown when cleanup changed nothing
  ///
  /// In en, this message translates to:
  /// **'Nothing to clean up.'**
  String get dictatedNothingToClean;

  /// The field's current text in the review sheet
  ///
  /// In en, this message translates to:
  /// **'In the field now: “{text}”'**
  String dictatedInFieldNow(String text);

  /// Review sheet line for an empty field
  ///
  /// In en, this message translates to:
  /// **'The field is empty.'**
  String get dictatedFieldEmpty;

  /// Adds the dictated text after the field's text
  ///
  /// In en, this message translates to:
  /// **'Append'**
  String get dictatedAppend;

  /// Replaces the field's text with the dictated text
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get dictatedReplace;

  /// Puts the dictated text into the empty field
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get dictatedInsert;

  /// Screen reader text for words the cleanup removed
  ///
  /// In en, this message translates to:
  /// **'Removed: {words}'**
  String dictatedRemovedWords(String words);

  /// Field kind name: a set of options
  ///
  /// In en, this message translates to:
  /// **'Choices'**
  String get fieldTypeChoices;

  /// How many options of a Choices field are picked
  ///
  /// In en, this message translates to:
  /// **'{count} picked'**
  String themeChoicesPicked(int count);

  /// Helper under the chips of a Choices field
  ///
  /// In en, this message translates to:
  /// **'Required means at least one option is picked.'**
  String get fieldEditorChoicesRequiredHelp;

  /// Helper under the default of a Choices field
  ///
  /// In en, this message translates to:
  /// **'A set of options, picked on new records.'**
  String get fieldEditorChoicesDefaultHelp;

  /// Inline error on a Choices option label holding a semicolon
  ///
  /// In en, this message translates to:
  /// **'Options of a Choices field can\'t contain “;”.'**
  String get fieldEditorChoicesSemicolon;

  /// Choices to Choice refused because records hold several options
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record holds more than one choice. Edit it first.} other{{count} records hold more than one choice. Edit them first.}}'**
  String fieldEditorChoicesConversionBlocked(int count);

  /// Set filter operator
  ///
  /// In en, this message translates to:
  /// **'has any of'**
  String get queryOpHasAnyOf;

  /// Set filter operator
  ///
  /// In en, this message translates to:
  /// **'has all of'**
  String get queryOpHasAllOf;

  /// Set filter operator
  ///
  /// In en, this message translates to:
  /// **'has none of'**
  String get queryOpHasNoneOf;

  /// Filter operator: no value
  ///
  /// In en, this message translates to:
  /// **'is empty'**
  String get queryOpIsEmpty;

  /// Filter operator: has a value
  ///
  /// In en, this message translates to:
  /// **'is not empty'**
  String get queryOpIsNotEmpty;

  /// Note under a widget grouped by a Choices field
  ///
  /// In en, this message translates to:
  /// **'Groups overlap: a record counts in each of its choices.'**
  String get widgetGroupsOverlap;

  /// Tag standing for Choices labels that don't fit
  ///
  /// In en, this message translates to:
  /// **'+{count}'**
  String recordsMoreTags(int count);

  /// Switch on Choice and Choices fields
  ///
  /// In en, this message translates to:
  /// **'Allow adding options from records'**
  String get fieldEditorAllowAddingOptions;

  /// Helper under the allow-adding switch
  ///
  /// In en, this message translates to:
  /// **'New options are added to this field when the record is saved.'**
  String get fieldEditorAllowAddingOptionsHelp;

  /// Tooltip of an option row's ⋯ button
  ///
  /// In en, this message translates to:
  /// **'Actions for “{label}”'**
  String fieldEditorOptionActions(String label);

  /// Option row menu item
  ///
  /// In en, this message translates to:
  /// **'Merge…'**
  String get fieldEditorMergeEllipsis;

  /// Option row menu item
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get fieldEditorDeleteEllipsis;

  /// Banner when active options share a label ignoring case
  ///
  /// In en, this message translates to:
  /// **'{count} options are named “{label}”. Merge them?'**
  String fieldEditorDuplicateBanner(int count, String label);

  /// Button that merges options
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get fieldEditorMerge;

  /// Banner when records hold a merged-away option
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record still uses merged options.} other{{count} records still use merged options.}}'**
  String fieldEditorMergedStill(int count);

  /// Button moving records off merged options
  ///
  /// In en, this message translates to:
  /// **'Move them'**
  String get fieldEditorMoveThem;

  /// Merge sheet title
  ///
  /// In en, this message translates to:
  /// **'Merge options'**
  String get mergeOptionsTitle;

  /// Merge sheet subtitle
  ///
  /// In en, this message translates to:
  /// **'in {field} · {kind}'**
  String mergeOptionsSubtitle(String field, String kind);

  /// Merge sheet section
  ///
  /// In en, this message translates to:
  /// **'Options to merge'**
  String get mergeOptionsToMerge;

  /// Records holding an option
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record} other{{count} records}}'**
  String mergeOptionsRecords(int count);

  /// Merge sheet section
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get mergeOptionsKeep;

  /// Under the kept option
  ///
  /// In en, this message translates to:
  /// **'Its label stays'**
  String get mergeOptionsLabelStays;

  /// Merge result line
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record will use “{label}”} other{{count} records will use “{label}”}}'**
  String mergeOptionsWillUse(int count, String label);

  /// Choices merge: records holding several merged options
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record had both. It keeps one “{label}”.} other{{count} records had both. Each keeps one “{label}”.}}'**
  String mergeOptionsHadBoth(int count, String label);

  /// Merge sheet warning
  ///
  /// In en, this message translates to:
  /// **'This can\'t be undone.'**
  String get mergeOptionsCantUndo;

  /// Merge sheet when the editor holds unsaved option edits
  ///
  /// In en, this message translates to:
  /// **'Save the field first. Options with unsaved changes can\'t be merged.'**
  String get mergeOptionsSaveFirst;

  /// Last row of a picker when no option matches
  ///
  /// In en, this message translates to:
  /// **'Add “{label}”'**
  String choiceAddOption(String label);

  /// Trailing chip that adds an option
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get choiceAddChip;

  /// Tag on an option added from the record form
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get choiceNewTag;

  /// Tag on the option matching the typed text
  ///
  /// In en, this message translates to:
  /// **'existing'**
  String get choiceExistingTag;

  /// Hint of the inline add input
  ///
  /// In en, this message translates to:
  /// **'New option'**
  String get choiceNewOptionHint;

  /// Tooltip of the pencil on the This device row.
  ///
  /// In en, this message translates to:
  /// **'Rename this device'**
  String get devicesRenameThisDevice;

  /// Title of the dialog or sheet that names this device.
  ///
  /// In en, this message translates to:
  /// **'Name this device'**
  String get devicesNameThisDeviceTitle;

  /// Line under the Name this device title.
  ///
  /// In en, this message translates to:
  /// **'Other devices see this name when pairing'**
  String get devicesNameThisDeviceSubtitle;

  /// Inline error under a device name over 64 UTF-8 bytes.
  ///
  /// In en, this message translates to:
  /// **'Use a shorter name (at most 64 bytes).'**
  String get devicesNameTooLong;

  /// Hint under the Name field of the rename dialog; name is the device's announced name.
  ///
  /// In en, this message translates to:
  /// **'Announces itself as {name}. Clear the name to use that.'**
  String devicesAnnouncesAs(String name);

  /// Name of the implicit view holding every record.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get viewAllName;

  /// Validation issue: view filter is not Boolean.
  ///
  /// In en, this message translates to:
  /// **'The filter must be a yes/no condition'**
  String get errorViewFilterType;

  /// Validation issue: invalid view sort key.
  ///
  /// In en, this message translates to:
  /// **'This field can\'t be used to sort'**
  String get errorViewSortKey;

  /// Validation issue: too many sort keys.
  ///
  /// In en, this message translates to:
  /// **'Sort by at most 3 keys'**
  String get errorViewSortLimit;

  /// Validation issue: invalid view grouping.
  ///
  /// In en, this message translates to:
  /// **'This grouping isn\'t supported'**
  String get errorViewGrouping;

  /// Validation issue: the view is broken.
  ///
  /// In en, this message translates to:
  /// **'This view uses a field that was deleted'**
  String get errorViewBroken;

  /// Inline error: the view name equals the All view's name.
  ///
  /// In en, this message translates to:
  /// **'“{name}” is reserved'**
  String viewNameReserved(String name);

  /// Inline warning: another saved view has this name.
  ///
  /// In en, this message translates to:
  /// **'Another view is already called {name}'**
  String viewNameDuplicate(String name);

  /// Notice: the unsaved view changes became broken and were dropped.
  ///
  /// In en, this message translates to:
  /// **'Your unsaved changes used a field that was deleted, so they were discarded.'**
  String get viewDraftDiscarded;

  /// Semantics label of the view chip row
  ///
  /// In en, this message translates to:
  /// **'Views'**
  String get viewTabsLabel;

  /// View chip: name and count
  ///
  /// In en, this message translates to:
  /// **'{name} · {count}'**
  String viewChipLabel(String name, int count);

  /// View chip tooltip
  ///
  /// In en, this message translates to:
  /// **'{name}: right-click or long-press for options'**
  String viewChipTooltip(String name);

  /// Button after the view chips (shown after a plus icon)
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get viewNewView;

  /// Accessible label and editor title for a new view
  ///
  /// In en, this message translates to:
  /// **'New view'**
  String get viewNewViewLabel;

  /// View tab: record count
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 record} other{{count} records}}'**
  String viewSemanticsCount(int count);

  /// View tab: the view is broken
  ///
  /// In en, this message translates to:
  /// **'broken'**
  String get viewSemanticsBroken;

  /// View tab: unsaved changes
  ///
  /// In en, this message translates to:
  /// **'modified'**
  String get viewSemanticsModified;

  /// Announced when a view becomes modified
  ///
  /// In en, this message translates to:
  /// **'{name} modified'**
  String viewModifiedAnnounce(String name);

  /// View line: sort prefix
  ///
  /// In en, this message translates to:
  /// **'Sort:'**
  String get viewSortLabel;

  /// View line: filter prefix
  ///
  /// In en, this message translates to:
  /// **'Filter:'**
  String get viewFilterLabel;

  /// Sort key: record creation time
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get viewSortCreated;

  /// View line: a further sort key
  ///
  /// In en, this message translates to:
  /// **'then {field}'**
  String viewThenField(String field);

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'newest'**
  String get viewDirNewest;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'oldest'**
  String get viewDirOldest;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'A→Z'**
  String get viewDirAToZ;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'Z→A'**
  String get viewDirZToA;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'high'**
  String get viewDirHigh;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'low'**
  String get viewDirLow;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'option order'**
  String get viewDirOptionOrder;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'reverse'**
  String get viewDirReverse;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'yes first'**
  String get viewDirYesFirst;

  /// Sort direction word
  ///
  /// In en, this message translates to:
  /// **'no first'**
  String get viewDirNoFirst;

  /// Tooltip of the ⇅ button
  ///
  /// In en, this message translates to:
  /// **'Flip sort direction'**
  String get viewFlipSort;

  /// Action and editor title
  ///
  /// In en, this message translates to:
  /// **'Edit view'**
  String get viewEditView;

  /// Modified view action
  ///
  /// In en, this message translates to:
  /// **'Save as new view'**
  String get viewSaveAsNew;

  /// Modified view action
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get viewReset;

  /// Editor section
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get viewEditorName;

  /// Editor section
  ///
  /// In en, this message translates to:
  /// **'Filter · all must match'**
  String get viewEditorFilter;

  /// Editor section
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get viewEditorSort;

  /// Editor: add a further sort key
  ///
  /// In en, this message translates to:
  /// **'Then by'**
  String get viewEditorThenBy;

  /// Editor: sort key picker label
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get viewEditorSortField;

  /// Editor: sort direction picker label
  ///
  /// In en, this message translates to:
  /// **'Direction'**
  String get viewEditorDirection;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove condition'**
  String get viewEditorRemoveCondition;

  /// Tooltip
  ///
  /// In en, this message translates to:
  /// **'Remove sort key'**
  String get viewEditorRemoveSort;

  /// Editor: an unrecognised filter condition
  ///
  /// In en, this message translates to:
  /// **'A condition this editor can\'t show'**
  String get viewEditorOtherCondition;

  /// Choices filter operator
  ///
  /// In en, this message translates to:
  /// **'is any of'**
  String get viewOpIsAnyOf;

  /// Choices filter operator
  ///
  /// In en, this message translates to:
  /// **'is none of'**
  String get viewOpIsNoneOf;

  /// Chip menu
  ///
  /// In en, this message translates to:
  /// **'Reorder views…'**
  String get viewMenuReorder;

  /// Chip menu
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get viewMenuDelete;

  /// Dialog title
  ///
  /// In en, this message translates to:
  /// **'Rename view'**
  String get viewRenameTitle;

  /// Sheet title
  ///
  /// In en, this message translates to:
  /// **'Reorder views'**
  String get viewReorderTitle;

  /// Reorder sheet: note on All
  ///
  /// In en, this message translates to:
  /// **'Always first'**
  String get viewReorderAlwaysFirst;

  /// Delete dialog title
  ///
  /// In en, this message translates to:
  /// **'Delete view “{name}”?'**
  String viewDeleteTitle(String name);

  /// Delete dialog body
  ///
  /// In en, this message translates to:
  /// **'Records aren\'t affected.'**
  String get viewDeleteBody;

  /// Delete dialog safe action
  ///
  /// In en, this message translates to:
  /// **'Keep view'**
  String get viewDeleteKeep;

  /// Notice on a broken view
  ///
  /// In en, this message translates to:
  /// **'This view uses a field that was deleted'**
  String get viewBrokenNotice;

  /// Empty view
  ///
  /// In en, this message translates to:
  /// **'No records match {name}.'**
  String viewEmpty(String name);

  /// Empty view action
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get viewShowAll;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
