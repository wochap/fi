import 'package:fi/crash_reporting.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('CrashReportingConfig DSN Precedence', () {
    const placeholder = CrashReportingConfig.defaultPlaceholderDsn;

    test(
      'falls back to default placeholder DSN when no overrides provided',
      () {
        final dsn = CrashReportingConfig.resolveDsn(
          customDsn: null,
          environment: {},
          compileTimeDsn: '',
        );
        expect(dsn, placeholder);
        expect(CrashReportingConfig.isPlaceholder(dsn), isTrue);
      },
    );

    test('compile-time dart-define flag overrides placeholder', () {
      final dsn = CrashReportingConfig.resolveDsn(
        customDsn: null,
        environment: {},
        compileTimeDsn: 'https://compile@bugsink.corp/2',
      );
      expect(dsn, 'https://compile@bugsink.corp/2');
      expect(CrashReportingConfig.isPlaceholder(dsn), isFalse);
    });

    test('environment variable SENTRY_DSN overrides compile-time flag', () {
      final dsn = CrashReportingConfig.resolveDsn(
        customDsn: null,
        environment: {'SENTRY_DSN': 'https://env@bugsink.corp/3'},
        compileTimeDsn: 'https://compile@bugsink.corp/2',
      );
      expect(dsn, 'https://env@bugsink.corp/3');
      expect(CrashReportingConfig.isPlaceholder(dsn), isFalse);
    });

    test('UiPrefs custom DSN takes highest precedence', () {
      final dsn = CrashReportingConfig.resolveDsn(
        customDsn: 'https://custom@bugsink.corp/4',
        environment: {'SENTRY_DSN': 'https://env@bugsink.corp/3'},
        compileTimeDsn: 'https://compile@bugsink.corp/2',
      );
      expect(dsn, 'https://custom@bugsink.corp/4');
      expect(CrashReportingConfig.isPlaceholder(dsn), isFalse);
    });

    test('empty or whitespace-only overrides are ignored and fall through', () {
      final dsn = CrashReportingConfig.resolveDsn(
        customDsn: '   ',
        environment: {'SENTRY_DSN': ''},
        compileTimeDsn: '  ',
      );
      expect(dsn, placeholder);
    });

    test('status resolves to disabled when reporting is turned off', () {
      final status = CrashReportingConfig.resolveStatus(
        enabled: false,
        customDsn: 'https://custom@bugsink.corp/4',
      );
      expect(status, CrashReportingStatus.disabled);
    });

    test('status resolves to placeholder with default configuration', () {
      final status = CrashReportingConfig.resolveStatus(
        enabled: true,
        customDsn: null,
        environment: {},
        compileTimeDsn: '',
      );
      expect(status, CrashReportingStatus.placeholder);
    });

    test('status resolves to active with custom or valid server DSN', () {
      final status = CrashReportingConfig.resolveStatus(
        enabled: true,
        customDsn: 'https://token@mybugsink.net/1',
      );
      expect(status, CrashReportingStatus.active);
    });
  });

  group('SecretSanitizer and beforeSend Callback', () {
    test('redacts private keys and secret tokens from strings', () {
      const privateKey =
          '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA...\n-----END RSA PRIVATE KEY-----';
      final sanitizedKey = SecretSanitizer.sanitize(
        'Error occurred: $privateKey',
      );
      expect(sanitizedKey, isNot(contains('MIIEowIBAAKCAQEA')));
      expect(sanitizedKey, contains('[REDACTED_PRIVATE_KEY]'));

      final sanitizedBearer = SecretSanitizer.sanitize(
        'Header: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xyz',
      );
      expect(sanitizedBearer, 'Header: Bearer [REDACTED_TOKEN]');

      final sanitizedAuthUrl = SecretSanitizer.sanitize(
        'Connecting to https://user:supersecretpassword@bugsink.lan:8000',
      );
      expect(sanitizedAuthUrl, isNot(contains('supersecretpassword')));
      expect(sanitizedAuthUrl, contains('https://[REDACTED_AUTH]@'));
    });

    test('redacts SAS codes, discovery tokens, and financial record payloads', () {
      final sanitizedSas = SecretSanitizer.sanitize(
        'pairing failed with sas = 918273',
      );
      expect(sanitizedSas, isNot(contains('918273')));
      expect(sanitizedSas, contains('[REDACTED_SAS]'));

      final sanitizedKeyAssignment = SecretSanitizer.sanitize(
        'discovery_secret: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
      );
      expect(
        sanitizedKeyAssignment,
        isNot(
          contains(
            '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08',
          ),
        ),
      );

      final sanitizedPayload = SecretSanitizer.sanitize(
        'record_payload = {"account": "40012", "balance": 150000.0}',
      );
      expect(sanitizedPayload, isNot(contains('40012')));
      expect(sanitizedPayload, isNot(contains('150000.0')));
      expect(sanitizedPayload, contains('[REDACTED_PAYLOAD]'));
    });

    test('redacts test sentinels', () {
      final text = SecretSanitizer.sanitize(
        'Check IDENTITY_SENTINEL_12345, PROVISIONING_SENTINEL_abc, and abababab',
      );
      expect(text, isNot(contains('IDENTITY_SENTINEL_12345')));
      expect(text, isNot(contains('PROVISIONING_SENTINEL_abc')));
      expect(text, isNot(contains('abababab')));
    });

    test(
      'beforeSend strips PII and sanitizes message, exceptions, and breadcrumbs',
      () async {
        CrashReportingService.isEnabled = true;

        final event = SentryEvent(
          message: SentryMessage(
            'Failed pairing: sas = 918273 with IDENTITY_SENTINEL_001',
          ),
          user: SentryUser(
            id: 'user-123',
            email: 'user@example.com',
            ipAddress: '192.168.1.10',
            username: 'john_doe',
          ),
          exceptions: [
            SentryException(
              type: 'PanicException',
              value:
                  'Rust panic at record_payload: secret_financial_amount_9999',
            ),
          ],
          breadcrumbs: [
            Breadcrumb(
              message: 'Auth request: Bearer top_secret_jwt_token',
              data: {'token': 'secret_value_12345'},
            ),
          ],
          // ignore: deprecated_member_use
          extra: {
            'private_key':
                '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          },
        );

        final sanitized = await CrashReportingService.beforeSend(event, Hint());
        expect(sanitized, isNotNull);

        // Verify zero PII
        expect(sanitized!.user, isNotNull);
        expect(sanitized.user!.email, isNull);
        expect(sanitized.user!.ipAddress, isNull);
        expect(sanitized.user!.username, isNull);

        // Verify message sanitized
        expect(sanitized.message!.formatted, isNot(contains('918273')));
        expect(
          sanitized.message!.formatted,
          isNot(contains('IDENTITY_SENTINEL_001')),
        );

        // Verify exceptions sanitized
        expect(
          sanitized.exceptions!.first.value,
          isNot(contains('secret_financial_amount_9999')),
        );
        expect(
          sanitized.exceptions!.first.value,
          contains('[REDACTED_PAYLOAD]'),
        );

        // Verify breadcrumbs sanitized
        expect(
          sanitized.breadcrumbs!.first.message,
          isNot(contains('top_secret_jwt_token')),
        );
        expect(
          sanitized.breadcrumbs!.first.message,
          contains('Bearer [REDACTED_TOKEN]'),
        );
        expect(
          sanitized.breadcrumbs!.first.data!['token'],
          isNot(contains('secret_value_12345')),
        );

        // Verify extra sanitized
        expect(
          // ignore: deprecated_member_use
          sanitized.extra!['private_key'],
          isNot(
            contains(
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
            ),
          ),
        );
      },
    );

    test('beforeSend drops event when crash reporting is disabled', () async {
      CrashReportingService.isEnabled = false;
      final event = SentryEvent(message: SentryMessage('Some error'));
      final result = await CrashReportingService.beforeSend(event, Hint());
      expect(result, isNull);
    });
  });

  group('CrashReportingService Bootstrap', () {
    test('initializes cleanly and calls appRunner', () async {
      var runnerCalled = false;
      await CrashReportingService.initialize(
        prefs: const UiPrefs(),
        appRunner: () {
          runnerCalled = true;
        },
      );
      expect(runnerCalled, isTrue);
      expect(CrashReportingService.isEnabled, isTrue);
    });

    test(
      'reconfigure updates active status when disabled and enabled',
      () async {
        await CrashReportingService.reconfigure(
          const UiPrefs(crashReportingEnabled: false),
        );
        expect(CrashReportingService.isEnabled, isFalse);

        await CrashReportingService.reconfigure(
          const UiPrefs(
            crashReportingEnabled: true,
            customSentryDsn: 'https://new@bugsink.corp/5',
          ),
        );
        expect(CrashReportingService.isEnabled, isTrue);
        expect(CrashReportingService.activeDsn, 'https://new@bugsink.corp/5');
      },
    );
  });
}
