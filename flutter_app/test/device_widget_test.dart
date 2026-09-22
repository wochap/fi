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
}) => PairingStateDto(
  kind: kind,
  sessionId: session,
  sas: sas,
  localConfirmed: false,
  remoteConfirmed: false,
  message: message,
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
    await tester.pump();
    expect(find.text('Pairing timed out.'), findsOneWidget);
  });

  testWidgets('device rows refresh rename, revoke, connection and sync state', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..status = SyncStatusDto.synced
      ..devices.add(
        const TrustedDeviceDto(
          deviceId:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          friendlyName: 'Tablet',
          pairedAtMs: 1,
          lastSeenMs: 2,
          lastSyncMs: 3,
          revoked: false,
          connection: PeerConnectionKindDto.connected,
        ),
      );
    await openDevices(tester, bridge);
    expect(find.text('Synced'), findsWidgets);
    expect(find.textContaining('Connected'), findsOneWidget);

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
}
