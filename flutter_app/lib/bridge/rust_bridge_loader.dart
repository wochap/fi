import 'dart:io';

import 'package:fi/bridge/duration_grammar.dart';
import 'package:fi/src/rust/frb_generated.dart';
import 'package:fi/theme/inputs.dart';
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
  FiDurationInput.grammar = const RustDurationGrammar();
}

String linuxRustLibraryPath(String executablePath) => File(
  executablePath,
).parent.uri.resolve('lib/libapp_bridge.so').toFilePath();
