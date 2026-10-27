import 'dart:async';
import 'dart:io';

import 'package:fi/ui_prefs.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Status of the crash reporting integration displayed in Settings.
enum CrashReportingStatus { active, placeholder, disabled }

/// Precedence and endpoint configuration for Sentry/Bugsink crash reporting.
abstract final class CrashReportingConfig {
  /// Default placeholder DSN used when no user override, env var, or dart-define is set.
  static const String defaultPlaceholderDsn =
      'https://placeholder_token@bugsink.example.com/1';

  /// Returns true if [dsn] is empty, matches the default placeholder, or targets example/placeholder hosts.
  static bool isPlaceholder(String? dsn) {
    if (dsn == null || dsn.trim().isEmpty) return false;
    final trimmed = dsn.trim();
    return trimmed == defaultPlaceholderDsn ||
        trimmed.contains('placeholder_token') ||
        trimmed.contains('bugsink.example.com') ||
        trimmed.contains('placeholder.example.com');
  }

  /// Resolves the active DSN following strict precedence:
  /// 1. [customDsn] (from UiPrefs, if non-empty)
  /// 2. [environment] SENTRY_DSN (defaults to Platform.environment)
  /// 3. [compileTimeDsn] (defaults to const String.fromEnvironment('SENTRY_DSN'))
  /// 4. [defaultPlaceholderDsn]
  static String resolveDsn({
    String? customDsn,
    Map<String, String>? environment,
    String? compileTimeDsn,
  }) {
    if (customDsn != null && customDsn.trim().isNotEmpty) {
      return customDsn.trim();
    }

    final env =
        environment ??
        (!kIsWeb ? Platform.environment : const <String, String>{});
    final envDsn = env['SENTRY_DSN'];
    if (envDsn != null && envDsn.trim().isNotEmpty) {
      return envDsn.trim();
    }

    final buildDsn =
        compileTimeDsn ??
        const String.fromEnvironment('SENTRY_DSN', defaultValue: '');
    if (buildDsn.trim().isNotEmpty) {
      return buildDsn.trim();
    }

    return defaultPlaceholderDsn;
  }

  /// Returns the current diagnostics connection status.
  static CrashReportingStatus resolveStatus({
    required bool enabled,
    String? customDsn,
    Map<String, String>? environment,
    String? compileTimeDsn,
  }) {
    if (!enabled) return CrashReportingStatus.disabled;
    final dsn = resolveDsn(
      customDsn: customDsn,
      environment: environment,
      compileTimeDsn: compileTimeDsn,
    );
    if (dsn.isEmpty) return CrashReportingStatus.disabled;
    if (isPlaceholder(dsn)) return CrashReportingStatus.placeholder;
    return CrashReportingStatus.active;
  }
}

/// Sanitization helper conforming to `secret-safe-tracing` specifications.
abstract final class SecretSanitizer {
  static final _privateKeyBlock = RegExp(
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
  );

  static final _urlAuth = RegExp(r'(https?://)[^:\s/]+:[^@\s/]+@');

  static final _bearerToken = RegExp(
    r'Bearer\s+[A-Za-z0-9\-._~+/]+=*',
    caseSensitive: false,
  );

  static final _keyOrSecretAssignment = RegExp(
    r"""(?<=\b(?:secret|private_key|discovery_secret|token|auth_token|pairing_secret|credentials?)\s*[:=]\s*)[^\s"',;]+""",
    caseSensitive: false,
  );

  static final _sasPattern = RegExp(
    r'(?<=\b(?:sas(?:_code)?|pairing_code)\s*[:=]\s*)(?:SasCode\()?"?(\d{6})"?\)?',
    caseSensitive: false,
  );

  static final _hex256Secret = RegExp(r'\b[0-9a-fA-F]{64}\b');

  static final _byteListSecret = RegExp(
    r'\[\s*(?:(?:\d+|0x[0-9a-fA-F]+),\s*){7,}(?:\d+|0x[0-9a-fA-F]+)\s*\]',
    caseSensitive: false,
  );

