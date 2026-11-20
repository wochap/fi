import 'dart:typed_data';

import 'package:fi/file_dialogs.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bridge.dart';
import 'widget_test.dart';

void main() {
  testWidgets(
    'Export collections dialog offers Include media files (.zip), warns on missing files, and shows .zip toast',
    (tester) async {
      final bridge = FakeCollectionBridge()
        ..bootstrap = const BootstrapDto(
          kind: BootstrapKindDto.ready,
          rootId: 'root',
        );
      final id = await bridge.createCollection('expenses', '');
      bridge.mediaSummaryOverride = const ReferencedMediaSummaryDto(
        totalReferenced: 38,
        presentCount: 36,
        presentBytes: 25375539, // ~24.2 MB
        missingCount: 2,
      );
      bridge.zipExportOverride = ZipExportDto(
        bytes: Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3]),
        records: 12,
        viewsWritten: 0,
        viewsOmitted: const [],
        mediaIncluded: 36,
        mediaMissing: 2,
      );
      final dialogs = FakeFileDialogs()..saveResult = 'expenses.zip';

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1240, 900);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        app(
          bridge,
          fileDialogs: dialogs,
          capabilities: PlatformCapabilities.desktop,
        ),
      );
      await pumpUntilFound(tester, find.text('expenses'));

      // Open Export collections dialog from the collections menu.
      await tester.tap(find.byKey(const Key('collections-transfer-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export selected…'));
      await tester.pumpAndSettle();

      // Check "expenses" collection.
      await tester.tap(find.byKey(Key('export-pick-$id')));
      await tester.pumpAndSettle();

      // Toggle appears with referenced file count & size.
      expect(
        find.byKey(const Key('export-include-media-zip')),
        findsOneWidget,
      );
      expect(find.text('Include media files (.zip)'), findsOneWidget);
      expect(find.text('38 referenced files · 24.2 MB'), findsOneWidget);

      // Enable Include media files (.zip) -> missing warning & "Export .zip" button.
      await tester.tap(find.byKey(const Key('export-include-media-zip')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('export-zip-missing-warning')),
        findsOneWidget,
      );
      expect(
        find.text(
          "2 referenced files are not in this device's media folder yet and will be skipped from the archive. Their paths stay in collections.json.",
        ),
        findsOneWidget,
      );
      expect(find.text('Export .zip'), findsOneWidget);

      // Confirm export -> writes zip bytes and displays missing-files toast.
      await tester.tap(find.byKey(const Key('confirm-export-selected')));
      await tester.pumpAndSettle();

      expect(dialogs.writtenBytes, hasLength(1));
      expect(dialogs.writtenBytes.single.$1, 'expenses.zip');
      expect(
        find.text(
          "Exported to expenses.zip · 2 missing media files weren't included.",
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Import JSON… accepts a .zip media bundle', (tester) async {
    final bridge = FakeCollectionBridge()
      ..bootstrap = const BootstrapDto(
        kind: BootstrapKindDto.ready,
        rootId: 'root',
      );
    final zipPayload = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 9, 8, 7]);
    final dialogs = FakeFileDialogs()
      ..openZipName = 'expenses.zip'
      ..openZipBytes = zipPayload;

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1240, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(
        bridge,
        fileDialogs: dialogs,
        capabilities: PlatformCapabilities.desktop,
      ),
    );
    await pumpUntilFound(tester, find.text('Collections'));

    await tester.tap(find.byKey(const Key('collections-transfer-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import JSON…'));
    await tester.pumpAndSettle();

    expect(dialogs.opened, [FileKind.zip]);
    expect(bridge.importedZipBytes, hasLength(1));
    expect(bridge.importedZipBytes.single, zipPayload);
  });
}
