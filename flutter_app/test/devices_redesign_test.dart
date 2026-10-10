import 'package:clock/clock.dart';
import 'package:fi/l10n/app_localizations.dart';
import 'package:fi/device_details.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_widget_test.dart';
import 'fake_bridge.dart';
import 'widget_test.dart' show useDarkPlatform;

TrustedDeviceDto _device(
  String id,
  String name,
  PeerConnectionKindDto connection, {
  bool revoked = false,
  int? lastSyncMs,
}) => TrustedDeviceDto(
  deviceId: id * 64,
  friendlyName: name,
  announcedName: name,
  pairedAtMs: 1,
  revoked: revoked,
  connection: connection,
  lastSyncMs: lastSyncMs,
);

Future<void> resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

/// Starts pairing and lets the stream event land.
Future<void> startPairing(WidgetTester tester) async {
  await tapVisible(tester, find.byKey(const Key('start-pairing')));
  await tester.pump();
}

Future<void> emit(
  WidgetTester tester,
  FakeCollectionBridge bridge,
  PairingStateDto state,
) async {
  bridge.pairingController.add(state);
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('Connected and Syncing are accent tags', (tester) async {
    const m = NocturneColors.mocha;
    for (final kind in [
      PeerConnectionKindDto.connected,
      PeerConnectionKindDto.syncing,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: nocturneTheme(m),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: DeviceStateTag(device: _device('a', 'Tablet', kind)),
          ),
        ),
      );
      final box =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(Tag),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(box.color, m.accentFill, reason: kind.name);
    }
  });

  testWidgets('sections read Trusted devices, This device, Connections', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.synced));
    await openDevices(tester, bridge);
    await tester.pumpAndSettle();
    final trusted = tester.getTopLeft(find.byKey(const Key('trusted-heading')));
    final local = tester.getTopLeft(find.text('THIS DEVICE'));
    final connections = tester.getTopLeft(find.text('CONNECTIONS'));
    expect(trusted.dy, lessThan(local.dy));
    expect(local.dy, lessThan(connections.dy));
  });

  testWidgets(
    'every tag has an icon; Synced success, Revoked danger, Offline neutral',
    (tester) async {
      useDarkPlatform(tester);
      final now = clock.now();
      final bridge = FakeCollectionBridge()
        ..devices.addAll([
          _device('a', 'Synced one', PeerConnectionKindDto.synced),
          _device('b', 'Offline one', PeerConnectionKindDto.offline),
          _device(
            'c',
            'Paused one',
            PeerConnectionKindDto.paused,
            lastSyncMs: now
                .subtract(const Duration(hours: 2))
                .millisecondsSinceEpoch,
          ),
          _device(
            'd',
            'Revoked one',
            PeerConnectionKindDto.offline,
            revoked: true,
          ),
        ]);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      final tags = tester
          .widgetList<Tag>(
            find.descendant(
              of: find.byKey(const Key('devices-page')),
              matching: find.byType(Tag),
            ),
          )
          .toList();
      expect(tags, hasLength(4));
      for (final tag in tags) {
        expect(tag.leading, isNotNull, reason: tag.text);
      }
      BoxDecoration boxOf(String text) =>
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byWidgetPredicate(
                            (w) => w is Tag && w.text == text,
                          ),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      const m = NocturneColors.mocha;
      expect(boxOf('Synced').color, m.success.withValues(alpha: .22));
      expect(boxOf('Offline').color, m.neutralFillStrong);
      final revoked = tags.last.text;
      expect((boxOf(revoked).border! as Border).top.color, m.danger);
      for (final tag in tags) {
        final label = find.descendant(
          of: find.byWidget(tag),
          matching: find.text(tag.text),
        );
        expect(tester.widget<Text>(label).style!.color, m.text);
      }
      expect(tags.map((tag) => tag.leading), [
        FiIcons.synced,
        FiIcons.offline,
        FiIcons.paused,
        FiIcons.blocked,
      ]);
      expect(
        find.text('Paused on this device · last synced 2 h ago'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a phone row is one tap target with a chevron and no menu', (
    tester,
  ) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.synced));
    await openDevices(tester, bridge);
    await resize(tester, const Size(390, 844));
    final row = find.byKey(Key('device-${'a' * 64}'));
    expect(
      find.descendant(of: row, matching: find.byType(PopupMenuButton<String>)),
      findsNothing,
    );
    expect(find.byKey(Key('device-chevron-${'a' * 64}')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(Key('device-details-${'a' * 64}'))).height,
      greaterThanOrEqualTo(64),
    );
    await tapVisible(tester, find.text('Tablet'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceDetailsScreen), findsOneWidget);
    expect(find.byTooltip('Device actions'), findsOneWidget);
  });

  testWidgets('the log filter shows at 390px', (tester) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.synced))
      ..logs['a' * 64] = [
        LogEventDto(
          atMs: 1,
          level: 'INFO',
          event: 'pairing_state',
          message: 'pairing',
          fields: const [],
          deviceId: 'a' * 64,
        ),
        LogEventDto(
          atMs: 2,
          level: 'INFO',
          event: 'peer_connection_state',
          message: 'peer',
          fields: const [],
          deviceId: 'a' * 64,
        ),
      ];
    await openDevices(tester, bridge);
    await resize(tester, const Size(390, 844));
    await tapVisible(tester, find.text('Tablet'));
    await tester.pumpAndSettle();
    final filter = find.byKey(Key('device-log-filter-${'a' * 64}'));
    expect(filter, findsOneWidget);
    expect(find.textContaining('pairing_state'), findsOneWidget);
    expect(find.textContaining('peer_connection_state'), findsOneWidget);
    await tapVisible(
      tester,
      find.descendant(of: filter, matching: find.text('Pairing')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('pairing_state'), findsOneWidget);
    expect(find.textContaining('peer_connection_state'), findsNothing);
  });

  group('status context', () {
    Finder sidebarLine() => find.byKey(const Key('sidebar-status-context'));
    String chipText(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('sync-status')),
            matching: find.byType(Text),
          ),
        )
        .data!;

    testWidgets('paused at 1240px and 390px', (tester) async {
      final bridge = FakeCollectionBridge()
        ..status = SyncStatusDto.paused
        ..preferences = const NetworkPreferencesDto(
          discoverable: true,
          syncEnabled: false,
        )
        ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.paused));
      await openDevices(tester, bridge);
      await resize(tester, const Size(1240, 900));
      expect(tester.widget<Text>(sidebarLine()).data, 'sync is off');
      expect(chipText(tester), 'Paused · sync with paired devices is off');

      await resize(tester, const Size(390, 844));
      expect(chipText(tester), 'Paused · sync is off');
    });

    testWidgets('pairing open in the sidebar at 1240px', (tester) async {
      final bridge = FakeCollectionBridge()..status = SyncStatusDto.searching;
      await openDevices(tester, bridge);
      await resize(tester, const Size(1240, 900));
      expect(tester.widget<Text>(sidebarLine()).data, isNot('pairing open'));
      await startPairing(tester);
      await tester.pump();
      expect(tester.widget<Text>(sidebarLine()).data, 'pairing open');
    });
  });

  testWidgets('Stop leaves pairing', (tester) async {
    final bridge = FakeCollectionBridge();
    await openDevices(tester, bridge);
    await startPairing(tester);
    await tester.pump();
    await tapVisible(tester, find.byKey(const Key('stop-pairing')));
    expect(bridge.pairingCalls, contains('stopPairing'));
  });

  for (final (failure, title, body) in [
    (
      PairingFailureKindDto.expired,
      'Pairing expired',
      "Pairing closed after 2 minutes. Start it again on both devices when they're nearby.",
    ),
    (
      PairingFailureKindDto.rejected,
      'Pairing rejected',
      'The code was rejected. Nothing was paired.',
    ),
  ]) {
    testWidgets('$title offers Start pairing', (tester) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);
      await startPairing(tester);
      await emit(
        tester,
        bridge,
        pairingState(PairingKindDto.failed, failure: failure),
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text(body), findsOneWidget);
      expect(find.byKey(const Key('pairing-sas')), findsNothing);
      await tapVisible(tester, find.byKey(const Key('pairing-start-again')));
      await tester.pump();
      expect(find.text('Pairing is open'), findsOneWidget);
    });
  }

  testWidgets('the code confirmation names a known peer', (tester) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.offline));
    await openDevices(tester, bridge);
    await tester.pumpAndSettle();
    await startPairing(tester);
    await emit(
      tester,
      bridge,
      pairingState(
        PairingKindDto.awaitingConfirmation,
        session: 'session',
        sas: '123456',
        peer: 'a' * 64,
      ),
    );
    expect(find.text('Device ID of Tablet'), findsOneWidget);
    expect(find.text('Pairing with Tablet'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('pairing-reject')));
    expect(bridge.rejectedSessions, ['session']);
  });

  testWidgets('rename reads Rename device / Name', (tester) async {
    final bridge = FakeCollectionBridge()
      ..devices.add(_device('a', 'Tablet', PeerConnectionKindDto.offline));
    await openDevices(tester, bridge);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename device'), findsOneWidget);
    expect(find.text('Only changes the name on this device'), findsOneWidget);
    expect(find.textContaining('Name'), findsWidgets);
    await tester.enterText(find.byKey(const Key('device-name')), 'Den');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Den'), findsOneWidget);
  });

  group('device names', () {
    TrustedDeviceDto nicknamed() => FakeCollectionBridge.withNames(
      _device('a', 'x', PeerConnectionKindDto.synced),
      nickname: 'Work laptop',
      announcedName: "Gean's ThinkPad",
    );

    testWidgets('naming this device in a dialog at 800px', (tester) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Rename this device'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('rename-local-device')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Name this device'), findsOneWidget);
      expect(
        find.text('Other devices see this name when pairing'),
        findsOneWidget,
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('local-name-field')),
          matching: find.byType(TextField),
        ),
        "  Gean's Pixel ",
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('local-name-save')));
      await tester.pumpAndSettle();
      expect(bridge.localNames, ["  Gean's Pixel "]);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('local-device-name'))).data,
        "Gean's Pixel",
      );
    });

    testWidgets('naming this device in a sheet at 390px', (tester) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);
      await resize(tester, const Size(390, 844));
      await tapVisible(tester, find.byKey(const Key('rename-local-device')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('rename-local-device'))).height,
        greaterThanOrEqualTo(44),
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('local-name-field')),
          matching: find.byType(TextField),
        ),
        'Pocket',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('local-name-save')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Pocket'), findsOneWidget);
    });

    testWidgets('a blank or overlong name cannot be saved', (tester) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('rename-local-device')));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byKey(const Key('local-name-field')),
        matching: find.byType(TextField),
      );
      FilledButton save() =>
          tester.widget<FilledButton>(find.byKey(const Key('local-name-save')));
      await tester.enterText(field, '   ');
      await tester.pump();
      expect(save().onPressed, isNull);
      await tester.enterText(field, 'é' * 33);
      await tester.pump();
      expect(save().onPressed, isNull);
      expect(
        find.text('Use a shorter name (at most 64 bytes).'),
        findsOneWidget,
      );
      expect(bridge.localNames, isEmpty);
    });

    testWidgets('no identity means no rename action', (tester) async {
      final bridge = FakeCollectionBridge()..localIdentity = null;
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('local-device-missing')), findsOneWidget);
      expect(find.byKey(const Key('rename-local-device')), findsNothing);
    });

    testWidgets('a nickname row shows the announced name under it', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()
        ..devices.addAll([
          nicknamed(),
          _device('b', 'Tablet', PeerConnectionKindDto.offline),
        ]);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.text('Work laptop'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(Key('device-announced-${'a' * 64}')))
            .data,
        "Gean's ThinkPad",
      );
      expect(find.byKey(Key('device-announced-${'b' * 64}')), findsNothing);
      expect(find.text('Tablet'), findsOneWidget);
    });

    testWidgets('clearing the nickname shows the announced name', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()..devices.add(nicknamed());
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Announces itself as Gean's ThinkPad. Clear the name to use that.",
        ),
        findsOneWidget,
      );
      final field = find.descendant(
        of: find.byKey(const Key('device-name')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).controller!.text, 'Work laptop');
      await tester.enterText(field, '');
      await tester.pump();
      await tester.tap(find.byKey(const Key('device-name-save')));
      await tester.pumpAndSettle();
      expect(bridge.devices.single.nickname, isNull);
      expect(find.text("Gean's ThinkPad"), findsOneWidget);
      expect(find.byKey(Key('device-announced-${'a' * 64}')), findsNothing);
    });

    testWidgets('an announced rename updates the row live', (tester) async {
      final bridge = FakeCollectionBridge()
        ..devices.add(
          _device('a', 'Fi aaaaaaaa', PeerConnectionKindDto.synced),
        );
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.text('Fi aaaaaaaa'), findsOneWidget);
      bridge.announceName('a' * 64, "Gean's ThinkPad");
      await tester.pump();
      await tester.pump();
      expect(find.text("Gean's ThinkPad"), findsOneWidget);
      expect(find.text('Fi aaaaaaaa'), findsNothing);
    });
  });
}
