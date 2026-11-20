import 'dart:io';

import 'package:fi/src/rust/api/collections.dart' as rust_collections;
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/ui_prefs.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

/// Formats a byte count into a concise human-readable string (`412 KB`, `84.6 MB`, `1.2 GB`).
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return kb >= 10 ? '${kb.round()} KB' : '${kb.toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
  final gb = bytes / (1024 * 1024 * 1024);
  return '${gb.toStringAsFixed(1)} GB';
}

/// An image picked from the filesystem, gallery, or camera prior to ingestion into the Media Folder.
final class PickedImageSource {
  const PickedImageSource({
    required this.name,
    this.path,
    this.bytes,
  });

  final String name;
  final String? path;
  final Uint8List? bytes;
}

/// Platform and bridge operations for device-local media storage; injectable for deterministic tests.
abstract interface class MediaStorageService {
  Future<String?> pickFolder();

  Future<List<PickedImageSource>> pickImages({required bool allowMultiple});

  Future<PickedImageSource?> takePhoto();

  Future<bool> hasAllFilesAccess();

  Future<bool> openAndroidAllFilesSettings();

  Future<MediaFolderStatusDto> scanFolder(String folderPath);

  Future<ImageAttachmentDto> ingestFile(String sourcePath, String folderPath);

  Future<ImageAttachmentDto> ingestBytes(
    Uint8List bytes,
    String originalName,
    String folderPath,
  );

  bool fileExists(String folderPath, String relativePath);

  Future<void> openExternally(String fullPath);
}

/// Production implementation backed by `file_selector`, `permission_handler`, and `app_bridge`.
final class DefaultMediaStorageService implements MediaStorageService {
  const DefaultMediaStorageService();

  static const _platformChannel = MethodChannel('fi/platform');

  static const _imageTypeGroup = XTypeGroup(
    label: 'Images',
    extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif'],
    mimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'],
  );

  @override
  Future<String?> pickFolder() => getDirectoryPath();

  @override
  Future<List<PickedImageSource>> pickImages({
    required bool allowMultiple,
  }) async {
    final files = allowMultiple
        ? await openFiles(acceptedTypeGroups: const [_imageTypeGroup])
        : [?await openFile(acceptedTypeGroups: const [_imageTypeGroup])];
    final picked = <PickedImageSource>[];
    for (final file in files) {
      final path = file.path;
      if (path.isNotEmpty &&
          !path.startsWith('content://') &&
          File(path).existsSync()) {
        picked.add(PickedImageSource(name: file.name, path: path));
      } else {
        picked.add(
          PickedImageSource(name: file.name, bytes: await file.readAsBytes()),
        );
      }
    }
    return picked;
  }

  @override
  Future<PickedImageSource?> takePhoto() async {
    if (Platform.isAndroid) {
      final result = await _platformChannel.invokeMapMethod<String, dynamic>(
        'takePhoto',
      );
      if (result == null) return null;
      final path = result['path'] as String?;
      final name = result['name'] as String? ?? 'photo.jpg';
      if (path == null || path.isEmpty) return null;
      return PickedImageSource(name: name, path: path);
    }
    // Non-Android platforms without a dedicated camera intent fall back to the single-image picker.
    final list = await pickImages(allowMultiple: false);
    return list.firstOrNull;
  }

  @override
  Future<bool> hasAllFilesAccess() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openAndroidAllFilesSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MediaFolderStatusDto> scanFolder(String folderPath) =>
      rust_collections.scanMediaFolder(mediaFolder: folderPath);

  @override
  Future<ImageAttachmentDto> ingestFile(String sourcePath, String folderPath) =>
      rust_collections.ingestImageFile(
        sourcePath: sourcePath,
        mediaFolder: folderPath,
      );

  @override
  Future<ImageAttachmentDto> ingestBytes(
    Uint8List bytes,
    String originalName,
    String folderPath,
  ) => rust_collections.ingestImageBytes(
    bytes: bytes,
    originalName: originalName,
    mediaFolder: folderPath,
  );

  @override
  bool fileExists(String folderPath, String relativePath) {
    final file = File('$folderPath${Platform.pathSeparator}$relativePath');
    return file.existsSync();
  }

  @override
  Future<void> openExternally(String fullPath) async {
    if (Platform.isAndroid) {
      await _platformChannel.invokeMethod<void>('openExternalFile', {
        'path': fullPath,
      });
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [fullPath]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [fullPath]);
    } else if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', fullPath]);
    }
  }
}

/// Holds the active device-local Media Folder path and notifies listeners on change or rescan.
final class MediaStorageController extends ChangeNotifier {
  MediaStorageController({
    required this.prefsStore,
    this.service = const DefaultMediaStorageService(),
    String? initialPath,
  }) : _mediaFolderPath = initialPath;

  final UiPrefsStore prefsStore;
  final MediaStorageService service;

  String? _mediaFolderPath;
  int _revision = 0;

  String? get mediaFolderPath => _mediaFolderPath;
  int get revision => _revision;

  Future<void> load() async {
    final prefs = await prefsStore.load();
    if (_mediaFolderPath != prefs.mediaFolderPath) {
      _mediaFolderPath = prefs.mediaFolderPath;
      notifyListeners();
    }
  }

  Future<void> setMediaFolder(String? path) async {
    final normalized = path?.trim();
    final next = (normalized == null || normalized.isEmpty) ? null : normalized;
    _mediaFolderPath = next;
    _revision++;
    notifyListeners();
    await prefsStore.update((prefs) => prefs.copyWith(mediaFolderPath: next));
  }

  Future<String?> pickAndSetMediaFolder() async {
    final picked = await service.pickFolder();
    if (picked == null || picked.trim().isEmpty) return null;
    await setMediaFolder(picked);
    return _mediaFolderPath;
  }

  void bumpRevision() {
    _revision++;
    notifyListeners();
  }

  String? resolvePath(String relativePath) {
    final root = _mediaFolderPath;
    if (root == null || root.isEmpty) return null;
    return '$root${Platform.pathSeparator}$relativePath';
  }

  bool isPresent(String relativePath) {
    final root = _mediaFolderPath;
    if (root == null || root.isEmpty) return false;
    return service.fileExists(root, relativePath);
  }

  Future<ImageAttachmentDto> ingestPicked(PickedImageSource source) async {
    final root = _mediaFolderPath;
    if (root == null || root.isEmpty) {
      throw StateError('Media folder is not configured');
    }
    if (source.path case final path? when path.isNotEmpty) {
      return service.ingestFile(path, root);
    }
    final bytes = source.bytes;
    if (bytes == null) {
      throw StateError('Picked image has neither path nor bytes');
    }
    return service.ingestBytes(bytes, source.name, root);
  }
}

/// Provides [MediaStorageController] down the widget tree.
class MediaStorageScope extends InheritedNotifier<MediaStorageController> {
  const MediaStorageScope({
    required MediaStorageController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static MediaStorageController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaStorageScope>()?.notifier;

  static MediaStorageController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No MediaStorageScope found in context');
    return controller!;
  }
}
