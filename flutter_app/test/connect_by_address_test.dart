import 'dart:async';

import 'package:fi/app.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_widget_test.dart' show pumpUntilFound, tapVisible;
import 'fake_bridge.dart';
import 'peer_problem_widget_test.dart'
    show bridgeWith, openDevicesAt, peerId, unreachable;

Finder field() => find.byKey(const Key('connect-address-field'));
Finder connect() => find.byKey(const Key('connect-address-connect'));

Future<FakeCollectionBridge> openDialog(
  WidgetTester tester, {
  FakeCollectionBridge? bridge,
}) async {
  final fake = bridge ?? bridgeWith(unreachable());
  await openDevicesAt(tester, fake, const Size(1240, 900));
  final open = find.byKey(const Key('device-connect-address-$peerId'));
  await pumpUntilFound(tester, open);
  await tapVisible(tester, open);
  await tester.pumpAndSettle();
  return fake;
}

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(field()).controller!.text;

Future<void> submit(WidgetTester tester, {String? text}) async {
  if (text != null) await tester.enterText(field(), text);
  await tester.tap(connect());
  await tester.pump();
  await tester.pump();
}

String errorText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('connect-address-error'))).data!;

void main() {
  testWidgets('opens as a dialog prefilled with the last known address', (
    tester,
  ) async {
    await openDialog(tester);
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.text(
        'Reach Fi f755167e directly when it isn\'t found on the network. '
        'It must already be paired.',
      ),
      findsOneWidget,
    );
    expect(fieldText(tester), '192.168.0.165:47380');
  });

  testWidgets('connecting shows progress, then closes and confirms', (
    tester,
  ) async {
    final gate = Completer<void>();
    final bridge = bridgeWith(unreachable())..connectAddressGate = gate;
    await openDialog(tester, bridge: bridge);
    await tester.tap(connect());
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);
    expect(tester.widget<FilledButton>(connect()).onPressed, isNull);
    expect(tester.widget<TextField>(field()).enabled, isFalse);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Connected to Fi f755167e'), findsOneWidget);
    expect(bridge.connectAddressCalls, [(peerId, '192.168.0.165:47380')]);
  });

  testWidgets('an invalid address keeps the text', (tester) async {
    final bridge = bridgeWith(unreachable())
      ..connectOutcome = const ManualConnectOutcomeDto(
        kind: ManualConnectKindDto.invalidAddress,
      );
    await openDialog(tester, bridge: bridge);
    await submit(tester, text: '192.168.0');
    expect(
      errorText(tester),
      'Enter an IPv4 address like 192.168.0.165, optionally followed by :port.',
    );
    expect(fieldText(tester), '192.168.0');
    expect(find.byType(Dialog), findsOneWidget);
  });

  testWidgets('a different device at the address is named', (tester) async {
    final bridge = bridgeWith(unreachable())
      ..connectOutcome = const ManualConnectOutcomeDto(
        kind: ManualConnectKindDto.failed,
        failureKind: ConnectionFailureKindDto.trust,
        message: 'trust failed',
      );
    await openDialog(tester, bridge: bridge);
    await submit(tester, text: '192.168.0.20:47380');
    expect(
      errorText(tester),
      "The device at 192.168.0.20:47380 isn't Fi f755167e.",
    );
  });

  testWidgets('not local and no answer have their own lines', (tester) async {
    final bridge = bridgeWith(unreachable())
      ..connectOutcome = const ManualConnectOutcomeDto(
        kind: ManualConnectKindDto.notLocalNetwork,
      );
    await openDialog(tester, bridge: bridge);
    await submit(tester, text: '8.8.8.8');
    expect(
      errorText(tester),
      'Use an address on your local network or tailnet, like 192.168.x.x or 100.x.x.x.',
    );
    bridge.connectOutcome = const ManualConnectOutcomeDto(
      kind: ManualConnectKindDto.failed,
      failureKind: ConnectionFailureKindDto.route,
      message: 'route failed',
    );
    await submit(tester, text: '192.168.0.9');
    expect(
      errorText(tester),
      'No answer at 192.168.0.9. Check the address and that Fi is open on '
      'the other device.',
    );
  });

  testWidgets('a paused sync error has its own line', (tester) async {
    final bridge = bridgeWith(unreachable())
      ..connectAddressError = const BridgeError(
        kind: BridgeErrorKind.paused,
        issues: [],
        message: 'sync is paused',
        resetResolvable: false,
      );
    await openDialog(tester, bridge: bridge);
    await submit(tester);
    expect(
      errorText(tester),
      'Sync with paired devices is off. Turn it on to connect.',
    );
  });

  testWidgets('an empty field cannot connect', (tester) async {
    await openDialog(tester);
    await tester.enterText(field(), '');
    await tester.pump();
    expect(tester.widget<FilledButton>(connect()).onPressed, isNull);
  });

  testWidgets('a phone opens it as a bottom sheet from Details', (
    tester,
  ) async {
    final bridge = bridgeWith(unreachable());
    await openDevicesAt(tester, bridge, const Size(390, 844));
    await pumpUntilFound(
      tester,
      find.byKey(const Key('device-details-$peerId')),
    );
    await tapVisible(tester, find.byKey(const Key('device-details-$peerId')));
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const Key('device-details-connect-address-$peerId')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(field(), findsOneWidget);
  });

  testWidgets('Spanish text fits at 360', (tester) async {
    final bridge = bridgeWith(
      unreachable(kind: ConnectionFailureKindDto.route),
    );
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
    await tapVisible(tester, find.byKey(const Key('device-details-$peerId')));
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.byKey(const Key('device-details-connect-address-$peerId')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conectar por dirección'), findsOneWidget);
    expect(find.text('Dirección'), findsWidgets);
    expect(find.text('Conectar'), findsOneWidget);
    expect(fieldText(tester), '192.168.0.165:47380');
    expect(tester.takeException(), isNull);
  });
}
