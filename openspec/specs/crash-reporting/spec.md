# crash-reporting Specification

## Purpose

Captures uncaught application errors and crashes across Flutter desktop and mobile platforms, redacts sensitive secrets and PII, buffers reports offline, and transmits them to a Sentry-compatible Bugsink endpoint.

## Requirements

### Requirement: Sentry initialization and DSN resolution
The application SHALL initialize the Sentry client during bootstrap before the root widget is rendered. The DSN SHALL resolve according to the following precedence:
1. User-configured custom DSN override stored in device-local `UiPrefs` (if non-empty).
2. Runtime environment variable `SENTRY_DSN` (if set and non-empty).
3. Compile-time environment definition `SENTRY_DSN` provided via `--dart-define`.
4. Default placeholder DSN (`https://placeholder_token@bugsink.example.com/1`).

When automated error reporting is disabled in settings, or the resolved DSN is empty, the Sentry client SHALL remain uninitialized or disabled so that no network requests are sent.

#### Scenario: Startup with default placeholder DSN
- **WHEN** the app starts without environment overrides or user-configured DSN
- **THEN** Sentry initializes using the default placeholder DSN and marks the diagnostics status as "Placeholder"

#### Scenario: Startup with environment variable override
- **WHEN** the app starts with `SENTRY_DSN=https://mykey@bugsink.lan:8000/2` set in its process environment
- **THEN** Sentry initializes using that environment DSN

#### Scenario: Runtime override from user settings
- **WHEN** the user inputs a custom Bugsink DSN in the Settings page and saves it
- **THEN** the custom DSN is stored in `UiPrefs` and Sentry re-initializes or updates its target DSN to the new endpoint

#### Scenario: Error reporting toggled off
- **WHEN** error reporting is turned off in Settings
- **THEN** Sentry event transmission is disabled and no events are queued or sent

### Requirement: Error capture across Flutter, Dart, and bridged Rust
The Sentry client SHALL capture unhandled Flutter framework errors (`FlutterError.onError`), unhandled asynchronous Dart exceptions (`PlatformDispatcher.onError`), and bridged Rust errors and panics that surface across the `flutter_rust_bridge` boundary. Captured events SHALL attach:
- Exception type, message, and stack trace.
- Application version and build number.
- Platform operating system and architecture.
- High-level lifecycle and navigation breadcrumbs.

#### Scenario: Uncaught Flutter framework exception
- **WHEN** a widget build or layout phase throws an unhandled exception
- **THEN** Sentry captures the error event with the widget stack trace and current route

#### Scenario: Unhandled async Dart exception
- **WHEN** an unhandled exception occurs in a Dart asynchronous Future or isolate
- **THEN** Sentry captures the exception through PlatformDispatcher

#### Scenario: Bridged Rust panic
- **WHEN** a Rust core method panics or returns an uncaught `PanicException` across the bridge
- **THEN** Sentry captures the bridged exception with the Rust failure message

### Requirement: Sensitive data redaction and zero-PII policy
Crash reporting MUST NOT transmit user financial data, custom collection record values, private cryptographic keys, discovery tokens, SAS pairing secrets, or plain-text network payloads.
- The Sentry configuration SHALL set `sendDefaultPii` to false, omitting IP addresses, device user names, and platform user identifiers.
- A `beforeSend` callback SHALL inspect every event message, exception detail, and breadcrumb, redacting any occurrences matching secret keys, discovery tokens, or sensitive record payloads defined by `secret-safe-tracing`.

#### Scenario: Exception message containing sensitive token
- **WHEN** an error message or breadcrumb contains a raw discovery secret, private key, or auth header
- **THEN** the `beforeSend` filter redacts the secret value before the event leaves the device

#### Scenario: Zero default PII in event payload
- **WHEN** an error event is constructed and sent
- **THEN** the user object contains no IP address, username, or email address

### Requirement: Offline event buffering and cache bounds
The Sentry client SHALL support offline-first operation. When network connectivity is absent or the Bugsink server is unreachable:
- Unsent error events SHALL be buffered locally in persistent device storage.
- The cache SHALL enforce a maximum item boundary (bounded to at most 30 events) to prevent unbounded storage consumption.
- Buffered events SHALL be transmitted to Bugsink once network connectivity is re-established.

#### Scenario: Error while offline
- **WHEN** an unhandled error occurs while the device has no network connection
- **THEN** the event is serialized to the local offline cache without dropping

#### Scenario: Connectivity re-established
- **WHEN** the device reconnects to a network where the Bugsink server is accessible
- **THEN** the buffered offline events are delivered to Bugsink in order