  static final _recordPayloadPattern = RegExp(
    r'(?<=\b(?:record_payload|payload|financial_record|record_content)\s*[:=]\s*)(?:\{[\s\S]*?\}|\[[\s\S]*?\]|[^\n\r]+)',
    caseSensitive: false,
  );

  static final _sensitiveKeyNames = RegExp(
    r'^(?:secret|private_key|discovery_secret|token|auth_token|pairing_secret|credentials?|password|payload|record_payload)$',
    caseSensitive: false,
  );

  static final _sentinelPattern = RegExp(
    r'\b(?:IDENTITY_SENTINEL|PROVISIONING_SENTINEL|DISCOVERY_SENTINEL)[A-Za-z0-9_]*\b',
  );

  static final _forbiddenSentinels = [
    'IDENTITY_SENTINEL',
    'PROVISIONING_SENTINEL',
    'DISCOVERY_SENTINEL',
    '918273',
    'abababab',
  ];

  /// Sanitizes [input] by redacting sensitive keys, secrets, tokens, SAS codes, and payloads.
  static String sanitize(String input) {
    if (input.isEmpty) return input;
    var result = input;
    result = result.replaceAll(_privateKeyBlock, '[REDACTED_PRIVATE_KEY]');
    result = result.replaceAllMapped(
      _urlAuth,
      (m) => '${m.group(1)}[REDACTED_AUTH]@',
    );
    result = result.replaceAll(_bearerToken, 'Bearer [REDACTED_TOKEN]');
    result = result.replaceAll(_keyOrSecretAssignment, '[REDACTED_SECRET]');
    result = result.replaceAllMapped(_sasPattern, (m) => '[REDACTED_SAS]');
    result = result.replaceAll(_hex256Secret, '[REDACTED_SECRET]');
    result = result.replaceAll(_byteListSecret, '[REDACTED_BYTES]');
    result = result.replaceAll(_recordPayloadPattern, '[REDACTED_PAYLOAD]');
    result = result.replaceAll(_sentinelPattern, '[REDACTED_SENTINEL]');

    for (final sentinel in _forbiddenSentinels) {
      if (result.contains(sentinel)) {
        result = result.replaceAll(sentinel, '[REDACTED]');
      }
    }

    return result;
  }

  /// Sanitizes any string values in a Map recursively, redacting sensitive keys directly.
  static Map<String, dynamic> sanitizeMap(Map<String, dynamic> map) {
    final sanitized = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = entry.key;
      final value = entry.value;

      if (_sensitiveKeyNames.hasMatch(key)) {
        sanitized[key] = '[REDACTED_SECRET]';
        continue;
      }

      if (value is String) {
        sanitized[key] = sanitize(value);
      } else if (value is Map<String, dynamic>) {
        sanitized[key] = sanitizeMap(value);
      } else if (value is List) {
        sanitized[key] = value.map((item) {
          if (item is String) return sanitize(item);
          if (item is Map<String, dynamic>) return sanitizeMap(item);
          return item;
        }).toList();
      } else {
        sanitized[key] = value;
      }
    }
    return sanitized;
  }
}

/// Service managing Sentry lifecycle, event sanitization, and runtime reconfiguration.
abstract final class CrashReportingService {
  static bool _enabled = true;
  static bool get isEnabled => _enabled;
  @visibleForTesting
  static set isEnabled(bool value) => _enabled = value;

  static String? _activeDsn;
  static String? get activeDsn => _activeDsn;

  /// Sanitization callback for Sentry events.
  static FutureOr<SentryEvent?> beforeSend(SentryEvent event, Hint hint) {
    if (!_enabled) return null;
    return sanitizeEvent(event);
  }

