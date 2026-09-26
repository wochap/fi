import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native save and open dialogs for export and import. Only text moves through here; Rust owns
/// every format, so this layer never parses or rewrites content.
abstract interface class FileDialogs {
  /// Asks where to save [text], suggesting [suggestedName]. Writes only after the user confirms
  /// and returns the written file's name, or null when the dialog was dismissed (nothing written).
  Future<String?> saveText({
    required String suggestedName,
    required FileKind kind,
    required String text,
  });

  /// Asks for a file of [kind] and returns its text, or null when the dialog was dismissed.
  Future<String?> openText({required FileKind kind});
}

/// The two portable formats, with what each platform dialog filters on.
enum FileKind {
  csv('CSV', 'csv', ['text/csv', 'text/comma-separated-values']),
  json('JSON', 'json', ['application/json']);

  const FileKind(this.label, this.extension, this.mimeTypes);
  final String label;
  final String extension;
  final List<String> mimeTypes;

  XTypeGroup get _group =>
      XTypeGroup(label: label, extensions: [extension], mimeTypes: mimeTypes);
}

/// GTK dialogs on Linux and the Storage Access Framework on Android. `file_selector` has no save
/// dialog on Android, so saving there goes through `saveDocument` on the `fi/platform` channel.
final class PlatformFileDialogs implements FileDialogs {
  const PlatformFileDialogs();

  static const _platform = MethodChannel('fi/platform');

  @override
  Future<String?> saveText({
    required String suggestedName,
    required FileKind kind,
    required String text,
  }) async {
    final bytes = utf8.encode(text);
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _platform.invokeMethod<String>('saveDocument', {
        'name': suggestedName,
        'mimeType': kind.mimeTypes.first,
        'bytes': bytes,
      });
    }
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [kind._group],
    );
    if (location == null) return null;
    await XFile.fromData(
      bytes,
      mimeType: kind.mimeTypes.first,
    ).saveTo(location.path);
    return location.path.split('/').last;
  }

  @override
  Future<String?> openText({required FileKind kind}) async {
    final file = await openFile(acceptedTypeGroups: [kind._group]);
    return file?.readAsString();
  }
}
