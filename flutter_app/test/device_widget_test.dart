import 'package:clock/clock.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/app.dart';
import 'package:fi/pairing_card.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Widget testApp(
  FakeCollectionBridge bridge, {
  PlatformCapabilities? capabilities,
}) => CollectionApp(
  bridge: bridge,
  initializeRust: () async {},
  dataDirProvider: () async => '/test',
  setPlatformForeground: (_) async {},
  uiPrefs: MemoryUiPrefsStore(),
  capabilities: capabilities,
);

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

PairingStateDto pairingState(
  PairingKindDto kind, {
  String? session,
  String? sas,
  String? peer,
  String? message,
  PairingFailureKindDto? failure,
}) => PairingStateDto(
  kind: kind,
  sessionId: session,
  sas: sas,
  peerDeviceId: peer,
  localConfirmed: false,
  remoteConfirmed: false,
  message: message,
  failure: failure,
  alreadyPaired: false,
);

Future<void> openDevices(
  WidgetTester tester,
  FakeCollectionBridge bridge,
) async {
  // Tall enough that the connection switches above the pairing card do not
  // push the device rows off screen.
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  bridge.bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );
  await tester.pumpWidget(testApp(bridge));
  await pumpUntilFound(tester, find.text('Collections'));
  await tester.tap(find.text('Devices').last);
  await tester.pump();
}

const failedPeerId =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

const failedPeer = TrustedDeviceDto(
  deviceId: failedPeerId,
  friendlyName: 'Phone',
  pairedAtMs: 1,
  revoked: false,
  connection: PeerConnectionKindDto.error,
  attemptEndpoint: '192.168.1.20:47380',
  lastAttemptMs: 1,
  failure: 'TLS failed: bad certificate',
  failureKind: ConnectionFailureKindDto.tls,
);

/// Records what the app writes to the clipboard.
List<String> mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump();
}

