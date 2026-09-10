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
  bool loading = true;
  bool creating = false;
  StreamSubscription<BootstrapDto>? _subscription;

  Future<void> start() async {
    loading = true;
    fatalError = null;
    notifyListeners();
    try {
      await initializeRust();
      state = await bridge.initialize(await dataDirProvider());
      await _subscription?.cancel();
      _subscription = bridge.bootstrapEvents().listen(
        (value) {
          state = value;
          notifyListeners();
        },
        onError: (Object error) {
          fatalError = bridgeMessage(error);
          notifyListeners();
        },
      );
    } catch (error) {
      fatalError = bridgeMessage(error);
    } finally {
      loading = false;
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
  bool busy = false;
  bool _disposed = false;
  Timer? _clock;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  Future<void> start() async {
    _subscriptions
      ..add(bridge.pairingStateEvents().listen(_setPairing, onError: _setError))
      ..add(
        bridge.pairingCandidateEvents().listen((value) {
          candidates = value;
          notifyListeners();
        }, onError: _setError),
      )
      ..add(
        bridge.connectionStateEvents().listen((value) {
          devices = value;
          notifyListeners();
        }, onError: _setError),
      )
      ..add(
        bridge.syncStatusEvents().listen((value) {
          syncStatus = value;
          notifyListeners();
        }, onError: _setError),
      );
    await refreshDevices();
    syncStatus = await bridge.syncStatus();
    notifyListeners();
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
    await _run(
      () => bridge.revokeTrustedDevice(
        device.deviceId,
        DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await refreshDevices();
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
      notifyListeners();
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
