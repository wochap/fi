import 'dart:io';

import 'package:fi/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

Future<void> initializeRustBridge() async {
  if (RustLib.instance.initialized) return;

  await RustLib.init(
    externalLibrary: Platform.isLinux
        ? ExternalLibrary.open(
            linuxRustLibraryPath(Platform.resolvedExecutable),
          )
        : null,
  );
}

String linuxRustLibraryPath(String executablePath) => File(
  executablePath,
).parent.uri.resolve('lib/libapp_bridge.so').toFilePath();
