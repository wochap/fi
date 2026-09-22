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
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder.');
}

const tablet = TrustedDeviceDto(
  deviceId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  friendlyName: 'Tablet',
  pairedAtMs: 1,
  revoked: false,
  connection: PeerConnectionKindDto.connected,
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
  await tester.drag(
    find.byKey(const Key('devices-page')),
    const Offset(0, -800),
  );
  await tester.pump();
}

void main() {
  testWidgets('declining the reset confirmation changes nothing', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..devices.add(tablet);
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-dataset-dialog')), findsOneWidget);
    expect(
      find.text('This deletes the only copy of the dataset on this device.'),
      findsOneWidget,
    );
    expect(find.text('Your other devices keep their copies.'), findsOneWidget);
    expect(
      find.text('If this is the only device, the data is permanently lost.'),
      findsOneWidget,
    );
    expect(
      find.text('Other devices are not told about this reset.'),
      findsOneWidget,
    );
    expect(
      find.text('This device currently trusts 1 other device.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('reset-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-dataset-dialog')), findsNothing);
    expect(bridge.pairingCalls, isNot(contains('resetDataset')));
    expect(bridge.bootstrap.kind, BootstrapKindDto.ready);
    expect(bridge.devices, [tablet]);
    expect(find.byKey(const Key('devices-page')), findsOneWidget);
  });

  testWidgets('confirming the reset from devices lands on onboarding', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..devices.add(tablet);
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-confirm')));
    await pumpUntilFound(tester, find.byKey(const Key('create-dataset')));
    expect(bridge.pairingCalls, contains('resetDataset'));
    expect(bridge.bootstrap.kind, BootstrapKindDto.needsDecision);
    expect(find.text('Collections'), findsNothing);
    expect(find.byKey(const Key('bootstrap-error')), findsNothing);
  });

  testWidgets('the fatal surface offers reset only for resolvable errors', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..nextError = const BridgeError(
        kind: BridgeErrorKind.initialization,
        message: 'The secure key store is locked.',
        resetResolvable: false,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.byKey(const Key('retry-bootstrap')), findsOneWidget);
    expect(find.byKey(const Key('reset-dataset')), findsNothing);

    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.bootstrap,
      message: 'Incompatible application version.',
      resetResolvable: true,
    );
    await tester.tap(find.byKey(const Key('retry-bootstrap')));
    await pumpUntilFound(tester, find.byKey(const Key('reset-dataset')));
    expect(find.byKey(const Key('retry-bootstrap')), findsNothing);
    expect(find.text('Incompatible application version.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-dataset-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-confirm')));
    await pumpUntilFound(tester, find.byKey(const Key('create-dataset')));
    expect(bridge.pairingCalls, contains('resetDataset'));
    expect(find.byKey(const Key('bootstrap-error')), findsNothing);
  });

  testWidgets('the root-mismatch outcome exposes the reset action', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..status = SyncStatusDto.searching;
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    bridge.pairingController.add(
      const PairingStateDto(
        kind: PairingKindDto.failed,
        localConfirmed: false,
        remoteConfirmed: false,
        failure: PairingFailureKindDto.rootMismatch,
        alreadyPaired: false,
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const Key('pairing-root-mismatch')),
    );
    expect(find.byKey(const Key('reset-dataset')), findsOneWidget);
    expect(find.text('Pair a different device'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-dataset-dialog')), findsOneWidget);
    expect(
      find.textContaining("this device's local data must be reset first"),
      findsWidgets,
    );
    await tester.tap(find.byKey(const Key('reset-cancel')));
    await tester.pumpAndSettle();
    expect(bridge.pairingCalls, isNot(contains('resetDataset')));
  });
}
