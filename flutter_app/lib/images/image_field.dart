import 'dart:async';
import 'dart:io';

import 'package:fi/images/image_lightbox.dart';
import 'package:fi/images/media_storage.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Record form input for an `Images` field supporting single and multiple attachments,
/// thumbnail and compact-row modes, inline media folder onboarding, missing-on-disk external
/// sync placeholders, and in-app lightbox preview.
class ImageFieldInput extends StatefulWidget {
  const ImageFieldInput({
    required this.field,
    required this.value,
    required this.onChanged,
    this.errorText,
    super.key,
  });

  final FieldDefinitionDto field;
  final FieldValueDto value;
  final ValueChanged<FieldValueDto> onChanged;
  final String? errorText;

  @override
  State<ImageFieldInput> createState() => _ImageFieldInputState();
}

class _ImageFieldInputState extends State<ImageFieldInput> {
  bool? _allFilesGranted;
  bool _ingesting = false;
  String? _localError;

  List<ImageAttachmentDto> get _attachments =>
      widget.value.kind == FieldValueKindDto.images
      ? widget.value.imagesValue
      : const [];

  bool get _allowMultiple => widget.field.allowMultiple;
  bool get _showThumbnails => widget.field.display.showThumbnails;
  bool get _isRequired => widget.field.required_;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (PlatformScope.of(context).android && _allFilesGranted == null) {
      unawaited(_checkAndroidPermission());
    }
  }

  Future<void> _checkAndroidPermission() async {
    final storage = MediaStorageScope.maybeOf(context);
    final service = storage?.service ?? const DefaultMediaStorageService();
    bool granted;
    try {
      granted = await service.hasAllFilesAccess();
    } catch (_) {
      granted = false;
    }
    if (mounted) setState(() => _allFilesGranted = granted);
  }

  void _emit(List<ImageAttachmentDto> next) {
    if (next.isEmpty) {
      widget.onChanged(const FieldValueDto(kind: FieldValueKindDto.null_));
    } else {
      widget.onChanged(
        FieldValueDto(kind: FieldValueKindDto.images, imagesValue: next),
      );
    }
  }

  Future<void> _chooseFolderAndMaybePick({required bool pickAfter}) async {
    final storage = MediaStorageScope.maybeOf(context);
    if (storage == null) return;
    final picked = await storage.pickAndSetMediaFolder();
    if (picked != null && pickAfter && mounted) {
      await _pickImages(replaceSingle: !_allowMultiple);
    }
  }

  Future<void> _pickImages({bool replaceSingle = false}) async {
    final storage = MediaStorageScope.maybeOf(context);
    if (storage == null) return;
    if (storage.mediaFolderPath == null) {
      await _chooseFolderAndMaybePick(pickAfter: true);
      return;
    }
    setState(() {
      _ingesting = true;
      _localError = null;
    });
    try {
      final picked = await storage.service.pickImages(
        allowMultiple: _allowMultiple && !replaceSingle,
      );
      if (picked.isEmpty) return;
      final ingested = <ImageAttachmentDto>[];
      for (final item in picked) {
        ingested.add(await storage.ingestPicked(item));
      }
      if (!mounted) return;
      if (_allowMultiple && !replaceSingle) {
        _emit([..._attachments, ...ingested]);
      } else {
        _emit([ingested.first]);
      }
    } catch (error) {
      if (mounted) setState(() => _localError = error.toString());
    } finally {
      if (mounted) setState(() => _ingesting = false);
    }
  }

  Future<void> _takePhoto() async {
    final storage = MediaStorageScope.maybeOf(context);
    if (storage == null) return;
    if (storage.mediaFolderPath == null) {
      await _chooseFolderAndMaybePick(pickAfter: false);
      if (storage.mediaFolderPath == null || !mounted) return;
    }
    setState(() {
      _ingesting = true;
      _localError = null;
    });
    try {
      final photo = await storage.service.takePhoto();
      if (photo == null) return;
      final ingested = await storage.ingestPicked(photo);
      if (!mounted) return;
      if (_allowMultiple) {
        _emit([..._attachments, ingested]);
      } else {
        _emit([ingested]);
      }
    } catch (error) {
      if (mounted) setState(() => _localError = error.toString());
    } finally {
      if (mounted) setState(() => _ingesting = false);
    }
  }

  void _removeAt(int index) {
    final next = [..._attachments]..removeAt(index);
    _emit(next);
  }

  void _reorder(int oldIndex, int newIndex) {
    final next = [..._attachments];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _emit(next);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final storage = MediaStorageScope.maybeOf(context);
    final folder = storage?.mediaFolderPath;
    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final attachments = _attachments;
    final effectiveError = _localError ?? widget.errorText;

    // Mixed presence header when multiple images have both local and missing files.
    int presentCount = 0;
    for (final item in attachments) {
      if (storage?.isPresent(item.relativePath) ?? false) {
        presentCount++;
      }
    }
    final isMixed =
        attachments.length > 1 &&
        presentCount > 0 &&
        presentCount < attachments.length;

    Widget body;
    if (attachments.isEmpty) {
      if (folder == null) {
        body = _folderNotSetCard(context);
      } else {
        body = _emptyPicker(
          context,
          isPhone: isPhone,
          hasError: effectiveError != null,
        );
      }
    } else if (!_showThumbnails) {
      body = _compactRows(context, attachments, storage, folder);
    } else if (!_allowMultiple) {
      body = _singlePreview(context, attachments.first, storage, folder);
    } else {
      body = _multiGrid(context, attachments, storage, folder);
    }

    return Column(
      key: Key('images-field-${widget.field.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        if (isMixed)
          Text(
            l.imagesOnThisDeviceCount(presentCount, attachments.length),
            key: const Key('images-mixed-header'),
            style: TextStyle(fontSize: 12, color: nocturne.muted(.65)),
          ),
        body,
        if (effectiveError != null)
          Text(
            effectiveError,
            key: const Key('images-field-error'),
            style: TextStyle(fontSize: 12, color: nocturne.danger),
          ),
      ],
    );
  }

  Widget _folderNotSetCard(BuildContext context) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final isAndroid = PlatformScope.of(context).android;
    final needsAllFiles = isAndroid && _allFilesGranted != true;
    final storage = MediaStorageScope.maybeOf(context);

    return Container(
      key: const Key('images-folder-primer'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: nocturne.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.errorText != null ? nocturne.danger : nocturne.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(FiIcons.folderDashed, size: 18, color: nocturne.muted(.75)),
              Expanded(
                child: Text(
                  l.imagesFolderNotSetTitle,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Text(
            l.imagesFolderNotSetBody,
            style: TextStyle(fontSize: 12.5, color: nocturne.muted(.65)),
          ),
          if (needsAllFiles) ...[
            Divider(height: 1, color: nocturne.divider),
            Row(
              key: const Key('images-primer-all-files'),
              spacing: 8,
              children: [
                Icon(FiIcons.folderLock, size: 16, color: nocturne.warning),
                Expanded(
                  child: Text(
                    '${l.settingsMediaAllFilesAccess} · ${l.settingsMediaAllFilesNeeded}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: nocturne.warning,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                OutlinedButton(
                  key: const Key('images-primer-android-settings'),
                  onPressed: () async {
                    final service =
                        storage?.service ?? const DefaultMediaStorageService();
                    await service.openAndroidAllFilesSettings();
                    await _checkAndroidPermission();
                  },
                  child: Text(l.settingsAndroidSettings),
                ),
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('images-primer-choose-folder'),
              onPressed: () =>
                  unawaited(_chooseFolderAndMaybePick(pickAfter: true)),
              icon: const Icon(FiIcons.folderOpen, size: 16),
              label: Text(l.settingsMediaChooseFolder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyPicker(
    BuildContext context, {
    required bool isPhone,
    required bool hasError,
  }) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final borderColor = hasError ? nocturne.danger : nocturne.divider;

    if (isPhone) {
      return Row(
        key: const Key('images-empty-phone'),
        spacing: 8,
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('images-take-photo'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: borderColor),
                minimumSize: const Size(0, 44),
              ),
              onPressed: _ingesting ? null : () => unawaited(_takePhoto()),
              icon: const Icon(FiIcons.camera, size: 16),
              label: Text(l.imagesTakePhoto),
            ),
          ),
          Expanded(
            child: OutlinedButton.icon(
              key: const Key('images-choose-image'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: borderColor),
                minimumSize: const Size(0, 44),
              ),
              onPressed: _ingesting ? null : () => unawaited(_pickImages()),
              icon: const Icon(FiIcons.images, size: 16),
              label: Text(l.imagesChooseImage),
            ),
          ),
        ],
      );
    }

    return InkWell(
      key: const Key('images-empty-desktop'),
      borderRadius: BorderRadius.circular(8),
      onTap: _ingesting ? null : () => unawaited(_pickImages()),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: nocturne.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            Icon(FiIcons.images, size: 18, color: nocturne.muted(.7)),
            Text(
              l.imagesDropHint,
              style: TextStyle(fontSize: 13, color: nocturne.muted(.65)),
            ),
            Text(
              l.imagesChooseImageEllipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: nocturne.accentInk,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _singlePreview(
    BuildContext context,
    ImageAttachmentDto item,
    MediaStorageController? storage,
    String? folder,
  ) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final fullPath = storage?.resolvePath(item.relativePath);
    final isPresent =
        fullPath != null && (storage?.isPresent(item.relativePath) ?? false);

    if (!isPresent) {
      return _missingPlaceholder(context, item, folder: folder, storage: storage);
    }

    return Container(
      key: const Key('images-single-card'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: nocturne.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: nocturne.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            key: const Key('images-single-thumb'),
            onTap: () => unawaited(
              showImageLightbox(context, attachments: [item], initialIndex: 0),
            ),
            child: SizedBox(
              height: 124,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(
                    image: ResizeImage(FileImage(File(fullPath)), height: 248),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Center(
                      child: Icon(
                        FiIcons.fileImage,
                        size: 32,
                        color: nocturne.muted(.5),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        l.imagesTapToView,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (!_isRequired)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          key: const Key('images-single-clear'),
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(alpha: 0.6),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _removeAt(0),
                          icon: const Icon(FiIcons.close, size: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        item.originalName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${formatByteSize(item.sizeBytes)} · ${item.relativePath}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                          color: nocturne.muted(.6),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('images-single-replace'),
                  onPressed: _ingesting
                      ? null
                      : () => unawaited(_pickImages(replaceSingle: true)),
                  child: Text(l.imagesReplace),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _multiGrid(
    BuildContext context,
    List<ImageAttachmentDto> attachments,
    MediaStorageController? storage,
    String? folder,
  ) {
    final l = context.l10n;
    final nocturne = context.nocturne;

    return GridView.builder(
      key: const Key('images-multi-grid'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        mainAxisExtent: 108,
      ),
      itemCount: attachments.length + 1,
      itemBuilder: (context, index) {
        if (index == attachments.length) {
          return InkWell(
            key: const Key('images-add-tile'),
            borderRadius: BorderRadius.circular(8),
            onTap: _ingesting ? null : () => unawaited(_pickImages()),
            child: Container(
              decoration: BoxDecoration(
                color: nocturne.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: nocturne.divider),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 4,
                children: [
                  Icon(FiIcons.add, size: 18, color: nocturne.accentInk),
                  Text(
                    l.imagesAddImage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: nocturne.accentInk,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final item = attachments[index];
        final fullPath = storage?.resolvePath(item.relativePath);
        final isPresent =
            fullPath != null && (storage?.isPresent(item.relativePath) ?? false);

        return DragTarget<int>(
          onAcceptWithDetails: (details) {
            if (details.data != index) {
              final next = [...attachments];
              final moved = next.removeAt(details.data);
              next.insert(index, moved);
              _emit(next);
            }
          },
          builder: (context, candidateData, _) {
            final tile = Container(
              key: Key('images-grid-tile-$index'),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: nocturne.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: candidateData.isNotEmpty
                      ? nocturne.accent
                      : nocturne.divider,
                  width: candidateData.isNotEmpty ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 78,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (isPresent)
                          GestureDetector(
                            onTap: () => unawaited(
                              showImageLightbox(
                                context,
                                attachments: attachments,
                                initialIndex: index,
                              ),
                            ),
                            child: Image(
                              image: ResizeImage(
                                FileImage(File(fullPath)),
                                height: 156,
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Icon(
                                FiIcons.fileImage,
                                size: 22,
                                color: nocturne.muted(.5),
                              ),
                            ),
                          )
                        else
                          CustomPaint(
                            painter: StripedPlaceholderPainter(
                              color: nocturne.divider.withValues(alpha: .45),
                            ),
                            child: Center(
                              child: Icon(
                                folder == null
                                    ? FiIcons.folderDashed
                                    : FiIcons.cloudArrowDown,
                                size: 20,
                                color: nocturne.muted(.65),
                              ),
                            ),
                          ),
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Draggable<int>(
                            data: index,
                            feedback: Material(
                              color: Colors.transparent,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: nocturne.surface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: nocturne.accent),
                                ),
                                child: const Icon(FiIcons.images, size: 22),
                              ),
                            ),
                            child: Container(
                              key: Key('images-drag-handle-$index'),
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(
                                FiIcons.dragHandle,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: IconButton(
                              key: Key('images-remove-$index'),
                              padding: EdgeInsets.zero,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black.withValues(
                                  alpha: 0.6,
                                ),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () => _removeAt(index),
                              icon: const Icon(FiIcons.close, size: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Text(
                      item.originalName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: nocturne.muted(.8)),
                    ),
                  ),
                ],
              ),
            );
            return tile;
          },
        );
      },
    );
  }

  Widget _compactRows(
    BuildContext context,
    List<ImageAttachmentDto> attachments,
    MediaStorageController? storage,
    String? folder,
  ) {
    final l = context.l10n;
    final nocturne = context.nocturne;

    Widget buildRow(int index) {
      final item = attachments[index];
      final isPresent = storage?.isPresent(item.relativePath) ?? false;
      final canRemove = _allowMultiple || !_isRequired;
      return Container(
        key: ValueKey('compact-${item.relativePath}-$index'),
        height: 44,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: nocturne.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: nocturne.divider),
        ),
        child: Row(
          spacing: 8,
          children: [
            if (_allowMultiple)
              ReorderableDragStartListener(
                index: index,
                child: Icon(
                  FiIcons.dragHandle,
                  size: 16,
                  color: nocturne.muted(.55),
                ),
              ),
            Icon(
              isPresent ? FiIcons.fileImage : FiIcons.cloudArrowDown,
              size: 16,
              color: isPresent ? nocturne.accentInk : nocturne.warning,
            ),
            Expanded(
              child: InkWell(
                onTap: isPresent
                    ? () => unawaited(
                        showImageLightbox(
                          context,
                          attachments: attachments,
                          initialIndex: index,
                        ),
                      )
                    : null,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.originalName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      item.relativePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: nocturne.muted(.55),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Text(
              formatByteSize(item.sizeBytes),
              style: TextStyle(
                fontSize: 12,
                color: nocturne.muted(.65),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (canRemove)
              IconButton(
                key: Key('images-compact-remove-$index'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: () => _removeAt(index),
                icon: const Icon(FiIcons.close, size: 14),
              ),
          ],
        ),
      );
    }

    return Column(
      key: const Key('images-compact-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_allowMultiple)
          ReorderableListView.builder(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: attachments.length,
            onReorder: _reorder,
            itemBuilder: (_, index) => buildRow(index),
          )
        else
          buildRow(0),
        if (_allowMultiple)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('images-compact-add'),
              onPressed: _ingesting ? null : () => unawaited(_pickImages()),
              icon: const Icon(FiIcons.add, size: 15),
              label: Text(l.imagesAddImage),
            ),
          ),
      ],
    );
  }

  Widget _missingPlaceholder(
    BuildContext context,
    ImageAttachmentDto item, {
    required String? folder,
    required MediaStorageController? storage,
  }) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final noFolder = folder == null;

    return ClipRRect(
      key: Key(
        noFolder ? 'images-missing-no-folder' : 'images-missing-waiting',
      ),
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        painter: StripedPlaceholderPainter(
          color: nocturne.divider.withValues(alpha: .35),
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: nocturne.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Row(
                spacing: 8,
                children: [
                  Icon(
                    noFolder ? FiIcons.folderDashed : FiIcons.cloudArrowDown,
                    size: 18,
                    color: nocturne.muted(.75),
                  ),
                  Expanded(
                    child: Text(
                      '${item.originalName} · ${formatByteSize(item.sizeBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!_isRequired)
                    IconButton(
                      key: const Key('images-missing-clear'),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      onPressed: () => _removeAt(0),
                      icon: const Icon(FiIcons.close, size: 14),
                    ),
                ],
              ),
              Text(
                item.relativePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: nocturne.muted(.6),
                ),
              ),
              Text(
                noFolder
                    ? l.imagesMissingNoFolderBody
                    : l.imagesMissingWaitingTitle,
                style: TextStyle(fontSize: 12.5, color: nocturne.muted(.8)),
              ),
              if (!noFolder)
                Text(
                  l.imagesMissingReferenceKept,
                  style: TextStyle(fontSize: 12, color: nocturne.muted(.6)),
                ),
              const SizedBox(height: 2),
              if (noFolder)
                OutlinedButton.icon(
                  key: const Key('images-set-folder'),
                  onPressed: () =>
                      unawaited(_chooseFolderAndMaybePick(pickAfter: false)),
                  icon: const Icon(FiIcons.folderOpen, size: 15),
                  label: Text(l.imagesSetFolder),
                )
              else
                OutlinedButton.icon(
                  key: const Key('images-check-again'),
                  onPressed: () {
                    storage?.bumpRevision();
                    setState(() {});
                  },
                  icon: const Icon(FiIcons.refresh, size: 15),
                  label: Text(l.imagesCheckAgain),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Diagonal subtle stripe painter for missing-on-disk image placeholders.
class StripedPlaceholderPainter extends CustomPainter {
  const StripedPlaceholderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 6;
    const step = 16.0;
    for (double x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(StripedPlaceholderPainter oldDelegate) =>
      oldDelegate.color != color;
}
