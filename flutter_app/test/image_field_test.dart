import 'dart:io';
import 'dart:typed_data';

import 'package:fi/images/image_field.dart';
import 'package:fi/images/image_lightbox.dart';
import 'package:fi/images/image_view_cells.dart';
import 'package:fi/images/media_storage.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/app_theme.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/widgets/query_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1x1 valid transparent PNG bytes.
final _pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

FieldDefinitionDto _imagesField({
  bool required_ = false,
  bool allowMultiple = false,
  bool showThumbnails = true,
}) => FieldDefinitionDto(
  id: 'photos',
  name: 'Photos',
  fieldType: const FieldTypeDto(kind: FieldTypeKindDto.images),
  required_: required_,
  validation: const ValidationMetadataDto(),
  display: DisplayMetadataDto(
    multiline: false,
    slider: false,
    sliderStep: null,
    showThumbnails: showThumbnails,
  ),
  order: 0,
  deleted: false,
  enumOptions: const [],
  allowMultiple: allowMultiple,
);

Widget _wrap({
  required Widget child,
  required MediaStorageController storage,
  PlatformCapabilities capabilities = PlatformCapabilities.desktop,
}) => PlatformScope(
  capabilities: capabilities,
  child: MediaStorageScope(
    controller: storage,
    child: MaterialApp(
      theme: latteTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  ),
);

final class _TestMediaService implements MediaStorageService {
  _TestMediaService({
    this.pickedFolder,
    this.allFilesGranted = true,
  });

  String? pickedFolder;
  bool allFilesGranted;
  final List<String> openedExternally = [];

  @override
  Future<String?> pickFolder() async => pickedFolder;

  @override
  Future<List<PickedImageSource>> pickImages({
    required bool allowMultiple,
  }) async => const [];

  @override
  Future<PickedImageSource?> takePhoto() async => null;

  @override
  Future<bool> hasAllFilesAccess() async => allFilesGranted;

  @override
  Future<bool> openAndroidAllFilesSettings() async => true;

  @override
  Future<MediaFolderStatusDto> scanFolder(String folderPath) async =>
      const MediaFolderStatusDto(
        accessible: true,
        fileCount: 0,
        totalBytes: 0,
        missingReferencedCount: 0,
      );

  @override
  Future<ImageAttachmentDto> ingestFile(String sourcePath, String folderPath) async =>
      ImageAttachmentDto(
        relativePath: '0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.png',
        originalName: 'receipt.png',
        mimeType: 'image/png',
        sizeBytes: _pngBytes.length,
      );

  @override
  Future<ImageAttachmentDto> ingestBytes(
    Uint8List bytes,
    String originalName,
    String folderPath,
  ) async => ImageAttachmentDto(
    relativePath: '0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_$originalName',
    originalName: originalName,
    mimeType: 'image/png',
    sizeBytes: bytes.length,
  );

  @override
  bool fileExists(String folderPath, String relativePath) =>
      File('$folderPath${Platform.pathSeparator}$relativePath').existsSync();

  @override
  Future<void> openExternally(String fullPath) async {
    openedExternally.add(fullPath);
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fi_img_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File writePng(String name) {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(_pngBytes);
    return file;
  }

  const receipt = ImageAttachmentDto(
    relativePath: '0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.png',
    originalName: 'receipt.png',
    mimeType: 'image/png',
    sizeBytes: 421888,
  );
  const espresso = ImageAttachmentDto(
    relativePath: '0195f3a1-12b0-7a84-9c03-8e41d902b77c_espresso.png',
    originalName: 'espresso.png',
    mimeType: 'image/png',
    sizeBytes: 120000,
  );
  const third = ImageAttachmentDto(
    relativePath: '0195f3a2-12b0-7a84-9c03-8e41d902b77c_cake.png',
    originalName: 'cake.png',
    mimeType: 'image/png',
    sizeBytes: 98000,
  );

  group('ImageFieldInput record form states', () {
    testWidgets('empty desktop drop-zone and phone Take photo + Choose image', (
      tester,
    ) async {
      final service = _TestMediaService();
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: service,
        initialPath: tempDir.path,
      );

      // Desktop (>= 720px)
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: ImageFieldInput(
            field: _imagesField(),
            value: const FieldValueDto(kind: FieldValueKindDto.null_),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('images-empty-desktop')), findsOneWidget);
      expect(find.text('Choose image…'), findsOneWidget);

      // Phone (< 720px) + required error
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: ImageFieldInput(
            field: _imagesField(required_: true),
            value: const FieldValueDto(kind: FieldValueKindDto.null_),
            errorText: 'Required',
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('images-empty-phone')), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Choose image'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('inline folder primer on Android shows All files access row', (
      tester,
    ) async {
      final service = _TestMediaService(
        pickedFolder: tempDir.path,
        allFilesGranted: false,
      );
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: service,
        initialPath: null,
      );
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          capabilities: PlatformCapabilities.androidPhone,
          child: ImageFieldInput(
            field: _imagesField(),
            value: const FieldValueDto(kind: FieldValueKindDto.null_),
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('images-folder-primer')), findsOneWidget);
      expect(find.text('Choose a media folder first'), findsOneWidget);
      expect(find.byKey(const Key('images-primer-all-files')), findsOneWidget);
      expect(find.text('All files access · Needed'), findsOneWidget);
    });

    testWidgets(
      'single image populated card shows Tap to view, Replace, and optional Clear',
      (tester) async {
        writePng(receipt.relativePath);
        final storage = MediaStorageController(
          prefsStore: MemoryUiPrefsStore(),
          service: _TestMediaService(),
          initialPath: tempDir.path,
        );
        FieldValueDto? updated;

        await tester.pumpWidget(
          _wrap(
            storage: storage,
            child: ImageFieldInput(
              field: _imagesField(required_: false),
              value: const FieldValueDto(
                kind: FieldValueKindDto.images,
                imagesValue: [receipt],
              ),
              onChanged: (v) => updated = v,
            ),
          ),
        );

        expect(find.byKey(const Key('images-single-card')), findsOneWidget);
        expect(find.text('Tap to view'), findsOneWidget);
        expect(find.text('Replace'), findsOneWidget);
        expect(find.byKey(const Key('images-single-clear')), findsOneWidget);

        await tester.tap(find.byKey(const Key('images-single-clear')));
        await tester.pump();
        expect(updated?.kind, FieldValueKindDto.null_);

        // Required single field omits Clear button.
        await tester.pumpWidget(
          _wrap(
            storage: storage,
            child: ImageFieldInput(
              field: _imagesField(required_: true),
              value: const FieldValueDto(
                kind: FieldValueKindDto.images,
                imagesValue: [receipt],
              ),
              onChanged: (_) {},
            ),
          ),
        );
        expect(find.byKey(const Key('images-single-clear')), findsNothing);
      },
    );

    testWidgets('multi-image mixed local + missing header and compact rows', (
      tester,
    ) async {
      writePng(receipt.relativePath);
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: _TestMediaService(),
        initialPath: tempDir.path,
      );

      // Thumbnails on: 3-column grid + "1 of 2 on this device" header
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: ImageFieldInput(
            field: _imagesField(allowMultiple: true, showThumbnails: true),
            value: const FieldValueDto(
              kind: FieldValueKindDto.images,
              imagesValue: [receipt, espresso],
            ),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('images-multi-grid')), findsOneWidget);
      expect(find.text('1 of 2 on this device'), findsOneWidget);
      expect(find.byKey(const Key('images-add-tile')), findsOneWidget);

      // Thumbnails off: compact rows
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: ImageFieldInput(
            field: _imagesField(allowMultiple: true, showThumbnails: false),
            value: const FieldValueDto(
              kind: FieldValueKindDto.images,
              imagesValue: [receipt, espresso],
            ),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('images-compact-list')), findsOneWidget);
      expect(find.text('receipt.png'), findsOneWidget);
      expect(find.text('espresso.png'), findsOneWidget);
    });

    testWidgets(
      'missing placeholder transitions to thumbnail when Check again detects synced file',
      (tester) async {
        final storage = MediaStorageController(
          prefsStore: MemoryUiPrefsStore(),
          service: _TestMediaService(),
          initialPath: tempDir.path,
        );

        await tester.pumpWidget(
          _wrap(
            storage: storage,
            child: ImageFieldInput(
              field: _imagesField(),
              value: const FieldValueDto(
                kind: FieldValueKindDto.images,
                imagesValue: [receipt],
              ),
              onChanged: (_) {},
            ),
          ),
        );
        expect(find.byKey(const Key('images-missing-waiting')), findsOneWidget);
        expect(
          find.text('File not in folder yet · waiting for external sync'),
          findsOneWidget,
        );
        expect(find.text('Reference is kept when saving'), findsOneWidget);

        // External sync writes the file; user taps Check again.
        writePng(receipt.relativePath);
        await tester.tap(find.byKey(const Key('images-check-again')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('images-single-card')), findsOneWidget);
      },
    );

    testWidgets('missing placeholder when media folder is not set shows Set folder…', (
      tester,
    ) async {
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: _TestMediaService(),
        initialPath: null,
      );
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: ImageFieldInput(
            field: _imagesField(),
            value: const FieldValueDto(
              kind: FieldValueKindDto.images,
              imagesValue: [receipt],
            ),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.byKey(const Key('images-missing-no-folder')), findsOneWidget);
      expect(find.text('Set folder…'), findsOneWidget);
    });
  });

  group('View mode cells, Lightbox, and Filter operators', () {
    testWidgets('desktop table cell renders single, multi +1, missing, and empty', (
      tester,
    ) async {
      writePng(receipt.relativePath);
      writePng(espresso.relativePath);
      writePng(third.relativePath);
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: _TestMediaService(),
        initialPath: tempDir.path,
      );

      // Empty
      await tester.pumpWidget(
        _wrap(storage: storage, child: const ImagesTableCell(attachments: [])),
      );
      expect(find.text('—'), findsOneWidget);

      // Single present
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: const ImagesTableCell(attachments: [receipt]),
        ),
      );
      expect(find.byKey(const Key('images-table-cell-single')), findsOneWidget);
      expect(find.text('receipt.png'), findsOneWidget);

      // Multiple (3 files -> +1 badge & "3 files")
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: const ImagesTableCell(attachments: [receipt, espresso, third]),
        ),
      );
      expect(find.byKey(const Key('images-table-cell-multi')), findsOneWidget);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('3 files'), findsOneWidget);

      // Missing single
      const missingItem = ImageAttachmentDto(
        relativePath: '0195f3a9-7c4b-7d20-8a1e-4b92c8103f1a_gone.jpg',
        originalName: 'gone.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 500,
      );
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: const ImagesTableCell(attachments: [missingItem]),
        ),
      );
      expect(find.byKey(const Key('images-table-cell-missing')), findsOneWidget);
      expect(find.text('gone.jpg · missing'), findsOneWidget);
    });

    testWidgets('mobile card preview renders waiting for external sync placeholder', (
      tester,
    ) async {
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: _TestMediaService(),
        initialPath: tempDir.path,
      );
      await tester.pumpWidget(
        _wrap(
          storage: storage,
          child: const ImagesMobileCardPreview(
            attachments: [receipt],
            showThumbnails: true,
          ),
        ),
      );
      expect(find.byKey(const Key('images-mobile-card-missing')), findsOneWidget);
      expect(find.text('Waiting for external sync'), findsOneWidget);
    });

    testWidgets('ImageLightboxDialog navigates between images and opens externally', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 840);
      addTearDown(tester.view.reset);
      writePng(receipt.relativePath);
      writePng(espresso.relativePath);
      final service = _TestMediaService();
      final storage = MediaStorageController(
        prefsStore: MemoryUiPrefsStore(),
        service: service,
        initialPath: tempDir.path,
      );

      await tester.pumpWidget(
        PlatformScope(
          capabilities: PlatformCapabilities.desktop,
          child: MediaStorageScope(
            controller: storage,
            child: MaterialApp(
              theme: latteTheme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(
                body: ImageLightboxDialog(
                  attachments: [receipt, espresso],
                  initialIndex: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('receipt.png'), findsOneWidget);
      expect(find.textContaining('1 of 2'), findsOneWidget);
      expect(find.text(receipt.relativePath), findsOneWidget);

      // Tap Next image
      await tester.tap(find.byKey(const Key('lightbox-next')));
      await tester.pumpAndSettle();
      expect(find.text('espresso.png'), findsOneWidget);
      expect(find.textContaining('2 of 2'), findsOneWidget);

      // Tap Open externally
      await tester.tap(find.byKey(const Key('lightbox-open-external')));
      await tester.pump();
      expect(service.openedExternally, [
        '${tempDir.path}${Platform.pathSeparator}${espresso.relativePath}',
      ]);
    });

    test('view filter operators for Images are has file and is empty', () {
      final l = lookupAppLocalizations(const Locale('en'));
      final ops = ChoicesFilterOperator.offeredFor(FieldTypeKindDto.images);
      expect(ops, [
        ChoicesFilterOperator.isNotEmpty,
        ChoicesFilterOperator.isEmpty,
      ]);
      expect(
        ops.map((o) => o.viewLabel(l, kind: FieldTypeKindDto.images)).toList(),
        ['has file', 'is empty'],
      );
      expect(isChoicesFilterKind(FieldTypeKindDto.images), isTrue);
    });
  });
}
