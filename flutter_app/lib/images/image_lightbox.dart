import 'dart:async';
import 'dart:io';

import 'package:fi/images/media_storage.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Opens the in-app Image Lightbox modal over a dark scrim for [attachments], starting at
/// [initialIndex].
Future<void> showImageLightbox(
  BuildContext context, {
  required List<ImageAttachmentDto> attachments,
  int initialIndex = 0,
}) {
  final storage = MediaStorageScope.maybeOf(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (dialogContext) => storage != null
        ? MediaStorageScope(
            controller: storage,
            child: ImageLightboxDialog(
              attachments: attachments,
              initialIndex: initialIndex.clamp(0, attachments.length - 1),
            ),
          )
        : ImageLightboxDialog(
            attachments: attachments,
            initialIndex: initialIndex.clamp(0, attachments.length - 1),
          ),
  );
}

/// Full-screen modal image viewer with previous/next navigation, thumbnail strip, dimensions,
/// relative filename inside the media folder, and external viewer handoff.
class ImageLightboxDialog extends StatefulWidget {
  const ImageLightboxDialog({
    required this.attachments,
    this.initialIndex = 0,
    super.key,
  });

  final List<ImageAttachmentDto> attachments;
  final int initialIndex;

  @override
  State<ImageLightboxDialog> createState() => _ImageLightboxDialogState();
}

class _ImageLightboxDialogState extends State<ImageLightboxDialog> {
  late int _index = widget.initialIndex;
  Size? _dimensions;
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;

  ImageAttachmentDto get _current => widget.attachments[_index];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveDimensions();
  }

  @override
  void dispose() {
    _detachStream();
    super.dispose();
  }

  void _detachStream() {
    if (_imageStream != null && _streamListener != null) {
      _imageStream!.removeListener(_streamListener!);
    }
    _imageStream = null;
    _streamListener = null;
  }

  void _resolveDimensions() {
    _detachStream();
    _dimensions = null;
    final storage = MediaStorageScope.maybeOf(context);
    final path = storage?.resolvePath(_current.relativePath);
    if (path == null || !storage!.isPresent(_current.relativePath)) return;
    final provider = FileImage(File(path));
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        if (mounted) {
          setState(() {
            _dimensions = Size(
              info.image.width.toDouble(),
              info.image.height.toDouble(),
            );
          });
        }
      },
      onError: (_, _) {},
    );
    _imageStream = stream;
    _streamListener = listener;
    stream.addListener(listener);
  }

  void _goTo(int nextIndex) {
    if (nextIndex < 0 || nextIndex >= widget.attachments.length) return;
    setState(() => _index = nextIndex);
    _resolveDimensions();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final storage = MediaStorageScope.maybeOf(context);
    final fullPath = storage?.resolvePath(_current.relativePath);
    final isPresent =
        fullPath != null && (storage?.isPresent(_current.relativePath) ?? false);
    final multiple = widget.attachments.length > 1;

    final metaParts = <String>[
      if (multiple)
        l.imagesLightboxIndex(_index + 1, widget.attachments.length),
      if (_current.sizeBytes > 0) formatByteSize(_current.sizeBytes),
      if (_dimensions case final dims?)
        '${dims.width.round()}×${dims.height.round()}',
    ];

    return Dialog(
      key: const Key('image-lightbox'),
      backgroundColor: nocturne.bg,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          _current.originalName,
                          key: const Key('lightbox-filename'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (metaParts.isNotEmpty)
                          Text(
                            metaParts.join(' · '),
                            key: const Key('lightbox-meta'),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: nocturne.muted(.65),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('lightbox-close'),
                    tooltip: l.commonClose,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(FiIcons.close, size: 18),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: nocturne.divider),
            // Main preview + prev/next arrows
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.35),
                      alignment: Alignment.center,
                      child: isPresent
                          ? InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 4.0,
                              child: Image.file(
                                File(fullPath),
                                key: ValueKey(_current.relativePath),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => Icon(
                                  FiIcons.fileImage,
                                  size: 48,
                                  color: nocturne.muted(.5),
                                ),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                Icon(
                                  FiIcons.cloudArrowDown,
                                  size: 36,
                                  color: nocturne.muted(.6),
                                ),
                                Text(
                                  l.imagesMissingWaitingTitle,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: nocturne.muted(.7),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  if (multiple && _index > 0)
                    Positioned(
                      left: 12,
                      child: IconButton.filledTonal(
                        key: const Key('lightbox-prev'),
                        tooltip: l.imagesLightboxPrevious,
                        onPressed: () => _goTo(_index - 1),
                        icon: const Icon(FiIcons.chevronLeft, size: 20),
                      ),
                    ),
                  if (multiple && _index < widget.attachments.length - 1)
                    Positioned(
                      right: 12,
                      child: IconButton.filledTonal(
                        key: const Key('lightbox-next'),
                        tooltip: l.imagesLightboxNext,
                        onPressed: () => _goTo(_index + 1),
                        icon: const Icon(FiIcons.chevronRight, size: 20),
                      ),
                    ),
                ],
              ),
            ),
            // Thumbnail strip when multiple
            if (multiple)
              Container(
                height: 68,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: nocturne.divider)),
                ),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.attachments.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, idx) {
                    final item = widget.attachments[idx];
                    final selected = idx == _index;
                    final itemPath = storage?.resolvePath(item.relativePath);
                    final itemPresent =
                        itemPath != null &&
                        (storage?.isPresent(item.relativePath) ?? false);
                    return GestureDetector(
                      key: Key('lightbox-thumb-$idx'),
                      onTap: () => _goTo(idx),
                      child: Container(
                        width: 52,
                        height: 52,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: selected
                                ? nocturne.accent
                                : nocturne.divider,
                            width: selected ? 2 : 1,
                          ),
                          color: nocturne.surface,
                        ),
                        child: itemPresent
                            ? Image(
                                image: ResizeImage(
                                  FileImage(File(itemPath)),
                                  width: 104,
                                ),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  FiIcons.fileImage,
                                  size: 18,
                                  color: nocturne.muted(.5),
                                ),
                              )
                            : Icon(
                                FiIcons.cloudArrowDown,
                                size: 18,
                                color: nocturne.muted(.5),
                              ),
                      ),
                    );
                  },
                ),
              ),
            // Footer
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: nocturne.divider)),
              ),
              child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(
                          l.imagesLightboxFileInFolder,
                          style: TextStyle(
                            fontSize: 11,
                            color: nocturne.muted(.55),
                          ),
                        ),
                        Text(
                          _current.relativePath,
                          key: const Key('lightbox-relative-path'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: nocturne.muted(.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isPresent)
                    OutlinedButton.icon(
                      key: const Key('lightbox-open-external'),
                      onPressed: () => unawaited(
                        (storage?.service ?? const DefaultMediaStorageService())
                            .openExternally(fullPath),
                      ),
                      icon: const Icon(FiIcons.openExternal, size: 15),
                      label: Text(l.imagesLightboxOpenExternally),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
