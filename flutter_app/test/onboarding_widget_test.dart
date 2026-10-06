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
  alreadyPaired: false,
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
  Future<NetworkPreferencesDto> networkPreferences() =>
      inner.networkPreferences();
  @override
  Future<BuildInfoDto> buildInfo() => inner.buildInfo();
  @override
  Future<void> setBuildInfo(String version) => inner.setBuildInfo(version);
  @override
  Future<LocalDeviceDto?> localDevice() => inner.localDevice();
  @override
  Future<List<String>> localSyncAddresses() => inner.localSyncAddresses();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    rejected.add(invocation.memberName.toString());
    throw const BridgeError(
      kind: BridgeErrorKind.lifecycle,
      issues: [],
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
      expect(controller.failure, isNull);
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
    // The Join card states both preconditions before pairing can fail on them.
    expect(
      find.text('The other device must already have a dataset.'),
      findsOneWidget,
    );
    expect(
      find.text('Start the connection from only one of the two devices.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('pairing-card')), findsOneWidget);
    expect(find.text('Pairing is open'), findsOneWidget);
    expect(bridge.bootstrap.kind, BootstrapKindDto.needsDecision);
    expect(find.text('Collections'), findsNothing);

    // Onboarding is still rootless; the controller reads the live status.
    final candidate = PairingCandidateDto(
      instanceId: List.filled(16, '02').join(),
      endpoint: '192.0.2.7:4400',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
      alreadyPaired: false,
    );
    bridge.candidateController.add([candidate]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('single-initiator-hint')), findsOneWidget);
    expect(find.text('192.0.2.7:4400'), findsOneWidget);
    // Candidates are anonymous: the list shows the endpoint, not an id.
    expect(find.byKey(const Key('pairing-peer-id')), findsNothing);
    expect(find.textContaining(peerId), findsNothing);

    bridge.pairingController.add(
      pairingState(
        PairingKindDto.awaitingConfirmation,
        session: 'session',
        sas: '42',
        peer: peerId,
      ),
    );
    await tester.pump();
    expect(findSas('000042'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('pairing-peer-id')))
          .data
          ?.replaceAll(' ', ''),
      peerId,
    );
    expect(find.text('Device ID of the other device'), findsOneWidget);
  });

  testWidgets('pairing blocks create with a reason until stopped', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    expect(find.byKey(const Key('choice-locked-reason')), findsNothing);
    expect(find.byKey(const Key('pairing-status-row')), findsNothing);

    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('join-back')));
    await tester.pump();
    expect(find.byKey(const Key('choice-locked-reason')), findsOneWidget);
    expect(
      find.text(
        'Not available while pairing is open. Stop pairing to create one '
        'instead.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pairing is open · '), findsOneWidget);
    // The locked card is inert.
    await tester.tap(find.byKey(const Key('create-dataset')));
    await tester.pump();
    expect(bridge.pairingCalls, isNot(contains('createNewDataset')));

    expect(
      tester.getSize(find.byKey(const Key('stop-pairing'))).height,
      greaterThanOrEqualTo(44),
    );
    await tester.ensureVisible(find.byKey(const Key('stop-pairing')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('stop-pairing')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('choice-locked-reason')), findsNothing);
    expect(find.byKey(const Key('pairing-status-row')), findsNothing);
    expect(bridge.bootstrap.kind, BootstrapKindDto.needsDecision);
  });

  testWidgets('Join starts pairing at once and Back keeps it open', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge();
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('join-dataset')));
    await tester.tap(find.byKey(const Key('join-dataset')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('join-view')), findsOneWidget);
    expect(find.text('Join an existing dataset'), findsOneWidget);
    expect(
      find.text(
        'Start pairing on the other device too. Tap Connect on one device '
        'only.',
      ),
      findsOneWidget,
    );
    expect(bridge.pairing.kind, PairingKindDto.discoverable);
    expect(find.byKey(const Key('start-pairing')), findsNothing);
    expect(find.byKey(const Key('pairing-time-left')), findsOneWidget);

    await tester.tap(find.byKey(const Key('join-back')));
    await tester.pump();
    expect(find.byKey(const Key('onboarding')), findsOneWidget);
    expect(find.byKey(const Key('choice-locked-reason')), findsOneWidget);
    expect(bridge.pairing.kind, PairingKindDto.discoverable);
    expect(bridge.pairingCalls, isNot(contains('stopPairing')));
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
    await pumpUntilFound(tester, find.text('Joining “Fi 3f9a2c1b”'));
    expect(
      find.text(
        'Copying the dataset from Fi 3f9a2c1b. Keep both devices open until '
        'this finishes.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('setup-ring')), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('the joining surface falls back to unnamed copy', (tester) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.joining,
        rootId: 'root',
      );
    await tester.pumpWidget(testApp(bridge));
    await pumpUntilFound(tester, find.byKey(const Key('joining-surface')));
    expect(find.text('Joining the other device'), findsOneWidget);
    expect(
      find.text(
        'Copying the dataset from the other device. Keep both devices open '
        'until this finishes.',
      ),
      findsOneWidget,
    );
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
      expect(findSas('000042'), findsOneWidget);

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
      await tester.ensureVisible(find.byKey(const Key('pairing-confirm')));
      await tester.tap(find.byKey(const Key('pairing-confirm')));
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

  testWidgets('both-rootless becomes Couldn\'t join; Back frees Create', (
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
    expect(find.byKey(const Key('couldnt-join')), findsOneWidget);
    expect(find.text("Couldn't join"), findsOneWidget);
    expect(
      find.text(
        'The other device has no dataset yet. Create one there first, or '
        'create one here.',
      ),
      findsOneWidget,
    );
    expect(find.text('both devices need a root dataset'), findsNothing);

    await tester.tap(find.byKey(const Key('couldnt-join-back')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('onboarding')), findsOneWidget);
    expect(bridge.pairing.kind, PairingKindDto.idle);
    expect(find.byKey(const Key('choice-locked-reason')), findsNothing);
  });

  testWidgets('root mismatch in onboarding replaces the Join view', (
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
        message: 'the devices have different root datasets',
        failure: PairingFailureKindDto.rootMismatch,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('dataset-mismatch')), findsOneWidget);
    expect(find.byKey(const Key('join-view')), findsNothing);
    expect(find.text('Try again'), findsNothing);

    await tester.tap(find.byKey(const Key('pair-different-device')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('join-view')), findsOneWidget);
    expect(bridge.pairing.kind, PairingKindDto.discoverable);
  });
}