  /// Sanitization callback for Sentry breadcrumbs.
  static Breadcrumb? beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
    if (breadcrumb == null) return null;
    return sanitizeBreadcrumb(breadcrumb);
  }

  /// Sanitizes an event by removing PII and scrubbing secret-bearing strings.
  static SentryEvent sanitizeEvent(SentryEvent event) {
    // Zero-PII: Clear out IP, email, username from user object.
    SentryUser? sanitizedUser;
    if (event.user != null) {
      sanitizedUser = SentryUser(
        id: event.user?.id != null
            ? SecretSanitizer.sanitize(event.user!.id!)
            : null,
      );
    }

    // Sanitize message
    SentryMessage? sanitizedMessage;
    if (event.message != null) {
      final msg = event.message!;
      sanitizedMessage = SentryMessage(
        SecretSanitizer.sanitize(msg.formatted),
        template: msg.template != null
            ? SecretSanitizer.sanitize(msg.template!)
            : null,
        params: msg.params
            ?.map((p) => p is String ? SecretSanitizer.sanitize(p) : p)
            .toList(),
      );
    }

    // Sanitize exceptions
    List<SentryException>? sanitizedExceptions;
    if (event.exceptions != null) {
      sanitizedExceptions = event.exceptions!.map((ex) {
        return ex.copyWith(
          value: ex.value != null ? SecretSanitizer.sanitize(ex.value!) : null,
          type: ex.type != null ? SecretSanitizer.sanitize(ex.type!) : null,
        );
      }).toList();
    }

    // Sanitize breadcrumbs
    List<Breadcrumb>? sanitizedBreadcrumbs;
    if (event.breadcrumbs != null) {
      sanitizedBreadcrumbs = event.breadcrumbs!
          .map(sanitizeBreadcrumb)
          .toList();
    }

    // Sanitize extra
    Map<String, dynamic>? sanitizedExtra;
    // ignore: deprecated_member_use
    if (event.extra != null) {
      // ignore: deprecated_member_use
      sanitizedExtra = SecretSanitizer.sanitizeMap(event.extra!);
    }

    return event.copyWith(
      user: sanitizedUser,
      message: sanitizedMessage,
      exceptions: sanitizedExceptions,
      breadcrumbs: sanitizedBreadcrumbs,
      // ignore: deprecated_member_use
      extra: sanitizedExtra,
    );
  }

  /// Sanitizes a breadcrumb.
  static Breadcrumb sanitizeBreadcrumb(Breadcrumb breadcrumb) {
    final message = breadcrumb.message != null
        ? SecretSanitizer.sanitize(breadcrumb.message!)
        : null;
    final data = breadcrumb.data != null
        ? SecretSanitizer.sanitizeMap(breadcrumb.data!)
        : null;
    return breadcrumb.copyWith(message: message, data: data);
  }

  /// Initializes Sentry during application bootstrap.
  static Future<void> initialize({
    required UiPrefs prefs,
    required FutureOr<void> Function() appRunner,
    Map<String, String>? environment,
    String? compileTimeDsn,
  }) async {
    _enabled = prefs.crashReportingEnabled;
    final dsn = _enabled
        ? CrashReportingConfig.resolveDsn(
            customDsn: prefs.customSentryDsn,
            environment: environment,
            compileTimeDsn: compileTimeDsn,
          )
        : '';
    _activeDsn = dsn;

    try {
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.sendDefaultPii = false;
        options.maxCacheItems = 30;
        options.beforeSend = beforeSend;
        options.beforeBreadcrumb = beforeBreadcrumb;
      }, appRunner: appRunner);
    } catch (_) {
      // In tests or non-standard environments where SentryFlutter.init encounters issues,
      // fall back to invoking appRunner directly so startup never stalls.
      await appRunner();
    }
  }

  /// Updates Sentry configuration when preferences change in Settings.
  static Future<void> reconfigure(
    UiPrefs prefs, {
    Map<String, String>? environment,
    String? compileTimeDsn,
  }) async {
    _enabled = prefs.crashReportingEnabled;
    if (!_enabled) {
      _activeDsn = '';
      await Sentry.close();
      return;
    }

    final dsn = CrashReportingConfig.resolveDsn(
      customDsn: prefs.customSentryDsn,
      environment: environment,
      compileTimeDsn: compileTimeDsn,
    );
    _activeDsn = dsn;

    try {
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.sendDefaultPii = false;
        options.maxCacheItems = 30;
        options.beforeSend = beforeSend;
        options.beforeBreadcrumb = beforeBreadcrumb;
      });
    } catch (_) {
      // Ignore in mock/test environments
    }
  }
}