void diagnosticsTests() {
  testWidgets('this device shows its grouped id, pairing name and Copy ID', (
    tester,
  ) async {
    final copied = mockClipboard(tester);
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await pumpUntilFound(tester, find.byKey(const Key('local-device-id')));
    final id = bridge.localIdentity!.deviceId;
    final shown = tester
        .widget<Text>(find.byKey(const Key('local-device-id')))
        .data!;
    expect(shown, startsWith(id.substring(0, 8)));
    expect(shown, endsWith(id.substring(id.length - 8)));
    expect(find.text(bridge.localIdentity!.pairingName), findsOneWidget);
    expect(find.byKey(const Key('local-device-missing')), findsNothing);

    await tapVisible(tester, find.byKey(const Key('copy-local-id')));
    expect(copied, [id]);
    expect(find.text('ID copied'), findsOneWidget);
    // "ID copied" stands in for the action, then Copy ID returns.
    expect(find.byKey(const Key('copy-local-id')), findsNothing);
    expect(find.text('Name other devices see when pairing'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('copy-local-id')), findsOneWidget);
    expect(find.text('ID copied'), findsNothing);
  });

  testWidgets('this device says networking is not set up without an id', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..localIdentity = null;
    await openDevices(tester, bridge);
    await pumpUntilFound(tester, find.byKey(const Key('local-device-missing')));
    expect(find.text('Networking is not set up'), findsOneWidget);
    expect(
      find.text('This device has no identity for pairing yet.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('local-device-id')), findsNothing);
    expect(find.byKey(const Key('copy-local-id')), findsNothing);
    expect(find.byKey(const Key('reset-dataset')), findsOneWidget);
  });

  testWidgets('details stay hidden until opened and explain a failure', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(failedPeer)
      ..logs[failedPeerId] = const [
        LogEventDto(
          atMs: 7,
          level: 'INFO',
          event: 'peer_dial_failed',
          message: 'dial to peer endpoint failed',
          fields: [('endpoint', '192.168.1.20:47380')],
          deviceId: failedPeerId,
        ),
      ];
    await openDevices(tester, bridge);
    await pumpUntilFound(tester, find.text('Phone'));
    expect(find.textContaining('TLS failed'), findsNothing);
    expect(find.textContaining('192.168.1.20:47380'), findsNothing);
    expect(find.byKey(const Key('device-log-$failedPeerId')), findsNothing);

    await tapVisible(
      tester,
      find.byKey(const Key('device-details-$failedPeerId')),
    );
    expect(find.text('TLS failed: bad certificate'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('device-failure-code-$failedPeerId')),
          )
          .data,
      'TLS_FAILED',
    );
    String fact(String name) =>
        tester.widget<Text>(find.byKey(Key('device-fact-$name'))).data!;
    expect(fact('Endpoint'), '192.168.1.20:47380');
    // The endpoint of a failed attempt is the last one tried.
    expect(find.text('LAST ENDPOINT'), findsOneWidget);
    expect(fact('State'), 'Error');
    expect(find.text('LAST ATTEMPT'), findsOneWidget);
    expect(fact('Sync port'), 'UDP ${bridge.ports.syncPort}');
    expect(find.text('Connection log · 1 event'), findsOneWidget);
    final log = find.byKey(const Key('device-log-$failedPeerId'));
    expect(
      find.descendant(
        of: log,
        matching: find.text(
          'peer_dial_failed dial to peer endpoint failed '
          'endpoint=192.168.1.20:47380',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: log, matching: find.text('peer')),
      findsOneWidget,
    );

    await tapVisible(
      tester,
      find.byKey(const Key('device-reconnect-$failedPeerId')),
    );
    expect(bridge.reconnects, [failedPeerId]);
  });

  testWidgets('copy all places the diagnostic block on the clipboard', (
    tester,
  ) async {
    final copied = mockClipboard(tester);
    // Without a build identity the block has no version to report.
    final bridge = FakeCollectionBridge()
      ..buildInfoError = StateError('no build info')
      ..devices.add(failedPeer);
    await openDevices(tester, bridge);
    await pumpUntilFound(tester, find.text('Phone'));
    await tapVisible(
      tester,
      find.byKey(const Key('device-details-$failedPeerId')),
    );
    await tapVisible(
      tester,
      find.byKey(const Key('device-copy-$failedPeerId')),
    );
    expect(bridge.diagnosticBlockCalls, [failedPeerId]);
    expect(copied, hasLength(1));
    expect(copied.single, startsWith('Version: unknown\n'));
    expect(find.text('Log copied'), findsOneWidget);
  });

  testWidgets('a revoked row offers copy but no reconnect', (tester) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(
        const TrustedDeviceDto(
          deviceId: failedPeerId,
          friendlyName: 'Phone',
          pairedAtMs: 1,
          revoked: true,
          connection: PeerConnectionKindDto.offline,
        ),
      );
    await openDevices(tester, bridge);
    await pumpUntilFound(tester, find.text('Phone'));
    await tapVisible(
      tester,
      find.byKey(const Key('device-details-$failedPeerId')),
    );
    expect(find.byKey(const Key('device-copy-$failedPeerId')), findsOneWidget);
    expect(
      find.byKey(const Key('device-reconnect-$failedPeerId')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('device-details-connect-address-$failedPeerId')),
      findsNothing,
    );
    // Only the log, its filter and Copy log.
    expect(find.byKey(const Key('device-fact-State')), findsNothing);
    expect(find.byKey(const Key('device-fact-Endpoint')), findsNothing);
    expect(
      find.byKey(const Key('device-log-filter-$failedPeerId')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('device-log-$failedPeerId')), findsOneWidget);
  });

  testWidgets('the confirmation step shows the other device id', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    bridge.candidateController.add([
      PairingCandidateDto(
        instanceId: List.filled(16, '01').join(),
        endpoint: '192.0.2.1:4400',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
        alreadyPaired: false,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('pairing-peer-id')), findsNothing);
    expect(find.textContaining(failedPeerId), findsNothing);

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.awaitingConfirmation,
        session: 'session',
        sas: '42',
        peer: failedPeerId,
      ),
    );
    await tester.pump();
    await tester.pump();
    final groups = [
      for (var i = 0; i < failedPeerId.length; i += 8)
        failedPeerId.substring(i, i + 8),
    ].join(' ');
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('pairing-peer-id')))
          .data,
      groups,
    );
    expect(find.text('Device ID of the other device'), findsOneWidget);
    expect(find.text('Confirm the code'), findsOneWidget);
    expect(
      find.text(
        'Check the same code shows on the other device, then confirm on both.',
      ),
      findsOneWidget,
    );
    expect(findSas('000042'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(Key('pairing-sas-digit-$i')), findsOneWidget);
    }
    // Reject is on the left, Confirm on the right.
    expect(
      tester.getCenter(find.byKey(const Key('pairing-reject'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('pairing-confirm'))).dx),
    );
  });
}

