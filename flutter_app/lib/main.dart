import 'package:fi/app.dart';
import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/bridge/rust_bridge_loader.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    CollectionApp(
      bridge: RustCollectionBridge(),
      initializeRust: initializeRustBridge,
      dataDirProvider: () async =>
          (await getApplicationSupportDirectory()).path,
    ),
  );
}
