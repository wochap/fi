import 'dart:convert';
import 'dart:io';

/// The two orders of the collections list.
enum CollectionSort {
  /// Most recently edited first; collections never edited last.
  lastEdited,

  /// A–Z, ignoring case.
  name,
}

/// The interface language: the system's, or a fixed one.
enum AppLanguage {
  system('system'),
  english('en'),
  spanish('es');

  const AppLanguage(this.code);

  /// Stored form: `system`, `en` or `es`.
  final String code;

  /// Reads [code]; anything unknown is [system].
  static AppLanguage fromCode(Object? code) =>
      values.where((value) => value.code == code).firstOrNull ?? system;
}

/// The color theme: the system's light or dark setting, or a fixed one.
enum AppThemeMode {
  system,
  light,
  dark;

  /// Stored form: `system`, `light` or `dark`.
  String get code => name;

  /// Reads [code]; anything unknown is [system].
  static AppThemeMode fromCode(Object? code) =>
      values.where((value) => value.code == code).firstOrNull ?? system;
}

/// Device-local presentation choices. They never enter Rust or sync.
final class UiPrefs {
  const UiPrefs({
    this.collectionSort = CollectionSort.lastEdited,
    this.voiceTipDismissed = false,
    this.handsFree = false,
    this.appLanguage = AppLanguage.system,
    this.appTheme = AppThemeMode.system,
  });

  final CollectionSort collectionSort;

  /// The "Fill by voice" tip was dismissed on this device.
  final bool voiceTipDismissed;

  /// Hands-free spoken feedback after voice turns; off by default.
  final bool handsFree;

  /// The interface language; follows the system by default.
  final AppLanguage appLanguage;

  /// The color theme; follows the system by default.
  final AppThemeMode appTheme;

  UiPrefs copyWith({
    CollectionSort? collectionSort,
    bool? voiceTipDismissed,
    bool? handsFree,
    AppLanguage? appLanguage,
    AppThemeMode? appTheme,
  }) => UiPrefs(
    collectionSort: collectionSort ?? this.collectionSort,
    voiceTipDismissed: voiceTipDismissed ?? this.voiceTipDismissed,
    handsFree: handsFree ?? this.handsFree,
    appLanguage: appLanguage ?? this.appLanguage,
    appTheme: appTheme ?? this.appTheme,
  );

  Map<String, Object?> toJson() => {
    'collection_sort': collectionSort.name,
    'voice_tip_dismissed': voiceTipDismissed,
    'hands_free': handsFree,
    'app_language': appLanguage.code,
    'app_theme': appTheme.code,
  };

  /// Reads what [toJson] wrote; anything unreadable falls back to the defaults.
  static UiPrefs fromJson(Object? json) {
    if (json is! Map) return const UiPrefs();
    final sort = CollectionSort.values
        .where((value) => value.name == json['collection_sort'])
        .firstOrNull;
    return UiPrefs(
      collectionSort: sort ?? CollectionSort.lastEdited,
      voiceTipDismissed: json['voice_tip_dismissed'] == true,
      handsFree: json['hands_free'] == true,
      appLanguage: AppLanguage.fromCode(json['app_language']),
      appTheme: AppThemeMode.fromCode(json['app_theme']),
    );
  }
}

/// Where [UiPrefs] are kept.
abstract interface class UiPrefsStore {
  /// The stored preferences, or the defaults when none are stored or they can't be read.
  Future<UiPrefs> load();

  /// Stores [prefs]. Failures are swallowed: a lost preference is not worth an error.
  Future<void> save(UiPrefs prefs);

  /// Stores [change] applied to the stored preferences, so writers of different fields
  /// (the list order, voice) never undo each other.
  Future<void> update(UiPrefs Function(UiPrefs prefs) change);
}

/// Preferences held in memory for the life of the store; used in tests.
final class MemoryUiPrefsStore implements UiPrefsStore {
  MemoryUiPrefsStore([this.prefs = const UiPrefs()]);

  UiPrefs prefs;

  @override
  Future<UiPrefs> load() async => prefs;

  @override
  Future<void> save(UiPrefs prefs) async => this.prefs = prefs;

  @override
  Future<void> update(UiPrefs Function(UiPrefs prefs) change) async =>
      prefs = change(prefs);
}

/// `ui_prefs.json` in the directory [directory] resolves to (the app support directory).
final class FileUiPrefsStore implements UiPrefsStore {
  FileUiPrefsStore(this.directory);

  final Future<String> Function() directory;

  /// Updates run one at a time, each reading what the last one wrote.
  Future<void> _updates = Future.value();

  @override
  Future<void> update(UiPrefs Function(UiPrefs prefs) change) =>
      _updates = _updates.then((_) async => save(change(await load())));

  static const fileName = 'ui_prefs.json';

  Future<File> _file() async =>
      File('${await directory()}${Platform.pathSeparator}$fileName');

  @override
  Future<UiPrefs> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const UiPrefs();
      return UiPrefs.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const UiPrefs();
    }
  }

  @override
  Future<void> save(UiPrefs prefs) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(prefs.toJson()), flush: true);
    } catch (_) {
      // Device-local presentation only; the next start falls back to the default.
    }
  }
}
