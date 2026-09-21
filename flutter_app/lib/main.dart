import 'dart:io';

import 'package:fi/app.dart';
import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/bridge/rust_bridge_loader.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Redirects the application data directory, so two instances can run on one
/// host against separate datasets. Without it both instances resolve to the same
/// application-support directory and silently share one dataset, which makes
/// multi-device discovery untestable locally.
const dataDirOverrideVariable = 'FI_DATA_DIR';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    CollectionApp(
      bridge: RustCollectionBridge(),
      initializeRust: initializeRustBridge,
      dataDirProvider: resolveDataDir,
    ),
  );
}

Future<String> resolveDataDir() async {
  final override = dataDirOverride(
    Platform.environment,
    releaseMode: kReleaseMode,
  );
  return override ?? (await getApplicationSupportDirectory()).path;
}

/// Returns the override directory, or `null` to fall back to the platform
/// application-support directory. A release build must not be redirectable from
/// its environment, so the override is discarded there.
String? dataDirOverride(
  Map<String, String> environment, {
  required bool releaseMode,
}) {
  if (releaseMode) return null;
  final override = environment[dataDirOverrideVariable]?.trim();
  if (override == null || override.isEmpty) return null;
  return override;
}
