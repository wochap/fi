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

  /// Asks where to save raw [bytes], suggesting [suggestedName]. Returns the written filename or
  /// null when dismissed.
  Future<String?> saveBytes({
    required String suggestedName,
    required FileKind kind,
    required Uint8List bytes,
  });

  /// Asks for a `.json` or `.zip` import file and returns its filename and raw bytes, or null when
  /// dismissed.
  Future<({String name, Uint8List bytes})?> openJsonOrZip();
}

/// The portable formats, with what each platform dialog filters on.
enum FileKind {
  csv('CSV', 'csv', ['text/csv', 'text/comma-separated-values']),
  json('JSON', 'json', ['application/json']),
  zip('ZIP', 'zip', ['application/zip']);

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
  }) => saveBytes(
    suggestedName: suggestedName,
    kind: kind,
    bytes: Uint8List.fromList(utf8.encode(text)),
  );

  @override
  Future<String?> saveBytes({
    required String suggestedName,
    required FileKind kind,
    required Uint8List bytes,
  }) async {
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

  @override
  Future<({String name, Uint8List bytes})?> openJsonOrZip() async {
    const group = XTypeGroup(
      label: 'Fi collections (JSON or ZIP)',
      extensions: ['json', 'zip'],
      mimeTypes: ['application/json', 'application/zip'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return null;
    return (name: file.name, bytes: await file.readAsBytes());
  }
}
