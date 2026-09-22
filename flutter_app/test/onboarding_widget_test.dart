import 'package:fi/app.dart';
import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
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
);

const peerId =
    '3f9a2c1b3f9a2c1b3f9a2c1b3f9a2c1b3f9a2c1b3f9a2c1b3f9a2c1b3f9a2c1b';

/// Bridge that admits only the calls valid before a root exists. Any other
/// call is a root-dependent addition that would break onboarding silently.
final class RootlessBridge implements CollectionBridge {
  RootlessBridge(this.inner);
  final FakeCollectionBridge inner;
  final List<String> rejected = [];

  @override
  Stream<PairingStateDto> pairingStateEvents() => inner.pairingStateEvents();
  @override
  Stream<List<PairingCandidateDto>> pairingCandidateEvents() =>
      inner.pairingCandidateEvents();
  @override
  Stream<List<TrustedDeviceDto>> connectionStateEvents() =>
      inner.connectionStateEvents();
  @override
  Stream<SyncStatusDto> syncStatusEvents() => inner.syncStatusEvents();
  @override
  Future<List<TrustedDeviceDto>> trustedDevices() => inner.trustedDevices();
  @override
  Future<SyncStatusDto> syncStatus() => inner.syncStatus();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    rejected.add(invocation.memberName.toString());
    throw const BridgeError(
      kind: BridgeErrorKind.lifecycle,
      message: 'A local dataset is required.',
      resetResolvable: false,
    );
  }
}

void main() {
  test(
    'DevicesController.start() only makes rootless-safe bridge calls',
    () async {
      final bridge = RootlessBridge(
        FakeCollectionBridge()..status = SyncStatusDto.searching,
      );
      final controller = DevicesController(bridge);
      await controller.start();
      expect(bridge.rejected, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(controller.syncStatus, SyncStatusDto.searching);
      controller.dispose();
    },
  );

  testWidgets('a rootless start offers pairing without creating a dataset', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()..status = SyncStatusDto.searching;
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    expect(find.byKey(const Key('pairing-card')), findsNothing);
    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    expect(find.byKey(const Key('pairing-card')), findsOneWidget);
    expect(find.byKey(const Key('pairing-preconditions')), findsOneWidget);
    expect(find.textContaining('must already have a dataset'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    expect(find.textContaining('Searching for nearby devices'), findsOneWidget);
    expect(bridge.bootstrap.kind, BootstrapKindDto.needsDecision);
    expect(find.text('Collections'), findsNothing);

    // Onboarding is still rootless; the controller reads the live status.
    final candidate = PairingCandidateDto(
      instanceId: List.filled(16, '02').join(),
      endpoint: '192.0.2.7:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
    );
    bridge.candidateController.add([candidate]);
    await tester.pump();
    expect(find.byKey(const Key('single-initiator-hint')), findsOneWidget);
    expect(find.textContaining('one device only'), findsWidgets);
  });

  testWidgets('pairing blocks create with a reason until stopped', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    FilledButton create() =>
        tester.widget<FilledButton>(find.byKey(const Key('create-dataset')));
    expect(create().onPressed, isNotNull);
    expect(find.byKey(const Key('create-blocked-reason')), findsNothing);

    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-pairing')));
    await tester.pump();
    expect(create().onPressed, isNull);
    expect(find.byKey(const Key('create-blocked-reason')), findsOneWidget);
    expect(find.textContaining('Stop pairing'), findsWidgets);

    await tester.ensureVisible(find.byKey(const Key('stop-pairing')));
    await tester.tap(find.byKey(const Key('stop-pairing')));
    await tester.pump();
    await tester.pump();
    expect(create().onPressed, isNotNull);
    expect(find.byKey(const Key('create-blocked-reason')), findsNothing);
    expect(bridge.bootstrap.kind, BootstrapKindDto.needsDecision);
  });

  testWidgets('create closes any pairing window before issuing the create', (
    tester,
  ) async {
    // The stream may not have delivered an open window yet, so the button is
    // still enabled; the create path must close the window regardless.
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('create-dataset')));
    await tester.tap(find.byKey(const Key('create-dataset')));
    await pumpUntilFound(tester, find.text('Collections'));
    expect(bridge.pairingCalls, ['stopPairing', 'createNewDataset']);
  });

  testWidgets('the joining surface names the provisioning device', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    bridge.devices.add(
      const TrustedDeviceDto(
        deviceId: peerId,
        friendlyName: 'Fi 3f9a2c1b',
        pairedAtMs: 1,
        revoked: false,
        connection: PeerConnectionKindDto.connected,
      ),
    );
    bridge.pairingController.add(
      pairingState(PairingKindDto.trusted, peer: peerId),
    );
    bridge.bootstrapController.add(
      const BootstrapDto(kind: BootstrapKindDto.joining, rootId: 'root'),
    );
    await pumpUntilFound(tester, find.byKey(const Key('joining-surface')));
    await pumpUntilFound(
      tester,
      find.text('Joining dataset from Fi 3f9a2c1b…'),
    );
  });

  testWidgets('the joining surface falls back to unnamed copy', (tester) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.joining,
        rootId: 'root',
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('joining-surface')));
    expect(
      find.text('Waiting for this local dataset to become available.'),
      findsOneWidget,
    );
    expect(find.textContaining('Joining dataset from'), findsNothing);
  });

  testWidgets(
    'confirming the SAS spans needs-decision → joining → ready without '
    'notifying a disposed controller',
    (tester) async {
      final bridge = FakeCollectionBridge();
      await tester.pumpWidget(testApp(bridge));
      await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
      await tester.tap(find.byKey(const Key('join-dataset')));
      await tester.pump();
      bridge.pairingController.add(
        pairingState(
          PairingKindDto.awaitingConfirmation,
          session: 'session',
          sas: '42',
        ),
      );
      await tester.pump();
      expect(find.text('000042'), findsOneWidget);

      // Advance bootstrap while `confirm` is still awaiting the bridge.
      bridge.confirmDelay = () async {
        bridge.bootstrapController.add(
          const BootstrapDto(kind: BootstrapKindDto.joining, rootId: 'root'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        bridge.bootstrapController.add(
          const BootstrapDto(kind: BootstrapKindDto.ready, rootId: 'root'),
        );
      };
      await tester.ensureVisible(find.text('Codes match'));
      await tester.tap(find.text('Codes match'));
      await pumpUntilFound(tester, find.byKey(const Key('joining-surface')));
      await pumpUntilFound(tester, find.text('Collections'));
      await tester.pumpAndSettle();
      expect(bridge.confirmedSessions, ['session']);
      expect(tester.takeException(), isNull);
      // The same controller still drives the devices tab.
      await tester.tap(find.text('Devices').last);
      await tester.pump();
      expect(find.byKey(const Key('pairing-card')), findsOneWidget);
    },
  );

  testWidgets('root mismatch and both-rootless render guidance', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.failed,
        message: 'both devices need a root dataset',
        failure: PairingFailureKindDto.bothRootless,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('pairing-both-rootless')), findsOneWidget);
    expect(find.text('both devices need a root dataset'), findsNothing);

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.failed,
        message: 'the devices have different root datasets',
        failure: PairingFailureKindDto.rootMismatch,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('pairing-root-mismatch')), findsOneWidget);
    expect(find.textContaining('cannot be merged'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
