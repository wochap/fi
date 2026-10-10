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
  announcedName: 'Tablet',
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
    expect(find.text("Reset this device's data?"), findsOneWidget);
    expect(
      find.textContaining('This deletes the only copy of the dataset'),
      findsOneWidget,
    );
    expect(
      find.text('1 trusted device is kept and can be paired again.'),
      findsOneWidget,
    );
    expect(find.text('Keep data'), findsOneWidget);
    // "Reset data" waits for the acknowledgement.
    final reset = find.byKey(const Key('reset-confirm'));
    expect(tester.widget<TextButton>(reset).onPressed, isNull);
    await tester.tap(find.text("I understand this can't be undone"));
    await tester.pump();
    expect(tester.widget<TextButton>(reset).onPressed, isNotNull);
    // Destructive secondary on the left, safe primary on the right.
    expect(
      tester.getCenter(reset).dx,
      lessThan(tester.getCenter(find.byKey(const Key('reset-cancel'))).dx),
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
    await tester.tap(find.byKey(const Key('reset-acknowledge')));
    await tester.pump();
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
        issues: [],
        message: 'The secure key store is locked.',
        resetResolvable: false,
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('bootstrap-error')));
    expect(find.byKey(const Key('retry-bootstrap')), findsOneWidget);
    expect(find.byKey(const Key('reset-dataset')), findsNothing);

    bridge.nextError = const BridgeError(
      kind: BridgeErrorKind.bootstrap,
      issues: [],
      message: 'Incompatible application version.',
      resetResolvable: true,
    );
    await tester.tap(find.byKey(const Key('retry-bootstrap')));
    await pumpUntilFound(tester, find.byKey(const Key('reset-dataset')));
    expect(find.byKey(const Key('retry-bootstrap')), findsNothing);
    expect(find.text("Fi couldn't start"), findsOneWidget);
    expect(
      find.textContaining("This device's local data can't be opened."),
      findsOneWidget,
    );
    // Rust's wording goes behind Copy details, not on the surface.
    expect(find.text('Incompatible application version.'), findsNothing);
    expect(find.byKey(const Key('copy-error-details')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-dataset-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-acknowledge')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reset-confirm')));
    await pumpUntilFound(tester, find.byKey(const Key('create-dataset')));
    expect(bridge.pairingCalls, contains('resetDataset'));
    expect(find.byKey(const Key('bootstrap-error')), findsNothing);
  });

  testWidgets('the count line has singular, plural and zero forms', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..devices.addAll([
        tablet,
        for (final n in [1, 2])
          TrustedDeviceDto(
            deviceId: '$n' * 64,
            friendlyName: 'Peer $n',
            announcedName: 'Peer $n',
            pairedAtMs: 1,
            revoked: false,
            connection: PeerConnectionKindDto.offline,
          ),
      ]);
    await openDevices(tester, bridge);
    await tester.tap(find.byKey(const Key('reset-dataset')));
    await tester.pumpAndSettle();
    expect(
      find.text('3 trusted devices are kept and can be paired again.'),
      findsOneWidget,
    );
  });

  testWidgets('the root-mismatch outcome opens the different-dataset screen', (
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
    await pumpUntilFound(tester, find.byKey(const Key('dataset-mismatch')));
    expect(find.text('This device has a different dataset'), findsOneWidget);
    expect(find.byKey(const Key('reset-dataset')), findsOneWidget);
    expect(find.text('Pair a different device'), findsOneWidget);
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

  testWidgets('Back from a Devices-page mismatch pops with pairing idle', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..devices.add(tablet);
    await openDevices(tester, bridge);
    await tester.drag(
      find.byKey(const Key('devices-page')),
      const Offset(0, 800),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('pairing-card')), findsOneWidget);
    bridge.pairingController.add(
      const PairingStateDto(
        kind: PairingKindDto.failed,
        localConfirmed: false,
        remoteConfirmed: false,
        failure: PairingFailureKindDto.rootMismatch,
        alreadyPaired: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dataset-mismatch')), findsOneWidget);
    // Tablet is trusted, but the mismatched peer is not: the unnamed copy.
    expect(
      find.textContaining('The other device uses another dataset'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);

    await tester.tap(find.byKey(const Key('dataset-mismatch-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dataset-mismatch')), findsNothing);
    expect(find.byKey(const Key('devices-page')), findsOneWidget);
    expect(bridge.pairing.kind, PairingKindDto.idle);
    expect(find.byKey(const Key('pairing-card')), findsNothing);
  });
}
