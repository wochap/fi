import 'package:fi/app.dart';
import 'package:fi/bridge/finance_bridge.dart';
import 'package:fi/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    FinanceApp(
      bridge: RustFinanceBridge(),
      initializeRust: RustLib.init,
      dataDirProvider: () async =>
          (await getApplicationSupportDirectory()).path,
    ),
  );
}