void main() {
  diagnosticsTests();
  testWidgets('pairing renders candidates, expiry, SAS actions, and errors', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    expect(find.text('Pairing is open'), findsOneWidget);
    expect(find.textContaining('left of 2:00'), findsOneWidget);
    expect(find.byKey(const Key('pairing-countdown-ring')), findsOneWidget);

    final candidate = PairingCandidateDto(
      instanceId: List.filled(16, '01').join(),
      endpoint: '192.0.2.1:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: false,
    );
    bridge.candidateController.add([candidate]);
    await tester.pump();
    await tester.pump();
    expect(find.text('192.0.2.1:4400'), findsOneWidget);
    expect(find.text('Nearby · 1'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(
      find.text("Devices you've already paired are hidden."),
      findsOneWidget,
    );
    // Candidates show the endpoint only, never a device name.
    expect(find.text('Nearby device'), findsNothing);
    bridge.candidateController.add(const []);
    await tester.pump();
    await tester.pump();
    expect(find.text('192.0.2.1:4400'), findsNothing);

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.awaitingConfirmation,
        session: 'session',
        sas: '42',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(findSas('000042'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(bridge.confirmedSessions, ['session']);
    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(bridge.rejectedSessions, ['session']);

    bridge.pairingController.add(
      pairingState(PairingKindDto.failed, message: 'Pairing timed out.'),
    );
    // The stream event lands after the frame; no ink animation keeps another frame queued.
    await tester.pump();
    await tester.pump();
    expect(find.text('Pairing timed out.'), findsOneWidget);
  });

  testWidgets('device rows refresh rename, revoke, connection and sync state', (
    tester,
  ) async {
    final now = clock.now();
    final bridge = FakeCollectionBridge()
      ..status = SyncStatusDto.synced
      ..devices.add(
        TrustedDeviceDto(
          deviceId:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          friendlyName: 'Tablet',
          pairedAtMs: 1,
          lastSeenMs: now
              .subtract(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
          lastSyncMs: now
              .subtract(const Duration(hours: 3))
              .millisecondsSinceEpoch,
          revoked: false,
          connection: PeerConnectionKindDto.connected,
        ),
      );
    await openDevices(tester, bridge);
    expect(find.text('Synced'), findsWidgets);
    expect(find.textContaining('Connected'), findsOneWidget);
    // Status times read relatively, and a persisted sync time is never
    // "never".
    expect(find.text('Seen 30 min ago · Synced 3 h ago'), findsOneWidget);
    expect(find.textContaining('Never synced'), findsNothing);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('device-name')),
      'Kitchen tablet',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Kitchen tablet'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke / unpair'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke Kitchen tablet?'), findsOneWidget);
    expect(
      find.text(
        'It stops syncing with this device right away. It stays in the list '
        'as revoked, and you can pair it again later.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('revoke-keep')));
    await tester.pumpAndSettle();
    expect(bridge.revokedDevices, isEmpty);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke / unpair'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const Key('revoke-confirm'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('revoke-keep'))).dx),
    );
    await tester.tap(find.byKey(const Key('revoke-confirm')));
    await tester.pumpAndSettle();
    expect(bridge.revokedDevices, isNotEmpty);
    expect(find.textContaining('Revoked'), findsOneWidget);
  });

  testWidgets('relative status times advance without a device event', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(
        TrustedDeviceDto(
          deviceId:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          friendlyName: 'Tablet',
          pairedAtMs: 1,
          lastSeenMs: clock.now().millisecondsSinceEpoch,
          revoked: false,
          connection: PeerConnectionKindDto.connected,
        ),
      );
    await openDevices(tester, bridge);
    expect(find.text('Seen just now · Never synced'), findsOneWidget);

    await tester.pump(const Duration(seconds: 61));
    expect(find.text('Seen 1 min ago · Never synced'), findsOneWidget);
  });

  testWidgets('a revocation whose rotation failed stays revoked and retries', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextRotationError = 'secure key store is unavailable'
      ..devices.add(
        const TrustedDeviceDto(
          deviceId:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          friendlyName: 'Tablet',
          pairedAtMs: 1,
          revoked: false,
          connection: PeerConnectionKindDto.connected,
        ),
      );
    await openDevices(tester, bridge);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke / unpair'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('revoke-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Revoked'), findsOneWidget);
    expect(find.byKey(const Key('rotation-error')), findsOneWidget);
    expect(
      find.textContaining('secure key store is unavailable'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('retry-rotation')));
    await tester.pumpAndSettle();
    expect(bridge.rotationRetries, 1);
    expect(find.byKey(const Key('rotation-error')), findsNothing);
    expect(find.textContaining('Revoked'), findsOneWidget);
  });

  testWidgets(
    'every aggregate status has its own label and icon, and Searching does not '
    'reuse the pairing word',
    (tester) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);

      const expected = {
        SyncStatusDto.offline: 'Offline',
        SyncStatusDto.searching: 'Looking for paired devices',
        SyncStatusDto.connected: 'Connected',
        SyncStatusDto.syncing: 'Syncing',
        SyncStatusDto.synced: 'Synced',
        SyncStatusDto.error: 'Error',
        // At 720px and wider the paused chip says what is off.
        SyncStatusDto.paused: 'Paused · sync with paired devices is off',
      };
      final icons = <IconData>{};
      for (final entry in expected.entries) {
        bridge.status = entry.key;
        bridge.statusController.add(entry.key);
        await tester.pumpAndSettle();

        final chip = find.byKey(const Key('sync-status'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text(entry.value)),
          findsOneWidget,
          reason: '${entry.key} should read "${entry.value}"',
        );
        final icon = tester.widget<Icon>(
          find.descendant(of: chip, matching: find.byType(Icon)),
        );
        icons.add(icon.icon!);
      }
      // Seven values, seven icons: the status is readable without the label.
      expect(icons, hasLength(expected.length));
      // The pairing card keeps "Searching" for discovery; the aggregate must not reuse it.
      expect(find.text('Searching'), findsNothing);
    },
  );

  testWidgets('connection switches reflect, toggle, and survive a failure', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..preferences = const NetworkPreferencesDto(
        discoverable: false,
        syncEnabled: true,
      )
      ..devices.add(
        const TrustedDeviceDto(
          deviceId: 'peer',
          friendlyName: 'Peer',
          pairedAtMs: 1,
          lastSeenMs: null,
          lastSyncMs: null,
          revoked: false,
          connection: PeerConnectionKindDto.synced,
        ),
      );
    await openDevices(tester, bridge);
    await tester.pumpAndSettle();

    bool switchValue(String key) =>
        tester.widget<FiSwitchTile>(find.byKey(Key(key))).value;
    Finder switchOf(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(FiSwitch),
    );
    expect(switchValue('pref-discoverable'), isFalse);
    expect(switchValue('pref-sync'), isTrue);

    // Rust reports every row paused once sync is off.
    bridge.devices[0] = const TrustedDeviceDto(
      deviceId: 'peer',
      friendlyName: 'Peer',
      pairedAtMs: 1,
      lastSeenMs: null,
      lastSyncMs: null,
      revoked: false,
      connection: PeerConnectionKindDto.paused,
    );
    await tester.tap(switchOf('pref-sync'));
    await tester.pumpAndSettle();
    expect(bridge.preferenceCalls, ['sync=false']);
    expect(switchValue('pref-sync'), isFalse);
    final chip = find.byKey(const Key('sync-status'));
    expect(
      find.descendant(
        of: chip,
        matching: find.text('Paused · sync with paired devices is off'),
      ),
      findsOneWidget,
    );
    expect(find.text('Paused on this device · never synced'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('Peer'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: row.first, matching: find.text('Paused')),
      findsOneWidget,
    );

    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.persistence,
      issues: [],
      message: 'Local data could not be saved or loaded.',
      resetResolvable: false,
    );
    await tester.tap(switchOf('pref-discoverable'));
    await tester.pumpAndSettle();
    expect(switchValue('pref-discoverable'), isFalse);
    // The error sits under that switch, not in a page banner.
    expect(find.byKey(const Key('pref-discoverable-error')), findsOneWidget);
    expect(find.text("Couldn't change this. Try again."), findsOneWidget);
    expect(find.byKey(const Key('pref-sync-error')), findsNothing);
    expect(find.text('Local data could not be saved or loaded.'), findsNothing);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('pref-discoverable-error'))).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const Key('pref-discoverable'))).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('pref-discoverable-error'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('pref-sync'))).dy),
    );

    // The next toggle of that switch clears it.
    await tester.tap(switchOf('pref-discoverable'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pref-discoverable-error')), findsNothing);
  });

  testWidgets('the connection switches show with no paired device', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pref-discoverable')), findsOneWidget);
    expect(find.byKey(const Key('pref-sync')), findsOneWidget);
    expect(find.text('No devices paired yet'), findsOneWidget);
  });

  for (final discoverable in [true, false]) {
    testWidgets('empty state with discoverable=$discoverable', (tester) async {
      final bridge = FakeCollectionBridge()
        ..preferences = NetworkPreferencesDto(
          discoverable: discoverable,
          syncEnabled: false,
        );
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-devices')), findsOneWidget);
      expect(find.text('Trusted devices · 0'.toUpperCase()), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('no-devices-body'))).data,
        "Start pairing on both devices while they're nearby. "
        'Pairing turns itself off after 2 minutes.',
      );
      expect(
        find.text(
          PairingCard.discoveryOffNote(
            lookupAppLocalizations(const Locale('en')),
          ),
        ),
        discoverable ? findsNothing : findsOneWidget,
      );
      final start = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('start-pairing')),
      );
      expect(start.onPressed, isNotNull);
      expect(find.byKey(const Key('pairing-card')), findsNothing);
    });
  }

  testWidgets('a locked keystore replaces the committing spinner with retry', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    bridge.pairingController.add(
      pairingState(
        PairingKindDto.awaitingConfirmation,
        session: 'session',
        sas: '42',
        peer: failedPeerId,
      ),
    );
    await tester.pump();
    await tester.pump();
    bridge.pairingController.add(
      pairingState(
        PairingKindDto.committing,
        session: 'session',
        peer: failedPeerId,
      ),
    );
    await tester.pump();
    await tester.pump();
    // Saving keeps the code with both actions unavailable.
    expect(find.text('Saving trust…'), findsOneWidget);
    expect(findSas('000042'), findsOneWidget);
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const Key('pairing-confirm')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const Key('pairing-reject')))
          .onPressed,
      isNull,
    );

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.failed,
        failure: PairingFailureKindDto.secureStoreLocked,
        message: 'secure key store is locked',
      ),
    );
    await tester.pump();
    await tester.pump();
    // The spinner is gone at once, the code and id stay, and the copy names
    // the keyring, never an expiry.
    expect(find.text('Saving trust…'), findsNothing);
    expect(
      find.byKey(const Key('pairing-secure-store-locked')),
      findsOneWidget,
    );
    expect(
      find.text('Unlock your desktop keyring, then retry.'),
      findsOneWidget,
    );
    expect(findSas('000042'), findsOneWidget);
    expect(find.byKey(const Key('pairing-peer-id')), findsOneWidget);
    expect(find.byKey(const Key('pairing-confirm')), findsNothing);
    expect(find.textContaining('expired'), findsNothing);
    expect(find.textContaining('left of'), findsNothing);

    await tester.tap(find.byKey(const Key('pairing-retry-after-unlock')));
    await tester.pump();
    expect(bridge.retryNetworkingCalls, 1);
    expect(bridge.pairingCalls, contains('retryNetworking'));
  });

  testWidgets('already paired candidates are hidden and explained', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();

    final paired = PairingCandidateDto(
      instanceId: List.filled(16, '03').join(),
      endpoint: '192.0.2.9:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: true,
    );
    bridge.candidateController.add([paired]);
    await tester.pump();
    await tester.pump();
    expect(find.text('192.0.2.9:4400'), findsNothing);
    expect(find.byKey(const Key('candidates-already-paired')), findsOneWidget);
    expect(find.text('All nearby devices are already paired.'), findsOneWidget);
    expect(find.text('No nearby pairing candidates yet.'), findsNothing);

    final fresh = PairingCandidateDto(
      instanceId: List.filled(16, '04').join(),
      endpoint: '192.0.2.10:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: false,
    );
    bridge.candidateController.add([paired, fresh]);
    await tester.pump();
    await tester.pump();
    expect(find.text('192.0.2.10:4400'), findsOneWidget);
    expect(find.text('192.0.2.9:4400'), findsNothing);
    expect(find.byKey(const Key('candidates-already-paired')), findsNothing);
  });

  testWidgets('only revoked rows offer a confirmed delete', (tester) async {
    final bridge = FakeCollectionBridge()
      ..devices.addAll(const [
        TrustedDeviceDto(
          deviceId:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          friendlyName: 'Tablet',
          pairedAtMs: 1,
          revoked: false,
          connection: PeerConnectionKindDto.offline,
        ),
        TrustedDeviceDto(
          deviceId:
              'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
          friendlyName: 'Old phone',
          pairedAtMs: 2,
          revoked: true,
          connection: PeerConnectionKindDto.offline,
        ),
      ]);
    await openDevices(tester, bridge);
    expect(find.textContaining('1 paired'), findsOneWidget);

    // A trusted row offers rename and revoke, never delete.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Revoke / unpair'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    // Cancelling the confirmation makes no bridge call.
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Revoke / unpair'), findsNothing);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete revoked device?'), findsOneWidget);
    expect(
      find.text('Removes Old phone from this list. It can be paired again.'),
      findsOneWidget,
    );
    expect(
      tester.getCenter(find.byKey(const Key('delete-confirm'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('delete-keep'))).dx),
    );
    await tester.tap(find.byKey(const Key('delete-keep')));
    await tester.pumpAndSettle();
    expect(bridge.deletedDevices, isEmpty);
    expect(find.text('Old phone'), findsOneWidget);

    // Confirming removes the row; the trusted count is unchanged.
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(bridge.deletedDevices, [
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
    ]);
    expect(find.text('Old phone'), findsNothing);
    expect(find.text('Tablet'), findsOneWidget);
    expect(find.textContaining('1 paired'), findsOneWidget);
  });

  group('build label', () {
    Future<void> openWithBuild(
      WidgetTester tester,
      FakeCollectionBridge bridge, {
      Size size = const Size(800, 1200),
    }) async {
      await openDevices(tester, bridge);
      tester.view.physicalSize = size;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
    }

    const clean = BuildInfoDto(
      version: '0.1.21',
      gitHash: 'a1b2c3d',
      dirty: false,
    );

    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pump();
    }

    testWidgets('is in Settings › About on a wide screen, not in the sidebar', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()..buildIdentity = clean;
      await openWithBuild(tester, bridge, size: const Size(1240, 900));
      final label = find.byKey(const Key('build-version'));
      expect(
        find.descendant(of: find.byKey(const Key('sidebar')), matching: label),
        findsNothing,
      );
      await openSettings(tester);
      await pumpUntilFound(tester, label);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-about')),
          matching: find.text('fi 0.1.21 · a1b2c3d'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('sits in Settings › About on a phone, not on Devices', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()..buildIdentity = clean;
      await openWithBuild(tester, bridge, size: const Size(390, 900));
      final label = find.byKey(const Key('build-version'));
      final devicesPage = find.byKey(const Key('devices-page'));
      expect(find.descendant(of: devicesPage, matching: label), findsNothing);
      await tester.tap(find.text('Settings'));
      await tester.pump();
      await pumpUntilFound(tester, label);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-about')),
          matching: find.text('fi 0.1.21 · a1b2c3d'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('marks a dirty build', (tester) async {
      final bridge = FakeCollectionBridge()
        ..buildIdentity = const BuildInfoDto(
          version: '0.1.21',
          gitHash: 'a1b2c3d',
          dirty: true,
        );
      await openWithBuild(tester, bridge);
      await openSettings(tester);
      await pumpUntilFound(tester, find.byKey(const Key('build-version')));
      expect(find.text('fi 0.1.21 · a1b2c3d-dirty'), findsOneWidget);
    });

    testWidgets('reads unknown without a hash', (tester) async {
      final bridge = FakeCollectionBridge()
        ..buildIdentity = const BuildInfoDto(
          version: '0.1.21',
          gitHash: 'unknown',
          dirty: false,
        );
      await openWithBuild(tester, bridge);
      await openSettings(tester);
      await pumpUntilFound(tester, find.byKey(const Key('build-version')));
      expect(find.text('fi 0.1.21 · unknown'), findsOneWidget);
    });

    testWidgets('is shown with no device paired', (tester) async {
      final bridge = FakeCollectionBridge()..buildIdentity = clean;
      await openWithBuild(tester, bridge);
      await pumpUntilFound(tester, find.text('No devices paired yet'));
      await openSettings(tester);
      await pumpUntilFound(tester, find.byKey(const Key('build-version')));
    });

    testWidgets('is absent when the query fails; the rest still renders', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()
        ..buildInfoError = StateError('no build info');
      await openWithBuild(tester, bridge);
      await pumpUntilFound(tester, find.text('No devices paired yet'));
      expect(find.byKey(const Key('start-pairing')), findsOneWidget);
      expect(find.byKey(const Key('build-version')), findsNothing);
    });
  });
}
