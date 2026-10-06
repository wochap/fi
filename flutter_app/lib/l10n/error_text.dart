import 'package:fi/exact_format.dart';
import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/src/rust/api/models.dart';

/// Localized text for a failure. Rust's English messages stay for logs;
/// the typed kind and issue codes decide what the user reads.
String bridgeMessage(AppLocalizations l, Object error) => switch (error) {
  BridgeError(
    kind: BridgeErrorKind.validation,
    :final issues,
    :final message,
  ) =>
    switch (issues) {
      [] => message,
      [final issue] => issueText(l, issue),
      _ => l.errorValidation(issues.length),
    },
  BridgeError(:final kind) => _kindText(l, kind),
  BridgeErrorEventDto(:final kind) => _kindText(l, kind),
  _ => l.errorUnexpected,
};

String _kindText(AppLocalizations l, BridgeErrorKind kind) => switch (kind) {
  BridgeErrorKind.initialization => l.errorInitialization,
  BridgeErrorKind.secureStoreLocked => l.errorSecureStoreLocked,
  BridgeErrorKind.paused => l.errorPaused,
  BridgeErrorKind.validation => l.errorValidation(1),
  BridgeErrorKind.bootstrap => l.errorBootstrap,
  BridgeErrorKind.persistence => l.errorPersistence,
  BridgeErrorKind.projection => l.errorProjection,
  BridgeErrorKind.lifecycle => l.errorLifecycle,
  BridgeErrorKind.internal => l.errorInternal,
};

/// One validation issue as text. Bounds come from [field] when given; an
/// `invalid` or unknown code keeps Rust's message.
String issueText(
  AppLocalizations l,
  BridgeIssueDto issue, {
  FieldDefinitionDto? field,
  String decimalSeparator = '.',
}) {
  final validation = field?.validation;
  switch (issue.code) {
    case 'required':
      return l.issueRequired;
    case 'type_mismatch':
      return l.issueTypeMismatch;
    case 'inactive_option':
      return l.issueInactiveOption;
    case 'field_unavailable':
      return l.issueFieldUnavailable;
    case 'length':
      return switch ((validation?.minLength, validation?.maxLength)) {
        (final min?, final max?) when min == max => l.issueLengthExact(min),
        (final min?, final max?) => l.issueLengthRange(min, max),
        (final min?, null) => l.issueLengthMin(min),
        (null, final max?) => l.issueLengthMax(max),
        _ => l.issueLength,
      };
    case 'out_of_range':
      String bound(int value) =>
          _formatBound(field!.fieldType, value, decimalSeparator);
      final dated = switch (field?.fieldType.kind) {
        FieldTypeKindDto.date || FieldTypeKindDto.dateTime => true,
        _ => false,
      };
      return switch ((validation?.minInteger, validation?.maxInteger)) {
        (final min?, final max?) => l.issueRangeBetween(bound(min), bound(max)),
        (final min?, null) when dated => l.issueDateMin(bound(min)),
        (null, final max?) when dated => l.issueDateMax(bound(max)),
        (final min?, null) => l.issueRangeMin(bound(min)),
        (null, final max?) => l.issueRangeMax(bound(max)),
        _ => l.issueRange,
      };
    default:
      return issue.message;
  }
}

String _formatBound(FieldTypeDto type, int value, String decimalSeparator) =>
    switch (type.kind) {
      FieldTypeKindDto.fixedDecimal => formatScaled(
        value,
        type.scale ?? 0,
        decimalSeparator: decimalSeparator,
      ),
      FieldTypeKindDto.date => formatDate(value),
      FieldTypeKindDto.dateTime => formatDateTime(value),
      FieldTypeKindDto.duration => formatDuration(value),
      _ => '$value',
    };

/// Why peer networking is waiting, in the active language.
String networkingDeferredTitle(
  AppLocalizations l,
  NetworkingDeferredDto deferred,
  NetworkPortsDto? ports,
) => switch (deferred.kind) {
  NetworkingDeferredKindDto.secureStoreLocked => l.deferredLockedTitle,
  NetworkingDeferredKindDto.secureStoreUnavailable => l.deferredNoKeyringTitle,
  NetworkingDeferredKindDto.portsExhausted => l.deferredPortsTitle(
    ports?.rangeFirst ?? 47380,
    ports?.rangeLast ?? 47389,
  ),
};

/// What to do about deferred networking, under [networkingDeferredTitle].
String networkingDeferredBody(
  AppLocalizations l,
  NetworkingDeferredDto deferred,
) => switch (deferred.kind) {
  NetworkingDeferredKindDto.secureStoreLocked => l.deferredLockedBody,
  NetworkingDeferredKindDto.secureStoreUnavailable => l.deferredNoKeyringBody,
  NetworkingDeferredKindDto.portsExhausted => l.deferredPortsBody,
};

/// The short cause under "Offline" in the navigation status while networking is deferred.
String deferredCause(AppLocalizations l, NetworkingDeferredKindDto kind) =>
    switch (kind) {
      NetworkingDeferredKindDto.secureStoreLocked => l.sidebarCauseLocked,
      NetworkingDeferredKindDto.secureStoreUnavailable =>
        l.sidebarCauseNoKeyring,
      NetworkingDeferredKindDto.portsExhausted => l.sidebarCausePorts,
    };

/// Why one widget could not be evaluated.
String widgetErrorText(AppLocalizations l, WidgetErrorKindDto kind) =>
    switch (kind) {
      WidgetErrorKindDto.removed => l.widgetErrorRemoved,
      WidgetErrorKindDto.unsupportedType => l.widgetErrorUnsupportedType,
      WidgetErrorKindDto.unsupportedConfigurationVersion =>
        l.widgetErrorUnsupportedConfigurationVersion,
      WidgetErrorKindDto.invalidConfiguration =>
        l.widgetErrorInvalidConfiguration,
      WidgetErrorKindDto.unknownQuery => l.widgetErrorUnknownQuery,
      WidgetErrorKindDto.invalidQuery => l.widgetErrorInvalidQuery,
      WidgetErrorKindDto.shapeMismatch => l.widgetErrorShapeMismatch,
      WidgetErrorKindDto.overflow => l.widgetErrorOverflow,
      WidgetErrorKindDto.queryFailed => l.widgetErrorQueryFailed,
    };
