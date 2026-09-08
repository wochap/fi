import 'dart:io';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/src/rust/api/pairing.dart' as pairing;
import 'package:fi/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const platform = MethodChannel('fi/platform');
  final bridge = RustCollectionBridge();

  setUpAll(RustLib.init);

  testWidgets('foreground networking, pairing, lifecycle stop, and restart', (
    _,
  ) async {
    final support = await getApplicationSupportDirectory();
    final data = Directory('${support.path}/android-foreground-smoke-v1');
    if (data.existsSync()) {
      data.deleteSync(recursive: true);
    }

    await platform.invokeMethod<void>('setForeground', true);
    final firstSeed = await platform.invokeMethod<Uint8List>(
      'secureLoadOrCreateDeviceKey',
    );
    final repeatedSeed = await platform.invokeMethod<Uint8List>(
      'secureLoadOrCreateDeviceKey',
    );
    expect(firstSeed, isNotNull);
    expect(repeatedSeed, orderedEquals(firstSeed!));

    final initial = await bridge.initialize(data.path);
    expect(initial.kind, BootstrapKindDto.needsDecision);
    final ready = await bridge.createNewDataset();
    expect(ready.kind, BootstrapKindDto.ready);
    expect(ready.rootId, isNotNull);

    await bridge.setForeground(true);
    expect(await bridge.syncStatus(), SyncStatusDto.searching);

    await bridge.startPairing(30 * 1000);
    final pairingState = await pairing.pairingState();
    expect(pairingState.kind, PairingKindDto.discoverable);
    expect(pairingState.deadlineMs, isNotNull);
    await bridge.stopPairing();

    await bridge.setForeground(false);
    await platform.invokeMethod<void>('setForeground', false);
    expect(await bridge.syncStatus(), SyncStatusDto.offline);
    await bridge.shutdown();

    final restartSeed = await platform.invokeMethod<Uint8List>(
      'secureLoadOrCreateDeviceKey',
    );
    expect(restartSeed, orderedEquals(firstSeed));
    final restarted = await bridge.initialize(data.path);
    expect(restarted.kind, BootstrapKindDto.ready);
    expect(restarted.rootId, ready.rootId);
    await bridge.setForeground(true);
    await platform.invokeMethod<void>('setForeground', true);
    expect(await bridge.syncStatus(), SyncStatusDto.searching);

    await bridge.setForeground(false);
    await platform.invokeMethod<void>('setForeground', false);
    await bridge.shutdown();
  });
}
