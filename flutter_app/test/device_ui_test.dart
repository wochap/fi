import 'dart:io';

import 'package:fi/controllers.dart';
import 'package:fi/device_details.dart';
import 'package:fi/pairing_card.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_widget_test.dart';
import 'fake_bridge.dart';

LogEventDto _event(int atMs, String event, [String? deviceId]) => LogEventDto(
  atMs: atMs,
  level: 'INFO',
  event: event,
  message: '$event message',
  fields: const [],
  deviceId: deviceId,
);

const _trusted = TrustedDeviceDto(
  deviceId: failedPeerId,
  friendlyName: 'Fi f755167e',
  pairedAtMs: 1,
  revoked: false,
  connection: PeerConnectionKindDto.synced,
  attemptEndpoint: '192.168.1.20:47380',
  lastAttemptMs: 1,
);

void main() {
  group('logCategory', () {
    /// Every event name `crates/app_core/src` emits, with its category. A new name makes this
    /// test fail until it is placed here, so no event lands in "device" by accident.
    const expected = {
      'bootstrap_recovery': LogCategory.device,
      'dataset_reset_completed': LogCategory.device,
      'dataset_reset_resumed': LogCategory.device,
      'dataset_reset_started': LogCategory.device,
      'discovery_advertise': LogCategory.address,
      'discovery_no_routable_address': LogCategory.address,
      'discovery_no_route': LogCategory.address,
      'discovery_secret_orphaned': LogCategory.address,
      'discovery_stop_failed': LogCategory.address,
      'network_preference_changed': LogCategory.device,
      'networking_deferred': LogCategory.device,
      'networking_resumed': LogCategory.device,
      'pairing_accept': LogCategory.pairing,
      'pairing_accept_error': LogCategory.pairing,
      'pairing_candidate_rejected': LogCategory.pairing,
      'pairing_commit_resume_failed': LogCategory.pairing,
      'pairing_commit_resumed': LogCategory.pairing,
      'pairing_dial': LogCategory.pairing,
      'pairing_fail': LogCategory.pairing,
      'pairing_journal_failure': LogCategory.pairing,
      'pairing_refuse': LogCategory.pairing,
      'pairing_released': LogCategory.pairing,
      'pairing_root_state': LogCategory.pairing,
      'pairing_state': LogCategory.pairing,
      'peer_address_observed': LogCategory.address,
      'peer_connection_state': LogCategory.peer,
      'peer_dial_failed': LogCategory.peer,
      'peer_endpoint_discovered': LogCategory.address,
      'sync_port_bound': LogCategory.peer,
      'tick': LogCategory.device,
      'trusted_device_activity_failed': LogCategory.device,
    };

    test('maps every event name emitted in app_core', () {
      final pattern = RegExp(r'event\s*=\s*"([a-z_]+)"');
      final emitted = <String>{
        for (final file in Directory(
          '../crates/app_core/src',
        ).listSync(recursive: true))
          if (file is File && file.path.endsWith('.rs'))
            for (final match in pattern.allMatches(file.readAsStringSync()))
              match.group(1)!,
      };
      expect(emitted, isNotEmpty);
      expect(emitted.difference(expected.keys.toSet()), isEmpty);
      for (final name in emitted) {
        expect(logCategory(_event(0, name)), expected[name], reason: name);
      }
    });

    test('an unknown or missing name is a device event', () {
      expect(logCategory(_event(0, 'something_new')), LogCategory.device);
      expect(
        logCategory(
          const LogEventDto(atMs: 0, level: 'INFO', message: '', fields: []),
        ),
        LogCategory.device,
      );
    });
  });

  test('the build label format', () {
    expect(
      buildLabel(
        const BuildInfoDto(version: '0.1.21', gitHash: 'a1b2c3d', dirty: false),
      ),
      'fi 0.1.21 · a1b2c3d',
    );
    expect(
      buildLabel(
        const BuildInfoDto(version: '0.1.21', gitHash: 'a1b2c3d', dirty: true),
      ),
      'fi 0.1.21 · a1b2c3d-dirty',
    );
    expect(
      buildLabel(
        const BuildInfoDto(version: '0.1.21', gitHash: '', dirty: false),
      ),
      'fi 0.1.21 · unknown',
    );
  });

  test('ids are grouped or shortened', () {
    const id =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    expect(groupedDeviceId(id), '01234567 89abcdef … 01234567 89abcdef');
    expect(shortDeviceId(id), '01234567…89abcdef');
  });

  group('pairing entry points', () {
    testWidgets('Start pairing swaps the empty state for the pairing card', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge();
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-devices')), findsOneWidget);
      await tester.tap(find.byKey(const Key('start-pairing')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('pairing-card')), findsOneWidget);
      expect(find.byKey(const Key('no-devices')), findsNothing);
    });

    testWidgets('with devices, Pair device heads the list', (tester) async {
      final bridge = FakeCollectionBridge()
        ..preferences = const NetworkPreferencesDto(
          discoverable: false,
          syncEnabled: true,
        )
        ..devices.add(_trusted);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.text('TRUSTED DEVICES · 1'), findsOneWidget);
      expect(find.byKey(const Key('no-devices')), findsNothing);
      expect(find.text('Pair device'), findsOneWidget);
      expect(
        find.byKey(const Key('discovery-off-note')),
        findsOneWidget,
        reason: 'discovery is off',
      );
      expect(find.text(PairingCard.discoveryOffNote), findsOneWidget);
      await tester.tap(find.text('Pair device'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('pairing-card')), findsOneWidget);
      expect(find.text('Fi f755167e'), findsOneWidget);
    });

    testWidgets('no discovery note while discoverable', (tester) async {
      final bridge = FakeCollectionBridge()..devices.add(_trusted);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discovery-off-note')), findsNothing);
    });

    testWidgets('a finished pairing shows a dismissible banner', (
      tester,
    ) async {
      final bridge = FakeCollectionBridge()..devices.add(_trusted);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      bridge.pairingController.add(
        pairingState(PairingKindDto.trusted, session: 's1', peer: failedPeerId),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Paired with Fi f755167e. The first sync starts automatically.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-card')), findsNothing);
      expect(find.text('Pair another'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dismiss-paired-banner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paired-banner')), findsNothing);
    });

    testWidgets('Pair another starts pairing again', (tester) async {
      final bridge = FakeCollectionBridge()..devices.add(_trusted);
      await openDevices(tester, bridge);
      await tester.pumpAndSettle();
      bridge.pairingController.add(
        pairingState(PairingKindDto.trusted, session: 's1', peer: failedPeerId),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pair another'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('paired-banner')), findsNothing);
      expect(find.byKey(const Key('pairing-card')), findsOneWidget);
    });
  });

  group('details', () {
    FakeCollectionBridge withLog() => FakeCollectionBridge()
      ..devices.add(_trusted)
      ..logs[failedPeerId] = [
        _event(1000, 'pairing_state', failedPeerId),
        _event(2000, 'peer_address_observed', failedPeerId),
        _event(3000, 'peer_connection_state', failedPeerId),
      ]
      ..logs[null] = [_event(1500, 'sync_port_bound')];

    testWidgets('the log is categorized, filtered and copied', (tester) async {
      tester.view.physicalSize = const Size(1240, 1400);
      final copied = mockClipboard(tester);
      final bridge = withLog();
      await openDevices(tester, bridge);
      tester.view.physicalSize = const Size(1240, 1400);
      await pumpUntilFound(tester, find.text('Fi f755167e'));
      await tapVisible(
        tester,
        find.byKey(const Key('device-details-$failedPeerId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connection log · 4 events'), findsOneWidget);
      final lines = find.byType(LogLineRow);
      expect(lines, findsNWidgets(4));
      for (final category in ['pairing', 'address', 'peer']) {
        expect(
          find.descendant(of: lines, matching: find.text(category)),
          findsWidgets,
          reason: category,
        );
      }
      // Oldest first: the local port line sits between the peer's first two.
      final tops = [
        for (final name in [
          'pairing_state pairing_state message',
          'sync_port_bound sync_port_bound message',
          'peer_address_observed peer_address_observed message',
          'peer_connection_state peer_connection_state message',
        ])
          tester.getTopLeft(find.text(name)).dy,
      ];
      expect(tops, [...tops]..sort());

      await tester.tap(find.text('Pairing').last);
      await tester.pumpAndSettle();
      expect(lines, findsOneWidget);
      expect(find.text('pairing_state pairing_state message'), findsOneWidget);

      await tester.tap(find.text('Peer').last);
      await tester.pumpAndSettle();
      expect(lines, findsNWidgets(3));
      expect(find.text('pairing_state pairing_state message'), findsNothing);

      await tapVisible(
        tester,
        find.byKey(const Key('device-copy-$failedPeerId')),
      );
      expect(bridge.diagnosticBlockCalls, [failedPeerId]);
      expect(copied, hasLength(1));
      expect(find.text('Log copied'), findsOneWidget);
    });

    testWidgets('the id copies in full', (tester) async {
      final copied = mockClipboard(tester);
      await openDevices(tester, withLog());
      await pumpUntilFound(tester, find.text('Fi f755167e'));
      await tapVisible(
        tester,
        find.byKey(const Key('device-details-$failedPeerId')),
      );
      await tapVisible(
        tester,
        find.byKey(const Key('device-copy-id-$failedPeerId')),
      );
      expect(copied, [failedPeerId]);
      expect(find.text('ID copied'), findsOneWidget);
    });

    testWidgets('a phone opens Details as a pushed screen', (tester) async {
      final bridge = withLog();
      await openDevices(tester, bridge);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const Key('device-details-$failedPeerId')),
      );
      await tester.pumpAndSettle();
      final screen = find.byKey(const Key('device-details-screen'));
      expect(screen, findsOneWidget);
      Finder inScreen(Finder finder) =>
          find.descendant(of: screen, matching: finder);
      expect(inScreen(find.text('Fi f755167e')), findsOneWidget);
      expect(inScreen(find.text('Synced')), findsWidgets);
      for (final label in ['Endpoint', 'Last attempt', 'Sync port', 'ID']) {
        expect(inScreen(find.text(label)), findsOneWidget, reason: label);
      }
      expect(inScreen(find.text('Connection log · 4 events')), findsOneWidget);
      expect(inScreen(find.byTooltip('Back')), findsOneWidget);
      expect(inScreen(find.byTooltip('Device actions')), findsOneWidget);
      final reconnect = find.byKey(const Key('device-reconnect-$failedPeerId'));
      await tester.ensureVisible(reconnect);
      expect(
        tester.getSize(reconnect).width,
        greaterThan(300),
        reason: 'full width',
      );
      expect(inScreen(find.text('Copy')), findsOneWidget);

      await tester.tap(inScreen(find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(screen, findsNothing);
    });
  });
}
