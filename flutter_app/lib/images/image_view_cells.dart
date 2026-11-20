import 'dart:async';
import 'dart:io';

import 'package:fi/images/image_field.dart';
import 'package:fi/images/image_lightbox.dart';
import 'package:fi/images/media_storage.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// Desktop records table cell for an `Images` field:
/// - `—` when empty
/// - `28×28px` thumbnail + `original_name` for a single present image
/// - up to two stacked `28×28px` thumbnails + `+<N-2>` tag + `<N> files` for multiple images
/// - dashed `28×28px` `ph-file-dashed` badge + `<original_name> · missing` when missing on disk
class ImagesTableCell extends StatelessWidget {
  const ImagesTableCell({
    required this.attachments,
    super.key,
  });

  final List<ImageAttachmentDto> attachments;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final storage = MediaStorageScope.maybeOf(context);

    if (attachments.isEmpty) {
      return Text('—', style: TextStyle(color: nocturne.muted(.45)));
    }

    if (attachments.length == 1) {
      final item = attachments.first;
      final fullPath = storage?.resolvePath(item.relativePath);
      final isPresent =
          fullPath != null && (storage?.isPresent(item.relativePath) ?? false);
      if (!isPresent) {
        return Row(
          key: const Key('images-table-cell-missing'),
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: nocturne.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: nocturne.divider),
              ),
              child: Icon(
                FiIcons.fileDashed,
                size: 15,
                color: nocturne.muted(.65),
              ),
            ),
            Flexible(
              child: Text(
                l.imagesMissingBadge(item.originalName),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: nocturne.muted(.7)),
              ),
            ),
          ],
        );
      }

      return InkWell(
        key: const Key('images-table-cell-single'),
        borderRadius: BorderRadius.circular(4),
        onTap: () => unawaited(
          showImageLightbox(context, attachments: attachments, initialIndex: 0),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            _miniThumb(context, fullPath),
            Flexible(
              child: Text(
                item.originalName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    // Multiple attachments: up to two stacked 28×28px thumbnails + optional +<N-2> tag + "<N> files".
    final extra = attachments.length - 2;
    return InkWell(
      key: const Key('images-table-cell-multi'),
      borderRadius: BorderRadius.circular(4),
      onTap: () => unawaited(
        showImageLightbox(context, attachments: attachments, initialIndex: 0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          SizedBox(
            width: 44,
            height: 28,
            child: Stack(
              children: [
                for (var i = 0; i < 2; i++)
                  Positioned(
                    left: i * 14.0,
                    child: _stackedThumb(context, attachments[i], storage),
                  ),
              ],
            ),
          ),
          if (extra > 0)
            Container(
              key: const Key('images-table-extra-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: nocturne.neutralFill,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: nocturne.divider),
              ),
              child: Text(
                '+$extra',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: nocturne.muted(.85),
                ),
              ),
            ),
          Flexible(
            child: Text(
              l.imagesFileCount(attachments.length),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: nocturne.muted(.8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stackedThumb(
    BuildContext context,
    ImageAttachmentDto item,
    MediaStorageController? storage,
  ) {
    final nocturne = context.nocturne;
    final fullPath = storage?.resolvePath(item.relativePath);
    final isPresent =
        fullPath != null && (storage?.isPresent(item.relativePath) ?? false);
    if (!isPresent) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: nocturne.surface,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: nocturne.bg, width: 1.5),
        ),
        child: Icon(FiIcons.fileDashed, size: 13, color: nocturne.muted(.6)),
      );
    }
    return Container(
      width: 28,
      height: 28,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: nocturne.bg, width: 1.5),
      ),
      child: Image(
        image: ResizeImage(FileImage(File(fullPath)), width: 56),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            Icon(FiIcons.fileImage, size: 14, color: nocturne.muted(.5)),
      ),
    );
  }

  Widget _miniThumb(BuildContext context, String fullPath) {
    final nocturne = context.nocturne;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 28,
        height: 28,
        child: Image(
          image: ResizeImage(FileImage(File(fullPath)), width: 56),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Icon(FiIcons.fileImage, size: 14, color: nocturne.muted(.5)),
        ),
      ),
    );
  }
}

/// Mobile record card display for an `Images` field:
/// - up to two `64×64px` thumbnails beside metadata when `showThumbnails` is true and present
/// - `64×64px` striped `ph-cloud-arrow-down` placeholder with `Waiting for external sync` when
///   missing on disk
class ImagesMobileCardPreview extends StatelessWidget {
  const ImagesMobileCardPreview({
    required this.attachments,
    required this.showThumbnails,
    super.key,
  });

  final List<ImageAttachmentDto> attachments;
  final bool showThumbnails;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final nocturne = context.nocturne;
    final storage = MediaStorageScope.maybeOf(context);

    if (attachments.isEmpty) return const SizedBox.shrink();

    if (!showThumbnails) {
      return Text(
        attachments.length == 1
            ? '${attachments.first.originalName} · ${formatByteSize(attachments.first.sizeBytes)}'
            : l.imagesFileCount(attachments.length),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: nocturne.muted(.8)),
      );
    }

    final first = attachments.first;
    final firstPath = storage?.resolvePath(first.relativePath);
    final firstPresent =
        firstPath != null && (storage?.isPresent(first.relativePath) ?? false);

    if (attachments.length == 1 && !firstPresent) {
      return Row(
        key: const Key('images-mobile-card-missing'),
        spacing: 10,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 64,
              height: 64,
              child: CustomPaint(
                painter: StripedPlaceholderPainter(
                  color: nocturne.divider.withValues(alpha: .4),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: nocturne.divider),
                  ),
                  child: Icon(
                    FiIcons.cloudArrowDown,
                    size: 22,
                    color: nocturne.muted(.7),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  '${first.originalName} · ${formatByteSize(first.sizeBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  l.imagesWaitingForSync,
                  style: TextStyle(fontSize: 12, color: nocturne.muted(.65)),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final visible = attachments.take(2).toList();
    final extra = attachments.length - visible.length;

    return Row(
      key: const Key('images-mobile-card-thumbs'),
      spacing: 8,
      children: [
        for (var i = 0; i < visible.length; i++)
          _mobileThumb(context, visible[i], i, storage),
        if (extra > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: nocturne.neutralFill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: nocturne.divider),
            ),
            child: Text(
              '+$extra',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: nocturne.muted(.85),
              ),
            ),
          ),
        Expanded(
          child: Text(
            attachments.length == 1
                ? first.originalName
                : l.imagesFileCount(attachments.length),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: nocturne.muted(.8)),
          ),
        ),
      ],
    );
  }

  Widget _mobileThumb(
    BuildContext context,
    ImageAttachmentDto item,
    int index,
    MediaStorageController? storage,
  ) {
    final nocturne = context.nocturne;
    final fullPath = storage?.resolvePath(item.relativePath);
    final isPresent =
        fullPath != null && (storage?.isPresent(item.relativePath) ?? false);
    if (!isPresent) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 64,
          height: 64,
          child: CustomPaint(
            painter: StripedPlaceholderPainter(
              color: nocturne.divider.withValues(alpha: .4),
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: nocturne.divider),
              ),
              child: Icon(
                FiIcons.cloudArrowDown,
                size: 20,
                color: nocturne.muted(.7),
              ),
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => unawaited(
        showImageLightbox(
          context,
          attachments: attachments,
          initialIndex: index,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Image(
            image: ResizeImage(FileImage(File(fullPath)), width: 128),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                Icon(FiIcons.fileImage, size: 22, color: nocturne.muted(.5)),
          ),
        ),
      ),
    );
  }
}
