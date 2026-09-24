import 'dart:async';

import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/foundation.dart';

final class BootstrapController extends ChangeNotifier {
  BootstrapController({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
  });

  final CollectionBridge bridge;
  final Future<void> Function() initializeRust;
  final Future<String> Function() dataDirProvider;
  BootstrapDto? state;
  String? fatalError;

  /// Whether [fatalError] is one a dataset reset resolves (unsupported
  /// schema, incomplete local store). False for transient failures such as a
  /// locked keystore, where retry is the right affordance.
  bool fatalResetResolvable = false;

  /// Whether [fatalError] is the desktop secure key store being locked, which
  /// the user fixes by unlocking the keyring and retrying in place.
  bool fatalSecureStoreLocked = false;

  /// Set when the core opened but peer networking could not start because the
  /// secure store was locked or unavailable. Local data stays usable.
  NetworkingDeferredDto? networkingDeferred;

  /// Why the last networking retry failed, if it did.
  String? networkingRetryError;
  bool retryingNetworking = false;
  bool loading = true;
  bool creating = false;
  bool resetting = false;
  StreamSubscription<BootstrapDto>? _subscription;

  Future<void> start() async {
    loading = true;
    _clearFatal();
    notifyListeners();
    try {
      await initializeRust();
      state = await bridge.initialize(await dataDirProvider());
      await _refreshNetworkingDeferred();
      await _listen();
    } catch (error) {
      _setFatal(error);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Deliberately abandons this device's local dataset. The bridge stops
  /// pairing, shuts the core down, resets, and reopens; the returned state
  /// replaces the current one and the lifecycle stream is re-subscribed
  /// against the reopened core. Works from a fatal-error state too.
  Future<void> resetDataset() async {
    resetting = true;
    loading = true;
    notifyListeners();
    try {
      state = await bridge.resetDataset();
      _clearFatal();
      await _listen();
    } catch (error) {
      _setFatal(error);
    } finally {
      resetting = false;
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _listen() async {
    // Not awaited: the stream is a broadcast source whose cancel may settle
    // only after the next frame, and nothing here depends on it.
    unawaited(_subscription?.cancel());
    _subscription = bridge.bootstrapEvents().listen(
      (value) {
        state = value;
        notifyListeners();
      },
      onError: (Object error) {
        _setFatal(error);
        notifyListeners();
      },
    );
  }

  void _setFatal(Object error) {
    fatalError = bridgeMessage(error);
    fatalResetResolvable = error is BridgeError && error.resetResolvable;
    fatalSecureStoreLocked =
        error is BridgeError && error.kind == BridgeErrorKind.secureStoreLocked;
  }

  void _clearFatal() {
    fatalError = null;
    fatalResetResolvable = false;
    fatalSecureStoreLocked = false;
  }

  Future<void> _refreshNetworkingDeferred() async {
    try {
      networkingDeferred = await bridge.networkingDeferred();
    } catch (_) {
      // A core that cannot answer at all is already reported as a fatal error.
      networkingDeferred = null;
    }
  }

  /// Re-runs the networking startup the secure store blocked. On success the
  /// locked-keyring condition clears without restarting the application; on
  /// failure the reason is kept so the explanation stays on screen.
  Future<void> retryNetworking() async {
    retryingNetworking = true;
    networkingRetryError = null;
    notifyListeners();
    try {
      await bridge.retryNetworking();
      networkingDeferred = null;
      _clearFatal();
      state = await bridge.bootstrapState();
      await _listen();
    } catch (error) {
      networkingRetryError = bridgeMessage(error);
      await _refreshNetworkingDeferred();
    } finally {
      retryingNetworking = false;
      notifyListeners();
    }
  }

  Future<void> createNewDataset() async {
    creating = true;
    notifyListeners();
    try {
      state = await bridge.createNewDataset();
    } catch (error) {
      fatalError = bridgeMessage(error);
    } finally {
      creating = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

/// The ID the field editor gives an option that has not been saved yet.
///
/// Rust mints the real ID on the first upsert; until then this key stands in for it, including
/// as the chosen default.
String tempOptionId(int n) => 'new-$n';

/// Whether [id] was made by [tempOptionId] rather than returned by Rust.
bool isTempOptionId(String id) => id.startsWith('new-');

/// What one field-editor save has already written, carried across a retry after a failure.
final class FieldSaveSession {
  /// The field's ID once it exists, so a retry updates it rather than adding a second field.
  String? fieldId;

  /// Real option IDs by the temp ID the editor used, for options already created.
  final Map<String, String> optionIds = {};
}

FieldDefinitionDto _fieldWith(
  FieldDefinitionDto field, {
  required String id,
  required FieldValueDto? defaultValue,
  required List<EnumOptionDto> enumOptions,
}) => FieldDefinitionDto(
  id: id,
  name: field.name,
  fieldType: field.fieldType,
  required_: field.required_,
  defaultValue: defaultValue,
  validation: field.validation,
  display: field.display,
  order: field.order,
  deleted: field.deleted,
  enumOptions: enumOptions,
);

/// What a collection holds, as shown before deleting it.
final class CollectionContents {
  const CollectionContents({
    required this.records,
    required this.widgets,
    required this.savedQueries,
  });

  final int records;
  final int widgets;
  final int savedQueries;
}

final class CollectionsController extends ChangeNotifier {
  CollectionsController(this.bridge);

  final CollectionBridge bridge;
  List<CollectionDto> collections = const [];
  CollectionSchemaDto? schema;
  List<RecordDto> records = const [];
  List<ComputedFieldDefinitionDto> computedFields = const [];
  List<QueryDefinitionDto> queryDefinitions = const [];
  List<WidgetDefinitionDto> widgetDefinitions = const [];
  List<WidgetEvaluationDto> widgetEvaluations = const [];
  List<WidgetDescriptorDto> widgetDescriptors = const [];
  String? selectedCollectionId;
  ProjectionDto projection = const ProjectionDto(
    kind: ProjectionKindDto.unavailable,
  );
  String? errorMessage;
  String? widgetErrorMessage;

  /// Records picked in selection mode, keyed by stable record ID so a refresh
  /// that reorders or drops rows never shifts the selection onto other records.
  final Set<String> selectedRecordIds = <String>{};
  bool _selectionRequested = false;
  bool loading = true;
  bool _disposed = false;
  StreamSubscription<DataChangedDto>? _dataSubscription;
  StreamSubscription<ProjectionDto>? _projectionSubscription;
  StreamSubscription<BridgeErrorEventDto>? _errorSubscription;

  Future<void> start() async {
    projection = await bridge.projectionState();
    _listenForInvalidations();
    _listenForProjection();
    _errorSubscription = bridge.errorEvents().listen((event) {
      errorMessage = event.message;
      notifyListeners();
    });
    widgetDescriptors = await bridge.listWidgetDescriptors();
    await refresh();
  }

  void _listenForInvalidations() {
    _dataSubscription = bridge.dataChangedEvents().listen(
      (_) => unawaited(refresh()),
      onError: (_) {
        if (!_disposed) {
          unawaited(_dataSubscription?.cancel());
          _listenForInvalidations();
          unawaited(refresh());
        }
      },
      onDone: () {
        if (!_disposed) {
          _listenForInvalidations();
          unawaited(refresh());
        }
      },
    );
  }

  void _listenForProjection() {
    _projectionSubscription = bridge.projectionEvents().listen(
      (value) {
        projection = value;
        notifyListeners();
      },
      onError: (_) {
        if (!_disposed) {
          unawaited(_projectionSubscription?.cancel());
          _listenForProjection();
        }
      },
    );
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      collections = await bridge.listCollections();
      if (selectedCollectionId case final id?) {
        schema = await bridge.getCollectionSchema(id);
        records = await bridge.listRecords(id);
        computedFields = await bridge.listComputedFields(id);
        queryDefinitions = await bridge.listQueryDefinitions(id);
        widgetDefinitions = await bridge.listWidgets(id);
      } else {
        schema = null;
        records = const [];
        computedFields = const [];
        queryDefinitions = const [];
        widgetDefinitions = const [];
        widgetEvaluations = const [];
      }
      _pruneSelection();
      errorMessage = null;
    } catch (error) {
      errorMessage = bridgeMessage(error);
    } finally {
      loading = false;
      notifyListeners();
    }
    // Evaluation is isolated so a widget-layer failure can never blank the record list above.
    await refreshWidgets();
  }

  /// Reevaluates the visible widgets. Duplicate query references are deduplicated by query ID and
  /// projection checkpoint inside a single bridge call, and nothing here is persisted.
  Future<void> refreshWidgets() async {
    final id = selectedCollectionId;
    if (id == null) return;
    try {
      widgetEvaluations = await bridge.evaluateWidgets(
        id,
        DateTime.now().millisecondsSinceEpoch,
      );
      widgetErrorMessage = null;
    } catch (error) {
      widgetErrorMessage = bridgeMessage(error);
    }
    if (!_disposed) notifyListeners();
  }

  /// The evaluation for one widget, or null while it is still loading.
  WidgetEvaluationDto? evaluationFor(String widgetId) {
    for (final evaluation in widgetEvaluations) {
      if (evaluation.widgetId == widgetId) return evaluation;
    }
    return null;
  }

  /// The descriptor for a widget type. An unrecognized type yields null, which renders as the
  /// unsupported placeholder rather than an error.
  WidgetDescriptorDto? descriptorFor(String widgetType) {
    for (final descriptor in widgetDescriptors) {
      if (descriptor.widgetType == widgetType) return descriptor;
    }
    return null;
  }

  Future<void> createWidget(WidgetDefinitionDto definition) async {
    await bridge.createWidget(definition);
    await refresh();
  }

  Future<void> updateWidget(WidgetUpdateDto update) async {
    await bridge.updateWidget(update);
    await refresh();
  }

  Future<void> removeWidget(String id) async {
    await bridge.removeWidget(selectedCollectionId!, id);
    await refresh();
  }

  Future<void> reorderWidgets(List<String> ids) async {
    await bridge.reorderWidgets(selectedCollectionId!, ids);
    await refresh();
  }

  Future<void> selectCollection(String? id) async {
    selectedCollectionId = id;
    await refresh();
  }

  Future<void> createComputedField(
    ComputedFieldDefinitionDto definition,
  ) async {
    await bridge.createComputedField(definition);
    await refresh();
  }

  /// Edits a computed field in place under its stable id, so queries and
  /// widgets that reference it resolve the new definition after the refresh.
  Future<void> updateComputedField(
    ComputedFieldDefinitionDto definition,
  ) async {
    await bridge.updateComputedField(definition);
    await refresh();
  }

  /// Creates a saved query and returns its new id, so a widget can reference it immediately.
  Future<String> createQueryDefinition(QueryDefinitionDto definition) async {
    final id = await bridge.createQueryDefinition(definition);
    await refresh();
    return id;
  }

  /// Edits a saved query in place. The id is preserved, so every widget referencing it evaluates
  /// the new definition after the refresh.
  Future<void> updateQueryDefinition(QueryDefinitionDto definition) async {
    await bridge.updateQueryDefinition(definition);
    await refresh();
  }

  Future<void> removeComputedField(String id) async {
    await bridge.removeComputedField(selectedCollectionId!, id);
    await refresh();
  }

  Future<void> removeQueryDefinition(String id) async {
    await bridge.removeQueryDefinition(selectedCollectionId!, id);
    await refresh();
  }

  Future<String> createCollection(
    String name, [
    String description = '',
  ]) async {
    final id = await bridge.createCollection(name, description);
    await refresh();
    return id;
  }

  Future<void> renameCollection(String id, String name) async {
    await bridge.renameCollection(id, name);
    await refresh();
  }

  /// Counts what deleting [collectionId] takes with it: its active records, widgets and saved
  /// queries. Reads run in parallel and are independent of the selected collection.
  Future<CollectionContents> contentsOf(String collectionId) async {
    final (records, widgets, queries) = await (
      bridge.listRecords(collectionId),
      bridge.listWidgets(collectionId),
      bridge.listQueryDefinitions(collectionId),
    ).wait;
    return CollectionContents(
      records: records.length,
      widgets: widgets.where((item) => !item.deleted).length,
      savedQueries: queries.where((item) => !item.deleted).length,
    );
  }

  Future<void> deleteCollection(String id) async {
    await bridge.deleteCollection(id);
    if (selectedCollectionId == id) selectedCollectionId = null;
    await refresh();
  }

  Future<String> addField(FieldDefinitionDto field) async {
    final id = await bridge.addField(selectedCollectionId!, field);
    await refresh();
    return id;
  }

  Future<void> updateField(FieldDefinitionDto field) async {
    await bridge.updateField(selectedCollectionId!, field);
    await refresh();
  }

  /// Saves a field and its Choice options as the field editor holds them, in one user action.
  ///
  /// [options] is the editor's list in display order; an option's `order` is taken from its
  /// position, and an ID made by [tempOptionId] marks an option that does not exist yet. The
  /// `enumOptions` on [field] are ignored: the stored field definition carries its options, so
  /// every field write here resubmits the stored ones and options change only through the
  /// per-option commands.
  ///
  /// A default pointing at a new option cannot be submitted before that option has a real ID, so
  /// it is held back and written by a second field update once the option exists. Options the
  /// user did not touch are not resubmitted.
  ///
  /// When a command fails after the field was written, the error is rethrown and [session]
  /// remembers what was already created, so saving again with the same session updates that
  /// field and those options instead of creating them twice.
  Future<String> saveFieldWithOptions(
    FieldDefinitionDto field,
    List<EnumOptionDto> options, {
    FieldSaveSession? session,
  }) async {
    final collectionId = selectedCollectionId!;
    final minted = session?.optionIds ?? <String, String>{};
    String resolve(String id) => minted[id] ?? id;
    final fieldId = field.id.isEmpty ? (session?.fieldId ?? '') : field.id;
    final choice = field.fieldType.kind == FieldTypeKindDto.enum_;
    final chosen = field.defaultValue;
    final pendingDefault =
        choice &&
            chosen?.kind == FieldValueKindDto.enum_ &&
            isTempOptionId(resolve(chosen?.textValue ?? ''))
        ? chosen!.textValue
        : null;
    final defaultValue = choice && chosen?.kind == FieldValueKindDto.enum_
        ? FieldValueDto(
            kind: FieldValueKindDto.enum_,
            textValue: resolve(chosen!.textValue!),
          )
        : chosen;
    final stored = schema?.fields
        .where((item) => item.id == fieldId)
        .firstOrNull;
    final storedOptions = stored?.enumOptions ?? const <EnumOptionDto>[];
    try {
      final submitted = _fieldWith(
        field,
        id: fieldId,
        defaultValue: pendingDefault == null ? defaultValue : null,
        enumOptions: storedOptions,
      );
      final String savedId;
      if (fieldId.isEmpty) {
        savedId = await bridge.addField(collectionId, submitted);
      } else {
        await bridge.updateField(collectionId, submitted);
        savedId = fieldId;
      }
      session?.fieldId = savedId;
      if (!choice) return savedId;

      final active = {
        for (final option in storedOptions)
          if (!option.deleted) option.id: option,
      };
      final kept = {for (final option in options) resolve(option.id)};
      for (final option in active.values) {
        if (!kept.contains(option.id)) {
          await bridge.removeEnumOption(collectionId, savedId, option.id);
        }
      }
      for (final (order, option) in options.indexed) {
        final id = resolve(option.id);
        if (isTempOptionId(id)) {
          minted[option.id] = await bridge.upsertEnumOption(
            collectionId,
            savedId,
            EnumOptionDto(
              id: '',
              label: option.label,
              order: order,
              deleted: false,
            ),
          );
        } else if (active[id] case final prior?
            when prior.label != option.label || prior.order != order) {
          await bridge.upsertEnumOption(
            collectionId,
            savedId,
            EnumOptionDto(
              id: id,
              label: option.label,
              order: order,
              deleted: false,
            ),
          );
        }
      }

      if (pendingDefault != null) {
        // The options just written live inside the stored definition, so the follow-up write
        // starts from what Rust now holds rather than from the list this call began with.
        final current = (await bridge.getCollectionSchema(
          collectionId,
        ))?.fields.where((item) => item.id == savedId).firstOrNull;
        await bridge.updateField(
          collectionId,
          _fieldWith(
            field,
            id: savedId,
            defaultValue: FieldValueDto(
              kind: FieldValueKindDto.enum_,
              textValue: resolve(pendingDefault),
            ),
            enumOptions: current?.enumOptions ?? const [],
          ),
        );
      }
      return savedId;
    } finally {
      await refresh();
    }
  }

  Future<void> removeField(String fieldId) async {
    await bridge.removeField(selectedCollectionId!, fieldId);
    await refresh();
  }

  Future<void> reorderFields(List<String> fieldIds) async {
    await bridge.reorderFields(selectedCollectionId!, fieldIds);
    await refresh();
  }

  Future<void> upsertEnumOption(String fieldId, EnumOptionDto option) async {
    await bridge.upsertEnumOption(selectedCollectionId!, fieldId, option);
    await refresh();
  }

  Future<void> removeEnumOption(String fieldId, String optionId) async {
    await bridge.removeEnumOption(selectedCollectionId!, fieldId, optionId);
    await refresh();
  }

  Future<void> createRecord(List<RecordValueDto> values) async {
    await bridge.createRecord(selectedCollectionId!, values);
    await refresh();
  }

  Future<void> updateRecord(
    String recordId,
    List<RecordValueDto> values,
  ) async {
    for (final value in values) {
      await bridge.updateRecordField(
        recordId,
        selectedCollectionId!,
        value.fieldId,
        value.value,
      );
    }
    await refresh();
  }

  /// Dry-run record validation in Rust with the same rules as create (no [recordId]) or update.
  /// Commits nothing; returns every issue, empty when the draft is valid.
  Future<List<BridgeIssueDto>> validateRecordDraft(
    List<RecordValueDto> values, {
    String? recordId,
  }) => bridge.validateRecordDraft(selectedCollectionId!, recordId, values);

  Future<void> deleteRecord(String id) async {
    await bridge.deleteRecord(id, selectedCollectionId!);
    await refresh();
  }

  /// True while the screen is in selection mode: either a record is selected,
  /// or the header's Select action opened an empty selection.
  bool get selecting => _selectionRequested || selectedRecordIds.isNotEmpty;

  /// Opens selection mode with nothing selected yet, for the header action.
  void startSelection() {
    if (_selectionRequested) return;
    _selectionRequested = true;
    notifyListeners();
  }

  void toggleSelected(String recordId) {
    if (!selectedRecordIds.remove(recordId)) selectedRecordIds.add(recordId);
    notifyListeners();
  }

  void clearSelection() {
    if (!selecting) return;
    _selectionRequested = false;
    selectedRecordIds.clear();
    notifyListeners();
  }

  /// Drops selected IDs that are no longer in the projected list, which is how
  /// a record deleted on another device leaves the selection.
  void _pruneSelection() {
    if (selectedRecordIds.isEmpty) return;
    final present = {for (final record in records) record.id};
    selectedRecordIds.removeWhere((id) => !present.contains(id));
  }

  /// Deletes the selection in one atomic batch and returns how many records the
  /// batch carried. On failure the selection is pruned, not cleared, so the
  /// user can retry from what is still there.
  Future<int> deleteSelected() async {
    final ids = selectedRecordIds.toList(growable: false);
    try {
      await bridge.deleteRecords(ids, selectedCollectionId!);
    } catch (failure) {
      await _reportBatchFailure(failure);
      rethrow;
    }
    await refresh();
    clearSelection();
    return ids.length;
  }

  /// A rejected batch wrote nothing, so the list is refreshed only to prune the
  /// selection; the typed error then replaces the message that refresh cleared.
  Future<void> _reportBatchFailure(Object failure) async {
    await refresh();
    errorMessage = bridgeMessage(failure);
    notifyListeners();
  }

  /// Sets one field to one value across the selection in one atomic batch and
  /// returns how many records the batch carried.
  Future<int> setFieldOnSelected(String fieldId, FieldValueDto value) async {
    final ids = selectedRecordIds.toList(growable: false);
    try {
      await bridge.setRecordsField(ids, selectedCollectionId!, fieldId, value);
    } catch (failure) {
      await _reportBatchFailure(failure);
      rethrow;
    }
    await refresh();
    clearSelection();
    return ids.length;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_dataSubscription?.cancel());
    unawaited(_projectionSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    super.dispose();
  }
}

final class DevicesController extends ChangeNotifier {
  DevicesController(this.bridge);

  final CollectionBridge bridge;
  PairingStateDto pairing = const PairingStateDto(
    kind: PairingKindDto.idle,
    localConfirmed: false,
    remoteConfirmed: false,
    alreadyPaired: false,
  );

  /// Every candidate Rust reports, including ones that resolve to devices
  /// already paired with. [candidates] is the selectable subset.
  List<PairingCandidateDto> discoveredCandidates = const [];
  List<TrustedDeviceDto> devices = const [];
  SyncStatusDto syncStatus = SyncStatusDto.offline;
  String? errorMessage;

  /// Set when a revocation committed but the follow-up discovery-secret
  /// rotation failed; cleared by a successful [retryRotation].
  String? rotationError;
  bool busy = false;
  bool _disposed = false;
  Timer? _clock;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Bumped by [restart] and [dispose]; a stream that ends after its
  /// generation moved on belongs to a subscription set that was torn down
  /// deliberately and must not reopen itself.
  int _generation = 0;

  Future<void> start() async {
    _subscribe(bridge.pairingStateEvents, _setPairing);
    _subscribe(bridge.pairingCandidateEvents, (value) {
      discoveredCandidates = value;
      notifyListeners();
    });
    _subscribe(bridge.connectionStateEvents, (value) {
      devices = value;
      notifyListeners();
    }, refresh: refreshDevices);
    _subscribe(bridge.syncStatusEvents, (value) {
      syncStatus = value;
      notifyListeners();
    }, refresh: _refreshSyncStatus);
    await refreshDevices();
    await _refreshSyncStatus();
  }

  /// Subscribes to [open] and keeps the subscription alive for the life of
  /// this controller: a bridge stream that ends without being cancelled here
  /// is reopened and the query it backs is refreshed. This controller is
  /// owned at application scope, so no screen remount will resubscribe it.
  void _subscribe<T>(
    Stream<T> Function() open,
    void Function(T value) onData, {
    Future<void> Function()? refresh,
  }) {
    final generation = _generation;
    late final StreamSubscription<T> subscription;
    subscription = open().listen(
      onData,
      onError: _setError,
      onDone: () {
        _subscriptions.remove(subscription);
        if (_disposed || generation != _generation) return;
        unawaited(
          _reopen(open, onData, refresh: refresh, generation: generation),
        );
      },
    );
    _subscriptions.add(subscription);
  }

  Future<void> _reopen<T>(
    Stream<T> Function() open,
    void Function(T value) onData, {
    required Future<void> Function()? refresh,
    required int generation,
  }) async {
    await Future<void>.delayed(_reopenDelay);
    if (_disposed || generation != _generation) return;
    _subscribe(open, onData, refresh: refresh);
    if (refresh != null) await refresh();
  }

  /// Pause before reopening a stream that ended unexpectedly, so a source
  /// that closes on every open cannot spin the controller.
  static const _reopenDelay = Duration(seconds: 1);

  Future<void> _refreshSyncStatus() async {
    try {
      syncStatus = await bridge.syncStatus();
    } catch (error) {
      _setError(error);
    }
    if (!_disposed) notifyListeners();
  }

  /// Drops every stream and cached value and starts again, so the controller
  /// observes the core that replaced the one it was subscribed to (after a
  /// dataset reset). Safe to call whether or not [start] ran before.
  Future<void> restart() async {
    _generation++;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _clock?.cancel();
    pairing = const PairingStateDto(
      kind: PairingKindDto.idle,
      localConfirmed: false,
      remoteConfirmed: false,
      alreadyPaired: false,
    );
    discoveredCandidates = const [];
    devices = const [];
    syncStatus = SyncStatusDto.offline;
    errorMessage = null;
    rotationError = null;
    busy = false;
    await start();
  }

  /// Candidates the user can select. A candidate Rust reports as already
  /// paired is a device we are already trusted with, so offering it would only
  /// re-run a commit the user does not need.
  List<PairingCandidateDto> get candidates => discoveredCandidates
      .where((candidate) => !candidate.alreadyPaired)
      .toList(growable: false);

  /// True when every discovered candidate was filtered out, which the list
  /// explains rather than showing an empty search.
  bool get allCandidatesAlreadyPaired =>
      discoveredCandidates.isNotEmpty && candidates.isEmpty;

  /// Re-runs the networking startup a locked secure store blocked, then
  /// reopens the pairing window so the user continues where they left off.
  Future<void> retryAfterUnlock() => _run(() async {
    await bridge.retryNetworking();
    await bridge.startPairing(120000);
  });

  /// Friendly name of the peer in the current pairing session, resolved from
  /// the trusted-device list; null when no peer is known yet.
  String? get peerName {
    final peerId = pairing.peerDeviceId;
    if (peerId == null) return null;
    for (final device in devices) {
      if (device.deviceId == peerId) return device.friendlyName;
    }
    return null;
  }

  int get remainingSeconds {
    final deadline = pairing.deadlineMs;
    if (deadline == null) return 0;
    final remaining = deadline - DateTime.now().millisecondsSinceEpoch;
    return remaining <= 0 ? 0 : (remaining / 1000).ceil();
  }

  Future<void> beginPairing({int durationMs = 120000}) =>
      _run(() => bridge.startPairing(durationMs));
  Future<void> stopPairing() => _run(bridge.stopPairing);
  Future<void> selectCandidate(PairingCandidateDto candidate) =>
      _run(() => bridge.connectPairingCandidate(candidate));
  Future<void> confirm() => _run(() async {
    final session = pairing.sessionId;
    if (session == null) return;
    await bridge.confirmPairing(session);
  });
  Future<void> reject() => _run(() => bridge.rejectPairing(pairing.sessionId));

  Future<void> rename(TrustedDeviceDto device, String name) async {
    await _run(() => bridge.renameTrustedDevice(device.deviceId, name));
    await refreshDevices();
  }

  Future<void> revoke(TrustedDeviceDto device) async {
    await _run(() async {
      final outcome = await bridge.revokeTrustedDevice(
        device.deviceId,
        DateTime.now().millisecondsSinceEpoch,
      );
      rotationError = outcome.rotationError;
    });
    await refreshDevices();
  }

  Future<void> retryRotation() async {
    await _run(() async {
      await bridge.rotateDiscoverySecret(DateTime.now().millisecondsSinceEpoch);
      rotationError = null;
    });
  }

  Future<void> refreshDevices() async {
    try {
      devices = await bridge.trustedDevices();
      errorMessage = null;
    } catch (error) {
      _setError(error);
    }
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await operation();
    } catch (error) {
      _setError(error);
    } finally {
      busy = false;
      // The owner may have been torn down while `operation` was in flight.
      if (!_disposed) notifyListeners();
    }
  }

  void _setPairing(PairingStateDto value) {
    pairing = value;
    _clock?.cancel();
    if (value.deadlineMs != null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (remainingSeconds == 0) timer.cancel();
        if (!_disposed) notifyListeners();
      });
    }
    if (value.kind == PairingKindDto.trusted) {
      unawaited(refreshDevices());
    }
    notifyListeners();
  }

  void _setError(Object error) {
    errorMessage = bridgeMessage(error);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _clock?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

String bridgeMessage(Object error) => switch (error) {
  BridgeError(:final message) => message,
  _ => 'The local collection service encountered an unexpected error.',
};

/// Validation problems split by where a form shows them: an issue naming exactly one field goes
/// under that input ([byField], one line per issue), anything else in the form-level slot above
/// the buttons ([form]).
final class FormIssues {
  const FormIssues({this.byField = const {}, this.form = const []});

  /// Splits Rust issues by field count, keeping Rust's order.
  factory FormIssues.fromIssues(List<BridgeIssueDto> issues) {
    final byField = <String, List<String>>{};
    final form = <String>[];
    for (final issue in issues) {
      if (issue.fields case [final field]) {
        byField.putIfAbsent(field, () => []).add(issue.message);
      } else {
        form.add(issue.message);
      }
    }
    return FormIssues(byField: byField, form: form);
  }

  /// A failure as form issues: a validation error splits by field; anything else (or a
  /// validation error without issues) is one form-level line.
  factory FormIssues.from(Object error) => switch (error) {
    BridgeError(:final issues) when issues.isNotEmpty => FormIssues.fromIssues(
      issues,
    ),
    _ => FormIssues(form: [bridgeMessage(error)]),
  };

  static const none = FormIssues();

  final Map<String, List<String>> byField;
  final List<String> form;

  bool get isEmpty => form.isEmpty && byField.values.every((l) => l.isEmpty);

  /// The lines for [key]; empty when it has none.
  List<String> of(String key) => byField[key] ?? const [];

  /// Renames each key through [inputs] (issue key to input key) and moves every key without an
  /// input into the form slot, so no issue is lost when a form has no input for it.
  FormIssues keyed(Map<String, String> inputs) {
    final byField = <String, List<String>>{};
    final form = [...this.form];
    for (final MapEntry(:key, :value) in this.byField.entries) {
      if (inputs[key] case final input?) {
        byField.putIfAbsent(input, () => []).addAll(value);
      } else {
        form.addAll(value);
      }
    }
    return FormIssues(byField: byField, form: form);
  }

  /// Keeps the keys in [known] and moves the rest into the form slot.
  FormIssues restrictTo(Set<String> known) =>
      keyed({for (final key in known) key: key});

  /// These issues without any under [key], for when that input changes.
  FormIssues without(String key) =>
      FormIssues(byField: {...byField}..remove(key), form: form);

  /// These issues plus one form-level [line], or unchanged when [line] is null.
  FormIssues withForm(String? line) =>
      line == null ? this : FormIssues(byField: byField, form: [...form, line]);

  /// These issues plus one [line] under [key], or unchanged when [line] is null.
  FormIssues withField(String key, String? line) => line == null
      ? this
      : FormIssues(
          byField: {
            ...byField,
            key: [...of(key), line],
          },
          form: form,
        );
}
