import 'package:clock/clock.dart';
import 'package:fi/app.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';

Widget testApp(FakeCollectionBridge bridge) => CollectionApp(
  bridge: bridge,
  initializeRust: () async {},
  dataDirProvider: () async => '/test',
  setPlatformForeground: (_) async {},
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
  String? message,
  PairingFailureKindDto? failure,
}) => PairingStateDto(
  kind: kind,
  sessionId: session,
  sas: sas,
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
  bridge.bootstrap = const BootstrapDto(
    kind: BootstrapKindDto.ready,
    rootId: 'root',
  );
  await tester.pumpWidget(testApp(bridge));
  await pumpUntilFound(tester, find.text('Collections'));
  await tester.tap(find.text('Devices').last);
  await tester.pump();
}

void main() {
  testWidgets('pairing renders candidates, expiry, SAS actions, and errors', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    expect(find.textContaining('Searching for nearby devices'), findsOneWidget);

    final candidate = PairingCandidateDto(
      instanceId: List.filled(16, '01').join(),
      endpoint: '192.0.2.1:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: false,
    );
    bridge.candidateController.add([candidate]);
    await tester.pump();
    expect(find.text('192.0.2.1:4400'), findsOneWidget);
    bridge.candidateController.add(const []);
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
    expect(find.text('000042'), findsOneWidget);
    await tester.tap(find.text('Codes match'));
    await tester.pump();
    expect(bridge.confirmedSessions, ['session']);
    await tester.tap(find.text('Codes do not match'));
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
    expect(
      find.textContaining('Last seen 30 min ago · Last sync 3 h ago'),
      findsOneWidget,
    );
    expect(find.textContaining('Last sync never'), findsNothing);

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
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
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
    expect(find.textContaining('Last seen just now'), findsOneWidget);

    await tester.pump(const Duration(seconds: 61));
    expect(find.textContaining('Last seen 1 min ago'), findsOneWidget);
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
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
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
      // Six values, six icons: the status is readable without the label.
      expect(icons, hasLength(expected.length));
      // The pairing card keeps "Searching" for discovery; the aggregate must not reuse it.
      expect(find.text('Searching'), findsNothing);
    },
  );

  testWidgets('a locked keystore replaces the committing spinner with retry', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    bridge.pairingController.add(
      pairingState(PairingKindDto.committing, session: 'session'),
    );
    await tester.pump();
    expect(
      find.text('Saving trust and synchronizing the dataset\u2026'),
      findsOneWidget,
    );

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.failed,
        failure: PairingFailureKindDto.secureStoreLocked,
        message: 'secure key store is locked',
      ),
    );
    await tester.pump();
    // The spinner is gone at once, and the copy names the keyring, never an
    // expiry.
    expect(
      find.text('Saving trust and synchronizing the dataset\u2026'),
      findsNothing,
    );
    expect(
      find.byKey(const Key('pairing-secure-store-locked')),
      findsOneWidget,
    );
    expect(find.textContaining('expired'), findsNothing);

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
    expect(find.text('192.0.2.9:4400'), findsNothing);
    expect(find.byKey(const Key('candidates-already-paired')), findsOneWidget);
    expect(find.text('No nearby pairing candidates yet.'), findsNothing);

    final fresh = PairingCandidateDto(
      instanceId: List.filled(16, '04').join(),
      endpoint: '192.0.2.10:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: false,
    );
    bridge.candidateController.add([paired, fresh]);
    await tester.pump();
    expect(find.text('192.0.2.10:4400'), findsOneWidget);
    expect(find.text('192.0.2.9:4400'), findsNothing);
    expect(find.byKey(const Key('candidates-already-paired')), findsNothing);
  });
}
