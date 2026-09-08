import 'package:fi/bridge/rust_bridge_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux bridge library is resolved relative to the executable', () {
    expect(linuxRustLibraryPath('/opt/fi/fi'), '/opt/fi/lib/libapp_bridge.so');
  });
}
