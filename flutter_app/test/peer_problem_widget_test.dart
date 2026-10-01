import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_widget_test.dart' show pumpUntilFound, tapVisible, testApp;
import 'fake_bridge.dart';

const peerId =
    'f755167e0123456789abcdef0123456789abcdef0123456789abcdeff755167e';

TrustedDeviceDto unreachable({
  ConnectionFailureKindDto? kind = ConnectionFailureKindDto.noRoute,
  PeerConnectionKindDto connection = PeerConnectionKindDto.error,
  String? failure = 'no eligible endpoint',
  String? lastKnown = '192.168.0.165:47380',
}) => TrustedDeviceDto(
  deviceId: peerId,
  friendlyName: 'Fi f755167e',
  pairedAtMs: 1,
  lastSeenMs: DateTime.now()
      .subtract(const Duration(hours: 3))
      .millisecondsSinceEpoch,
  lastSyncMs: DateTime.now()
      .subtract(const Duration(hours: 2, minutes: 5))
      .millisecondsSinceEpoch,
  revoked: false,
  connection: connection,
  failure: failure,
  failureKind: kind,
  lastKnownEndpoint: lastKnown,
);

FakeCollectionBridge bridgeWith(TrustedDeviceDto device) =>
    FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      )
      ..devices.add(device);

Future<void> openDevicesAt(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  Size size, {
  Widget? app,
  String devicesLabel = 'Devices',
  String collectionsLabel = 'Collections',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app ?? testApp(bridge));
  await pumpUntilFound(tester, find.text(collectionsLabel));
  await tester.tap(find.text(devicesLabel).last);
  await tester.pump();
  await tester.pump();
}

Finder problemBox() => find.byKey(const Key('device-problem-$peerId'));

void main() {
  testWidgets('a peer not found explains itself without raw detail', (
    tester,
  ) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(tester, bridge, const Size(1240, 900));
    await pumpUntilFound(tester, problemBox());
    expect(find.text('Not reachable'), findsOneWidget);
    expect(
      find.text('Not found on your network · Last synced 2 h ago'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: problemBox(),
        matching: find.textContaining('same Wi-Fi'),
      ),
      findsOneWidget,
    );
    for (final key in ['try-again', 'pair-again', 'connect-address']) {
      expect(find.byKey(Key('device-$key-$peerId')), findsOneWidget);
    }
    expect(find.text('no eligible endpoint'), findsNothing);
    expect(find.textContaining('NO_ELIGIBLE_ENDPOINT'), findsNothing);

    await tapVisible(tester, find.byKey(const Key('device-details-$peerId')));
    expect(find.text('no eligible endpoint'), findsOneWidget);
    expect(find.textContaining('NO_ELIGIBLE_ENDPOINT'), findsOneWidget);
  });

  testWidgets('Try again reconnects and Pair again opens pairing', (
    tester,
  ) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(tester, bridge, const Size(1240, 900));
    await pumpUntilFound(tester, problemBox());
    await tapVisible(tester, find.byKey(const Key('device-try-again-$peerId')));
    expect(bridge.reconnects, [peerId]);
    await tapVisible(
      tester,
      find.byKey(const Key('device-pair-again-$peerId')),
    );
    await pumpUntilFound(tester, find.byKey(const Key('pairing-card')));
  });

  testWidgets('a trust failure asks to pair again', (tester) async {
    final bridge = bridgeWith(
      unreachable(kind: ConnectionFailureKindDto.trust, failure: 'trust'),
    );
    await openDevicesAt(tester, bridge, const Size(1240, 900));
    await pumpUntilFound(tester, problemBox());
    expect(find.text("Can't verify"), findsOneWidget);
    expect(
      find.textContaining('It no longer recognizes this device'),
      findsOne,
    );
    expect(
      find.byKey(const Key('device-connect-address-$peerId')),
      findsNothing,
    );
  });

  testWidgets('a phone offers Connect by address under Details', (
    tester,
  ) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(tester, bridge, const Size(390, 844));
    await pumpUntilFound(tester, problemBox());
    expect(find.byKey(const Key('device-try-again-$peerId')), findsOneWidget);
    expect(find.byKey(const Key('device-pair-again-$peerId')), findsOneWidget);
    expect(
      find.byKey(const Key('device-connect-address-$peerId')),
      findsNothing,
    );
    await tapVisible(tester, find.byKey(const Key('device-details-$peerId')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('device-details-connect-address-$peerId')),
      findsOneWidget,
    );
  });

  testWidgets('the box goes away once the peer syncs', (tester) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(tester, bridge, const Size(1240, 900));
    await pumpUntilFound(tester, problemBox());
    bridge.devices[0] = unreachable(
      kind: null,
      failure: null,
      connection: PeerConnectionKindDto.synced,
    );
    bridge.devicesController.add(List.of(bridge.devices));
    await tester.pump();
    await tester.pump();
    expect(problemBox(), findsNothing);
    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets('a paused row reads Paused without guidance', (tester) async {
    final bridge =
        bridgeWith(
            unreachable(
              kind: null,
              failure: null,
              connection: PeerConnectionKindDto.paused,
            ),
          )
          ..preferences = const NetworkPreferencesDto(
            discoverable: true,
            syncEnabled: false,
          );
    await openDevicesAt(tester, bridge, const Size(1240, 900));
    await pumpUntilFound(tester, find.text('Fi f755167e'));
    expect(find.text('Paused'), findsWidgets);
    expect(problemBox(), findsNothing);
  });

  testWidgets('Spanish copy fits at 360', (tester) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(
      tester,
      bridge,
      const Size(360, 780),
      app: CollectionApp(
        bridge: bridge,
        initializeRust: () async {},
        dataDirProvider: () async => '/test',
        setPlatformForeground: (_) async {},
        uiPrefs: MemoryUiPrefsStore(
          const UiPrefs(appLanguage: AppLanguage.spanish),
        ),
      ),
      devicesLabel: 'Dispositivos',
      collectionsLabel: 'Colecciones',
    );
    await pumpUntilFound(tester, problemBox());
    expect(find.text('No disponible'), findsOneWidget);
    expect(find.text('Intentar de nuevo'), findsOneWidget);
    expect(find.text('Emparejar de nuevo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
