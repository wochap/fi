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
  }

  void _clearFatal() {
    fatalError = null;
    fatalResetResolvable = false;
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

  Future<void> deleteCollection(String id) async {
    await bridge.deleteCollection(id);
    if (selectedCollectionId == id) selectedCollectionId = null;
    await refresh();
  }

  Future<void> addField(FieldDefinitionDto field) async {
    await bridge.addField(selectedCollectionId!, field);
    await refresh();
  }

  Future<void> updateField(FieldDefinitionDto field) async {
    await bridge.updateField(selectedCollectionId!, field);
    await refresh();
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

  Future<void> deleteRecord(String id) async {
    await bridge.deleteRecord(id, selectedCollectionId!);
    await refresh();
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
  );
  List<PairingCandidateDto> candidates = const [];
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
      candidates = value;
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
    );
    candidates = const [];
    devices = const [];
    syncStatus = SyncStatusDto.offline;
    errorMessage = null;
    rotationError = null;
    busy = false;
    await start();
  }

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
