import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fi/l10n/error_text.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/file_dialogs.dart';
import 'package:fi/help_button.dart';
import 'package:fi/help_copy.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/l10n/language.dart';
import 'package:intl/intl.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/collections_page.dart';
import 'package:fi/connect_by_address.dart';
import 'package:fi/peer_problem.dart';
import 'package:fi/device_details.dart';
import 'package:fi/pairing_card.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/reset_dialog.dart';
import 'package:fi/settings_page.dart';
import 'package:fi/setup_screens.dart';
import 'package:fi/status_time.dart';
import 'package:fi/theme/confirm_dialog.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CollectionApp extends StatefulWidget {
  const CollectionApp({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
    this.setPlatformForeground,
    this.fileDialogs = const PlatformFileDialogs(),
    this.uiPrefs,
    this.voiceServices,
    this.capabilities,
    super.key,
  });

  final CollectionBridge bridge;
  final Future<void> Function() initializeRust;

  /// Builds the voice services once the data directory is known; none in tests by default.
  final VoiceServices Function(String dataDir, UiPrefsStore prefs)?
  voiceServices;

  /// Device-local list preferences; by default `ui_prefs.json` in the data directory.
  final UiPrefsStore? uiPrefs;
  final Future<String> Function() dataDirProvider;
  final Future<void> Function(bool foreground)? setPlatformForeground;

  /// Save and open dialogs for export and import; replaced in tests.
  final FileDialogs fileDialogs;

  /// What this platform can do; `PlatformCapabilities.current()` by default, replaced in tests.
  final PlatformCapabilities? capabilities;

  @override
  State<CollectionApp> createState() => _CollectionAppState();
}

class _CollectionAppState extends State<CollectionApp>
    with WidgetsBindingObserver {
  late final BootstrapController controller;

  /// Owned here, above the bootstrap switch, so an in-flight pairing
  /// confirmation survives the needs-decision → joining → ready transition.
  late final DevicesController devices;
  bool _devicesStarted = false;
  VoiceServices? _voice;

  /// One store for the list order and voice preferences, so their updates queue.
  late final UiPrefsStore _uiPrefs =
      widget.uiPrefs ?? FileUiPrefsStore(widget.dataDirProvider);
  static const _platform = MethodChannel('fi/platform');
  final LanguageController _language = LanguageController();

  @override
  void initState() {
    super.initState();
    unawaited(_language.load(_uiPrefs));
    WidgetsBinding.instance.addObserver(this);
    controller = BootstrapController(
      bridge: widget.bridge,
      initializeRust: widget.initializeRust,
      dataDirProvider: widget.dataDirProvider,
    );
    devices = DevicesController(widget.bridge);
    unawaited(_start());
  }

  Future<void> _start() async {
    await _setPlatformForeground(true);
    await controller.start();
    if (_voice == null && controller.fatalFailure == null) {
      if (widget.voiceServices case final build?) {
        final voice = build(await widget.dataDirProvider(), _uiPrefs);
        if (mounted) setState(() => _voice = voice);
      }
    }
    await _setForeground(true);
    // Only after the core exists (bridge.initialize) and foreground is set, so
    // every call in DevicesController.start() succeeds and the aggregate
    // status reads Searching rather than Offline on a rootless device.
    if (controller.fatalFailure == null && !_devicesStarted) {
      _devicesStarted = true;
      await devices.start();
    }
  }

  /// Runs a confirmed dataset reset. The devices controller is restarted
  /// afterwards so its streams observe the reopened core rather than the one
  /// the bridge shut down.
  Future<void> _resetDataset() async {
    await controller.resetDataset();
    if (controller.fatalFailure != null) return;
    await _setForeground(true);
    _devicesStarted = true;
    await devices.restart();
  }

  Future<void> _confirmResetFromError(BuildContext context) async {
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead: context.l10n.bootResetLeadError,
    );
    if (confirmed) await _resetDataset();
  }

  /// Deliberate escape from a recovery that no other device can complete.
  /// Never automatic: the user confirms abandoning the recorded root.
  Future<void> _confirmResetFromRecovery(BuildContext context) async {
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead: context.l10n.recoveryResetLead,
    );
    if (confirmed) await _resetDataset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_setForeground(state == AppLifecycleState.resumed));
  }

  Future<void> _setForeground(bool foreground) async {
    try {
      await widget.bridge.setForeground(foreground);
      // The device may have changed networks while in the background.
      if (foreground && mounted) unawaited(devices.loadLocalAddresses());
    } catch (_) {
      // Rust exposes lifecycle failures through its typed error stream.
    }
    await _setPlatformForeground(foreground);
  }

  Future<void> _setPlatformForeground(bool foreground) async {
    if (widget.setPlatformForeground case final callback?) {
      await callback(foreground);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _platform.invokeMethod<void>('setForeground', foreground);
      } on PlatformException {
        // Initialization below maps the unavailable capability to app state.
      }
    }
  }

  @override
  void dispose() {
    _language.dispose();
    devices.dispose();
    controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setForeground(false));
    unawaited(widget.bridge.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformScope(
    capabilities: widget.capabilities ?? PlatformCapabilities.current(),
    child: LanguageScope(
      notifier: _language,
      child: ListenableBuilder(
        listenable: _language,
        builder: (context, _) => _app(),
      ),
    ),
  );

  Widget _app() => MaterialApp(
    title: 'Fi',
    debugShowCheckedModeBanner: false,
    theme: nocturneTheme(),
    locale: _language.locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    localeListResolutionCallback: (locales, supported) =>
        resolveAppLocale(locales, supported),
    builder: (context, child) {
      Intl.defaultLocale = Localizations.localeOf(context).languageCode;
      return child!;
    },
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const _CenteredSurface(
            key: Key('bootstrap-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (controller.fatalFailure case final failure?) {
          return FatalSurface(
            failure: failure,
            resetResolvable: controller.fatalResetResolvable,
            secureStoreLocked: controller.fatalSecureStoreLocked,
            retryingNetworking: controller.retryingNetworking,
            onRetryAfterUnlock: () => unawaited(controller.retryNetworking()),
            onReset: () => unawaited(_confirmResetFromError(context)),
            onRetry: () => unawaited(_start()),
          );
        }
        final surface = switch (controller.state?.kind) {
          BootstrapKindDto.ready => CollectionShell(
            bridge: widget.bridge,
            fileDialogs: widget.fileDialogs,
            uiPrefs: _uiPrefs,
            devices: devices,
            voice: _voice,
            onResetDataset: _resetDataset,
            deferred: controller.networkingDeferred?.kind,
          ),
          BootstrapKindDto.needsDecision => OnboardingPage(
            controller: controller,
            devices: devices,
            onResetDataset: _resetDataset,
          ),
          BootstrapKindDto.joining => switch (controller.state?.recovery) {
            final recovery? when recovery.isActive => RecoverySurface(
              recovery: recovery,
              devices: devices,
              onResetDataset: () => _confirmResetFromRecovery(context),
            ),
            _ => JoiningSurface(devices: devices),
          },
          BootstrapKindDto.creating => const _CenteredSurface(
            child: CircularProgressIndicator(),
          ),
          _ => _CenteredSurface(
            child: Text(context.l10n.bootServiceUnavailable),
          ),
        };
        final deferred = controller.networkingDeferred;
        if (deferred == null) return surface;
        // Local data is usable; only peer networking is waiting, so the
        // explanation sits above the app rather than replacing it.
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: _NetworkingDeferredBanner(
                deferred: deferred,
                ports: controller.deferredPorts,
                retryFailure: controller.networkingRetryFailure,
                busy: controller.retryingNetworking,
                onRetry: () => unawaited(controller.retryNetworking()),
              ),
            ),
            Expanded(child: surface),
          ],
        );
      },
    ),
  );
}

/// Explains why peer networking is off and offers the retry that resumes it (mock
/// startup-errors): a title naming the cause, a body with the fix, and Retry.
class _NetworkingDeferredBanner extends StatelessWidget {
  const _NetworkingDeferredBanner({
    required this.deferred,
    required this.ports,
    required this.retryFailure,
    required this.busy,
    required this.onRetry,
  });

  final NetworkingDeferredDto deferred;
  final NetworkPortsDto? ports;
  final Object? retryFailure;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final phone = MediaQuery.sizeOf(context).width < Nocturne.phoneBreakpoint;
    final retry = OutlinedButton(
      key: const Key('retry-networking'),
      onPressed: busy ? null : onRetry,
      child: Text(l.commonRetry),
    );
    return Padding(
      padding: phone
          ? const EdgeInsets.fromLTRB(12, 10, 12, 4)
          : const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Container(
        key: const Key('networking-deferred-banner'),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: Nocturne.errorTint,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          border: Border.all(color: Nocturne.error.withValues(alpha: .45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                switch (deferred.kind) {
                  NetworkingDeferredKindDto.secureStoreLocked => FiIcons.locked,
                  NetworkingDeferredKindDto.portsExhausted => FiIcons.network,
                  NetworkingDeferredKindDto.secureStoreUnavailable =>
                    FiIcons.offline,
                },
                size: 18,
                color: Nocturne.error,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    networkingDeferredTitle(l, deferred, ports),
                    key: const Key('networking-deferred-title'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    networkingDeferredBody(l, deferred),
                    key: const Key('networking-deferred-message'),
                    style: TextStyle(fontSize: 13, color: Nocturne.muted(.75)),
                  ),
                  if (retryFailure case final failure?) ...[
                    const SizedBox(height: 6),
                    Text(
                      bridgeMessage(l, failure),
                      key: const Key('networking-retry-error'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Nocturne.error,
                      ),
                    ),
                  ],
                  if (phone) ...[const SizedBox(height: 8), retry],
                ],
              ),
            ),
            if (!phone) ...[const SizedBox(width: 12), retry],
          ],
        ),
      ),
    );
  }
}

class _CenteredSurface extends StatelessWidget {
  const _CenteredSurface({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    ),
  );
}

/// "Fi couldn't start" (mock startup-errors). A reset-resolvable error gets the fixed body and
/// the reset; otherwise the localized error and Retry. Rust's own wording goes behind Copy
/// details rather than on the surface.
class FatalSurface extends StatelessWidget {
  const FatalSurface({
    required this.failure,
    required this.resetResolvable,
    required this.secureStoreLocked,
    required this.retryingNetworking,
    required this.onRetryAfterUnlock,
    required this.onReset,
    required this.onRetry,
    super.key,
  });

  final Object failure;
  final bool resetResolvable;
  final bool secureStoreLocked;
  final bool retryingNetworking;
  final VoidCallback onRetryAfterUnlock;
  final VoidCallback onReset;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final localized = bridgeMessage(l, failure);
    final details = switch (failure) {
      BridgeError(kind: != BridgeErrorKind.validation, :final message)
          when message != localized =>
        message,
      _ => null,
    };
    return SetupScaffold(
      key: const Key('bootstrap-error'),
      title: l.fatalTitle,
      children: [
        Text(
          resetResolvable && !secureStoreLocked ? l.fatalResetBody : localized,
          key: const Key('bootstrap-error-body'),
          style: setupBodyStyle(),
        ),
        const SizedBox(height: 24),
        SetupActions(
          children: [
            if (details != null)
              OutlinedButton.icon(
                key: const Key('copy-error-details'),
                onPressed: () => unawaited(
                  copyWithConfirmation(context, details, l.fatalDetailsCopied),
                ),
                icon: const Icon(FiIcons.copy, size: 16),
                label: Text(l.fatalCopyDetails),
              ),
            if (secureStoreLocked)
              FilledButton.icon(
                key: const Key('retry-after-unlock'),
                onPressed: retryingNetworking ? null : onRetryAfterUnlock,
                icon: const Icon(FiIcons.refresh),
                label: Text(l.bootRetryAfterUnlock),
              )
            else if (resetResolvable)
              FilledButton(
                key: const Key('reset-dataset'),
                onPressed: onReset,
                child: Text(l.resetDataEllipsis),
              )
            else
              FilledButton(
                key: const Key('retry-bootstrap'),
                onPressed: onRetry,
                child: Text(l.commonRetry),
              ),
          ],
        ),
      ],
    );
  }
}

extension RecoveryDtoState on RecoveryDto {
  /// Whether the dataset is still being recovered (or waiting for a device
  /// that can supply it), as opposed to a completed or decided recovery.
  bool get isActive =>
      outcome == RecoveryOutcomeDto.recovering ||
      outcome == RecoveryOutcomeDto.noPeerAvailable;
}

/// Shown while a lost or corrupt root snapshot is being recovered from the user's other
/// devices (mock startup-errors). When none can supply it, Retry dials every trusted device
/// now; recovery also resumes on its own when one appears. Never offers to create a new
/// dataset: that would split from the recorded root and never merge again.
class RecoverySurface extends StatelessWidget {
  const RecoverySurface({
    required this.recovery,
    required this.devices,
    required this.onResetDataset,
    super.key,
  });
  final RecoveryDto recovery;
  final DevicesController devices;
  final Future<void> Function() onResetDataset;

  void _retry() {
    for (final device in devices.devices) {
      if (!device.revoked) unawaited(devices.reconnect(device));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return switch (recovery.outcome) {
      RecoveryOutcomeDto.noPeerAvailable => SetupScaffold(
        key: const Key('recovery-no-peer'),
        title: l.recoveryNeedsDevice,
        children: [
          Text(l.recoveryNeedsDeviceBody, style: setupBodyStyle()),
          const SizedBox(height: 24),
          SetupActions(
            children: [
              OutlinedButton(
                key: const Key('recovery-reset-dataset'),
                onPressed: () => unawaited(onResetDataset()),
                child: Text(l.resetDataEllipsis),
              ),
              FilledButton(
                key: const Key('recovery-retry'),
                onPressed: _retry,
                child: Text(l.commonRetry),
              ),
            ],
          ),
        ],
      ),
      _ => SetupScaffold(
        key: const Key('recovery-recovering'),
        leading: const SetupRing(),
        title: l.recoveringTitle,
        children: [Text(l.recoveringBody, style: setupBodyStyle())],
      ),
    };
  }
}

/// Shown while a received root is being joined (mock onboarding-joining). Names the
/// provisioning device when the pairing session that started the join is still known. No
/// progress or cancel: Rust reports neither.
class JoiningSurface extends StatelessWidget {
  const JoiningSurface({required this.devices, super.key});
  final DevicesController devices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: devices,
    builder: (context, _) {
      final l = context.l10n;
      final name = devices.peerName;
      return SetupScaffold(
        key: const Key('joining-surface'),
        leading: const SetupRing(),
        title: name == null ? l.joiningTitle : l.joiningTitleNamed(name),
        children: [
          Text(
            name == null ? l.joiningBody : l.joiningBodyNamed(name),
            style: setupBodyStyle(),
          ),
        ],
      );
    },
  );
}

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    required this.controller,
    required this.devices,
    this.onResetDataset,
    super.key,
  });
  final BootstrapController controller;
  final DevicesController devices;
  final ResetDatasetAction? onResetDataset;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  /// Whether the Join view replaces the two choices.
  bool _join = false;

  DevicesController get devices => widget.devices;

  bool get _pairingActive => devices.pairing.kind != PairingKindDto.idle;

  Future<void> _create() async {
    // Unconditional, not gated on the observed pairing state: the stream may
    // not have delivered an open window yet. A window advertises the root state
    // captured when it opened, so it must be closed before a root exists or a
    // peer may provision against a state that no longer holds. Stopping from
    // idle is a no-op in Rust.
    await devices.stopPairing();
    await widget.controller.createNewDataset();
  }

  void _openJoin() {
    setState(() => _join = true);
    if (!_pairingActive) unawaited(devices.beginPairing());
  }

  /// Back from a terminal failure: pairing stops and the two choices return.
  Future<void> _backToChoices() async {
    setState(() => _join = false);
    await devices.stopPairing();
  }

  Future<void> _confirmReset() async {
    final action = widget.onResetDataset;
    if (action == null) return;
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead: context.l10n.pairingResetLead,
    );
    if (!confirmed) return;
    await devices.stopPairing();
    await action();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: devices,
    builder: (context, _) {
      final pairing = devices.pairing;
      if (pairing.kind == PairingKindDto.failed) {
        switch (pairing.failure) {
          case PairingFailureKindDto.bothRootless:
            return CouldntJoinScreen(onBack: () => unawaited(_backToChoices()));
          case PairingFailureKindDto.rootMismatch:
            return DatasetMismatchScreen(
              peerName: devices.peerName,
              onBack: () => unawaited(_backToChoices()),
              onPairDifferent: () {
                setState(() => _join = true);
                unawaited(devices.beginPairing());
              },
              onReset: widget.onResetDataset == null
                  ? null
                  : () => unawaited(_confirmReset()),
            );
          case _:
        }
      }
      return _join ? _joinView(context) : _choices(context);
    },
  );

  Widget _choices(BuildContext context) {
    final l = context.l10n;
    final controller = widget.controller;
    final pairingOpen = _pairingActive;
    return SetupScaffold(
      key: const Key('onboarding'),
      title: l.setupTitle,
      lead: l.setupLead,
      children: [
        ChoiceCard(
          key: const Key('create-dataset'),
          icon: FiIcons.addCircle,
          title: controller.creating ? l.onboardCreating : l.setupCreateTitle,
          body: l.setupCreateBody,
          lockedReason: pairingOpen ? l.setupCreateLocked : null,
          onTap: controller.creating ? null : () => unawaited(_create()),
        ),
        const SizedBox(height: 12),
        ChoiceCard(
          key: const Key('join-dataset'),
          icon: FiIcons.link,
          title: l.setupJoinTitle,
          body: l.setupJoinBody,
          bullets: [l.setupJoinNeedsDataset, l.setupJoinOneSide],
          selected: pairingOpen,
          onTap: controller.creating ? null : _openJoin,
        ),
        if (pairingOpen) ...[
          const SizedBox(height: 20),
          PairingStatusRow(devices: devices),
        ],
        if (controller.state?.recovery case final recovery?
            when recovery.outcome == RecoveryOutcomeDto.quarantined) ...[
          const SizedBox(height: 20),
          Text(
            l.onboardQuarantined,
            key: const Key('recovery-quarantined'),
            style: TextStyle(fontSize: 13, color: Nocturne.muted(.55)),
          ),
        ],
      ],
    );
  }

  Widget _joinView(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _join = false);
      },
      child: SetupScaffold(
        key: const Key('join-view'),
        title: l.setupJoinTitle,
        lead: l.joinLead,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('join-back'),
              onPressed: () => setState(() => _join = false),
              icon: const Icon(FiIcons.back, size: 16),
              label: Text(l.commonBack),
            ),
          ),
          const SizedBox(height: 8),
          if (devices.failure case final failure?)
            _ErrorBanner(bridgeMessage(l, failure)),
          PairingCard(controller: devices),
        ],
      ),
    );
  }
}

class CollectionShell extends StatefulWidget {
  const CollectionShell({
    required this.bridge,
    required this.devices,
    this.onResetDataset,
    this.fileDialogs = const PlatformFileDialogs(),
    this.uiPrefs,
    this.voice,
    this.deferred,
    super.key,
  });
  final CollectionBridge bridge;
  final FileDialogs fileDialogs;

  /// Why peer networking has not started, while it has not; the status then reads Offline
  /// with the cause instead of the Rust aggregate.
  final NetworkingDeferredKindDto? deferred;
  final UiPrefsStore? uiPrefs;
  final DevicesController devices;

  /// Voice fill and the Settings tab's voice and microphone sections; absent in most tests.
  final VoiceServices? voice;
  final ResetDatasetAction? onResetDataset;

  @override
  State<CollectionShell> createState() => _CollectionShellState();
}

class _CollectionShellState extends State<CollectionShell> {
  late final CollectionsController controller;
  DevicesController get devices => widget.devices;
  int selected = 0;

  @override
  void initState() {
    super.initState();
    controller = CollectionsController(
      widget.bridge,
      fileDialogs: widget.fileDialogs,
      uiPrefs: widget.uiPrefs,
    );
    unawaited(controller.start());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _select(int value) {
    setState(() => selected = value);
    if (value == 2) unawaited(devices.loadLocalAddresses());
  }

  @override
  Widget build(BuildContext context) => VoiceScope(
    services: widget.voice,
    openSettings: () => _select(2),
    child: switch (widget.voice) {
      final voice? => VoiceLanguageSync(
        services: voice,
        child: _shell(context),
      ),
      null => _shell(context),
    },
  );

  Widget _shell(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, devices]),
    builder: (context, _) => PopScope(
      canPop:
          selected == 0 &&
          controller.selectedCollectionId == null &&
          !controller.selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // System back unwinds the shell one step: selection, open collection, then tab.
        if (controller.selecting) {
          controller.clearSelection();
        } else if (controller.selectedCollectionId != null) {
          unawaited(controller.selectCollection(null));
        } else {
          _select(0);
        }
      },
      child: _layout(context),
    ),
  );

  Widget _layout(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final page = IndexedStack(
      index: selected,
      children: [
        CollectionsPage(controller: controller),
        DevicesPage(controller: devices, onResetDataset: widget.onResetDataset),
        SettingsPage(
          buildInfo: devices.buildInfo,
          localAddresses: devices.localAddresses,
        ),
      ],
    );
    if (wide) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              selected: selected,
              onSelected: _select,
              devices: devices,
              deferred: widget.deferred,
            ),
            Expanded(child: page),
          ],
        ),
      );
    }
    // The slim brand row belongs to the top-level lists; a collection brings its own header
    // with a back button, and the devices page states the sync status itself.
    final topRow = switch (selected) {
      0 when controller.selectedCollectionId == null => _MobileTopRow(
        status: devices.syncStatus,
        deferred: widget.deferred,
      ),
      1 || 2 => const _MobileTopRow(),
      _ => null,
    };
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ?topRow,
            Expanded(child: page),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Nocturne.divider)),
        ),
        child: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: _select,
          destinations: [
            NavigationDestination(
              icon: const Icon(FiIcons.collection),
              label: context.l10n.navCollections,
            ),
            NavigationDestination(
              icon: const Icon(FiIcons.devices),
              label: context.l10n.navDevices,
            ),
            NavigationDestination(
              icon: const Icon(FiIcons.settings),
              label: context.l10n.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}

/// The wide-layout navigation: brand, destinations, and the aggregate sync status at the foot.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.onSelected,
    required this.devices,
    required this.deferred,
  });

  final int selected;
  final ValueChanged<int> onSelected;
  final DevicesController devices;
  final NetworkingDeferredKindDto? deferred;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('sidebar'),
    width: 216,
    padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Nocturne.surface, Nocturne.bg],
      ),
      border: Border(right: BorderSide(color: Nocturne.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 2, 8, 20),
          child: Row(
            children: [
              FiLogoTile(),
              SizedBox(width: 10),
              Text(
                'Fi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        _NavRow(
          icon: FiIcons.collection,
          label: context.l10n.navCollections,
          selected: selected == 0,
          onTap: () => onSelected(0),
        ),
        const SizedBox(height: 4),
        _NavRow(
          icon: FiIcons.devices,
          label: context.l10n.navDevices,
          selected: selected == 1,
          onTap: () => onSelected(1),
        ),
        const SizedBox(height: 4),
        _NavRow(
          key: const Key('nav-settings'),
          icon: FiIcons.settings,
          label: context.l10n.navSettings,
          selected: selected == 2,
          onTap: () => onSelected(2),
        ),
        const Spacer(),
        _SidebarStatus(devices: devices, deferred: deferred),
      ],
    ),
  );
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Nocturne.accent200 : Nocturne.muted(.7);
    return Material(
      color: selected ? Nocturne.accent900 : Colors.transparent,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 14, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.devices, this.deferred});
  final DevicesController devices;
  final NetworkingDeferredKindDto? deferred;

  @override
  Widget build(BuildContext context) {
    final trusted = devices.devices.where((device) => !device.revoked);
    final reachable = trusted
        .where(
          (device) =>
              device.connection == PeerConnectionKindDto.connected ||
              device.connection == PeerConnectionKindDto.syncing ||
              device.connection == PeerConnectionKindDto.synced,
        )
        .length;
    final deferred = this.deferred;
    final status = deferred == null
        ? devices.syncStatus
        : SyncStatusDto.offline;
    return Container(
      key: const Key('app-bar-sync-status'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: Nocturne.neutral800),
      ),
      child: Row(
        children: [
          _StatusDot(status: status),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusText(context.l10n, status),
                  key: const Key('sidebar-status'),
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
                Text(
                  key: const Key('sidebar-status-context'),
                  deferred != null
                      ? deferredCause(context.l10n, deferred)
                      : devices.syncStatus == SyncStatusDto.paused
                      ? context.l10n.sidebarSyncOff
                      : _pairingOpen(devices.pairing.kind)
                      ? context.l10n.sidebarPairingOpen
                      : context.l10n.sidebarPairedSummary(
                          trusted.length,
                          reachable == 0
                              ? context.l10n.sidebarNoneNearby
                              : context.l10n.sidebarConnectedCount(reachable),
                        ),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Nocturne.muted(.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// True while pairing mode runs: from discoverable until it is trusted, failed or stopped.
bool _pairingOpen(PairingKindDto kind) => switch (kind) {
  PairingKindDto.discoverable ||
  PairingKindDto.connecting ||
  PairingKindDto.awaitingConfirmation ||
  PairingKindDto.committing => true,
  PairingKindDto.idle ||
  PairingKindDto.trusted ||
  PairingKindDto.failed => false,
};

/// The aggregate status as a dot: lit while the device is reaching peers, dim when offline.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, this.size = 8, this.ring = true});
  final SyncStatusDto status;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) => switch (status) {
    SyncStatusDto.offline || SyncStatusDto.paused => GlowDot(
      size: size,
      ring: false,
      color: Nocturne.neutral600,
    ),
    SyncStatusDto.error => GlowDot(
      size: size,
      ring: false,
      color: Nocturne.error,
    ),
    _ => GlowDot(size: size, ring: ring),
  };
}

/// The phone-width brand row, with the aggregate status when [status] is given.
class _MobileTopRow extends StatelessWidget {
  const _MobileTopRow({this.status, this.deferred});
  final SyncStatusDto? status;

  /// Replaces [status] with "Offline · cause" while networking is deferred.
  final NetworkingDeferredKindDto? deferred;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
    child: Row(
      children: [
        const FiLogoTile(),
        const Spacer(),
        if (status case final live?)
          Flexible(
            child: Row(
              key: const Key('app-bar-sync-status'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusDot(
                  status: deferred == null ? live : SyncStatusDto.offline,
                  size: 7,
                  ring: false,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    switch (deferred) {
                      final cause? =>
                        '${context.l10n.devicesStatusOffline} · '
                            '${deferredCause(context.l10n, cause)}',
                      null => _statusText(context.l10n, live),
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

String _statusText(
  AppLocalizations l,
  SyncStatusDto status,
) => switch (status) {
  SyncStatusDto.offline => l.devicesStatusOffline,
  // Not "Searching": that word belongs to pairing discovery on the pairing card, and the
  // aggregate status is already `Searching` at boot before the user has touched pairing.
  SyncStatusDto.searching => l.devicesStatusLooking,
  SyncStatusDto.connected => l.devicesStatusConnected,
  SyncStatusDto.syncing => l.devicesStatusSyncing,
  SyncStatusDto.synced => l.devicesStatusSynced,
  SyncStatusDto.error => l.devicesStatusError,
  SyncStatusDto.paused => l.devicesStatusPaused,
};

/// One distinct icon per aggregate status, so the state is readable without the label.
IconData _statusIcon(SyncStatusDto status) => switch (status) {
  SyncStatusDto.offline => FiIcons.offline,
  SyncStatusDto.searching => FiIcons.searching,
  SyncStatusDto.connected => FiIcons.link,
  SyncStatusDto.syncing => FiIcons.syncing,
  SyncStatusDto.synced => FiIcons.synced,
  SyncStatusDto.error => FiIcons.error,
  SyncStatusDto.paused => FiIcons.paused,
};

class DevicesPage extends StatefulWidget {
  const DevicesPage({required this.controller, this.onResetDataset, super.key});
  final DevicesController controller;
  final ResetDatasetAction? onResetDataset;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  // Relative status times ("5 min ago") go stale without device events, so
  // the page rebuilds once a minute while mounted.
  late final Timer _ticker;

  /// Device ids whose Details disclosure is open.
  final Set<String> _openDetails = {};

  /// The pairing session whose "Paired with …" banner was dismissed.
  String? _dismissedBanner;

  DevicesController get controller => widget.controller;
  ResetDatasetAction? get onResetDataset => widget.onResetDataset;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  bool get _pairedBanner =>
      controller.pairing.kind == PairingKindDto.trusted &&
      _dismissedBanner != (controller.pairing.sessionId ?? '');

  @override
  Widget build(BuildContext context) {
    // `clock` rather than `DateTime.now()` so widget tests can advance time.
    final now = clock.now();
    final phone = MediaQuery.sizeOf(context).width < 720;
    final theme = Theme.of(context);
    final trusted = controller.devices;
    final pairingKind = controller.pairing.kind;
    // A finished pairing is announced by the banner; the card only runs a pairing.
    final pairing =
        pairingKind != PairingKindDto.idle &&
        pairingKind != PairingKindDto.trusted;
    final discoveryOff = !controller.preferences.discoverable;
    final l = context.l10n;
    return ListView(
      key: const Key('devices-page'),
      padding: phone
          ? const EdgeInsets.fromLTRB(16, 12, 16, 24)
          : const EdgeInsets.fromLTRB(32, 22, 32, 32),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 816),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.navDevices,
                  style: phone
                      ? theme.textTheme.headlineSmall
                      : theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                if (!phone)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l.devicesIntro,
                      style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
                    ),
                  ),
                _SyncChip(status: controller.syncStatus, phone: phone),
                const SizedBox(height: 22),
                if (controller.failure case final failure?)
                  _ErrorBanner(bridgeMessage(context.l10n, failure)),
                if (controller.rotationError case final error?)
                  MaterialBanner(
                    key: const Key('rotation-error'),
                    content: Text(l.devicesRotationError(error)),
                    actions: [
                      TextButton(
                        key: const Key('retry-rotation'),
                        onPressed: controller.busy
                            ? null
                            : controller.retryRotation,
                        child: Text(l.devicesRetryRotation),
                      ),
                    ],
                  ),
                if (_pairedBanner) ...[
                  _PairedBanner(
                    name: controller.peerName ?? l.devicesOtherDevice,
                    onDismiss: () => setState(
                      () =>
                          _dismissedBanner = controller.pairing.sessionId ?? '',
                    ),
                    onPairAnother: controller.busy
                        ? null
                        : controller.beginPairing,
                  ),
                  const SizedBox(height: 14),
                ],
                Row(
                  children: [
                    Expanded(
                      child: SectionLabel(
                        l.devicesTrustedHeading(trusted.length),
                        key: const Key('trusted-heading'),
                      ),
                    ),
                    if (trusted.isNotEmpty && !pairing) ...[
                      if (discoveryOff && !phone)
                        Flexible(
                          flex: 2,
                          child: Text(
                            PairingCard.discoveryOffNote(context.l10n),
                            key: const Key('discovery-off-note'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              color: Nocturne.muted(.5),
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            key: const Key('start-pairing'),
                            onPressed: controller.busy
                                ? null
                                : controller.beginPairing,
                            icon: const Icon(FiIcons.link, size: 16),
                            label: Text(l.devicesPairDevice),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (trusted.isNotEmpty && !pairing && discoveryOff && phone)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      PairingCard.discoveryOffNote(context.l10n),
                      key: const Key('discovery-off-note'),
                      style: TextStyle(fontSize: 12, color: Nocturne.muted(.5)),
                    ),
                  ),
                const SizedBox(height: 10),
                if (pairing) ...[
                  PairingCard(
                    controller: controller,
                    onTerminalFailure: (_) => unawaited(_showMismatch(context)),
                  ),
                  if (trusted.isNotEmpty) const SizedBox(height: 12),
                ] else if (trusted.isEmpty)
                  _NoDevices(
                    phone: phone,
                    discoveryOff: discoveryOff,
                    onStart: controller.busy ? null : controller.beginPairing,
                  ),
                if (trusted.isNotEmpty)
                  NocturneCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final (index, device) in trusted.indexed) ...[
                          if (index > 0) const FadedRule(indent: 16),
                          _deviceRow(context, device, now, phone: phone),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 26),
                SectionLabel(l.devicesThisDevice),
                const SizedBox(height: 10),
                _LocalIdentity(
                  device: controller.localDevice,
                  phone: phone,
                  onReset: onResetDataset == null || controller.busy
                      ? null
                      : () => _resetDataset(context),
                  showReset: onResetDataset != null,
                ),
                const SizedBox(height: 26),
                _ConnectionSwitches(controller: controller),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One trusted device (mock devices): icon tile, name with its state tag, when it was last
  /// seen and synced, Details, and the ⋮ menu. Details expand inline on wide screens and open as
  /// a pushed screen on a phone.
  Widget _deviceRow(
    BuildContext context,
    TrustedDeviceDto device,
    DateTime now, {
    required bool phone,
  }) {
    final open = _openDetails.contains(device.deviceId);
    final summary = Row(
      children: [
        IconTile(
          device.revoked ? FiIcons.blocked : FiIcons.devices,
          fill: Nocturne.neutral800,
          color: Nocturne.text,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The state tag wraps under the name rather than being cut short.
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    device.friendlyName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  DeviceStateTag(device: device),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _timesLine(context.l10n, device, now),
                key: Key('device-times-${device.deviceId}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFeatures: Nocturne.tabular,
                  color: Nocturne.muted(.55),
                ),
              ),
            ],
          ),
        ),
        if (phone)
          Icon(
            FiIcons.chevronRight,
            key: Key('device-chevron-${device.deviceId}'),
            size: 18,
            color: Nocturne.muted(.5),
          )
        else ...[
          TextButton.icon(
            key: Key('device-details-${device.deviceId}'),
            onPressed: () => _toggleDetails(device),
            icon: Icon(open ? FiIcons.collapse : FiIcons.expand, size: 16),
            label: Text(context.l10n.commonDetails),
          ),
          _deviceMenu(context, device),
        ],
      ],
    );
    return Padding(
      key: Key('device-${device.deviceId}'),
      padding: phone
          ? const EdgeInsets.symmetric(vertical: 4)
          : const EdgeInsets.fromLTRB(16, 12, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (phone)
            // On a phone the whole row is the Details action (mock devices).
            InkWell(
              key: Key('device-details-${device.deviceId}'),
              onTap: () => unawaited(_pushDetails(context, device)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
                  child: summary,
                ),
              ),
            )
          else
            summary,
          if (peerProblemOf(device) case final problem?)
            Padding(
              padding: phone
                  ? const EdgeInsets.fromLTRB(16, 0, 14, 10)
                  : const EdgeInsets.fromLTRB(50, 10, 10, 0),
              child: PeerGuidanceBox(
                key: Key('device-problem-${device.deviceId}'),
                deviceId: device.deviceId,
                problem: problem,
                onTryAgain: controller.reconnecting.contains(device.deviceId)
                    ? null
                    : () => unawaited(controller.reconnect(device)),
                onPairAgain: () => unawaited(controller.beginPairing()),
                onConnectByAddress: !phone && problem != PeerProblem.notVerified
                    ? () => unawaited(
                        showConnectByAddress(context, controller, device),
                      )
                    : null,
              ),
            ),
          if (open && !phone)
            Padding(
              padding: const EdgeInsets.fromLTRB(50, 12, 10, 4),
              child: DeviceDetails(
                device: device,
                controller: controller,
                now: now,
                onCopyLog: () => _copyDiagnostics(context, device),
              ),
            ),
        ],
      ),
    );
  }

  /// The row's second line: the problem and last sync for an unreachable device, else when it
  /// was last seen and synced.
  String _timesLine(AppLocalizations l, TrustedDeviceDto device, DateTime now) {
    final problem = peerProblemOf(device);
    if (problem == null) return seenSyncedLine(l, device, now);
    final line = peerProblemLine(l, problem);
    return device.lastSyncMs == null
        ? l.peerNeverSynced(line)
        : l.peerLastSynced(
            line,
            formatStatusTime(l, device.lastSyncMs, now: now),
          );
  }

  /// The row's rename, revoke and delete actions.
  Widget _deviceMenu(
    BuildContext context,
    TrustedDeviceDto device,
  ) => PopupMenuButton<String>(
    tooltip: context.l10n.devicesActions,
    icon: const Icon(FiIcons.more),
    onSelected: (action) {
      if (action == 'rename') _renameDevice(context, device);
      if (action == 'revoke') _revokeDevice(context, device);
      if (action == 'delete') _deleteDevice(context, device);
    },
    itemBuilder: (_) => [
      PopupMenuItem(value: 'rename', child: Text(context.l10n.commonRename)),
      if (!device.revoked)
        PopupMenuItem(
          value: 'revoke',
          child: Text(context.l10n.devicesRevokeUnpair),
        ),
      if (device.revoked)
        PopupMenuItem(value: 'delete', child: Text(context.l10n.commonDelete)),
    ],
  );

  void _toggleDetails(TrustedDeviceDto device) {
    setState(() {
      if (!_openDetails.remove(device.deviceId)) {
        _openDetails.add(device.deviceId);
      }
    });
    if (_openDetails.contains(device.deviceId)) {
      unawaited(controller.loadDetails(device));
    } else {
      controller.closeDetails(device.deviceId);
    }
  }

  /// Details as a pushed screen on a phone (mock devices-details).
  Future<void> _pushDetails(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    unawaited(controller.loadDetails(device));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceDetailsScreen(
          deviceId: device.deviceId,
          controller: controller,
          menu: _deviceMenu,
          onCopyLog: _copyDiagnostics,
        ),
      ),
    );
    controller.closeDetails(device.deviceId);
  }

  Future<void> _copyDiagnostics(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = context.l10n;
    if (await controller.copyDiagnostics(device)) {
      messenger?.showSnackBar(SnackBar(content: Text(l.devicesLogCopied)));
    }
  }

  /// A root mismatch from the Devices page as a pushed "different dataset" screen. Back
  /// stops pairing and pops; a confirmed reset pops before it runs, so the app lands on
  /// onboarding rather than under a stale route.
  Future<void> _showMismatch(BuildContext context) async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (routeContext) => ListenableBuilder(
          listenable: controller,
          builder: (routeContext, _) => DatasetMismatchScreen(
            peerName: controller.peerName,
            onBack: () {
              unawaited(controller.stopPairing());
              Navigator.of(routeContext).pop();
            },
            onPairDifferent: () {
              unawaited(controller.beginPairing());
              Navigator.of(routeContext).pop();
            },
            onReset: onResetDataset == null
                ? null
                : () => unawaited(_resetFromMismatch(routeContext)),
          ),
        ),
      ),
    );
  }

  Future<void> _resetFromMismatch(BuildContext routeContext) async {
    final action = onResetDataset;
    if (action == null) return;
    final confirmed = await ResetDatasetDialog.show(
      routeContext,
      lead: routeContext.l10n.pairingResetLead,
      trustedDeviceCount: controller.devices
          .where((device) => !device.revoked)
          .length,
    );
    if (!confirmed || !routeContext.mounted) return;
    Navigator.of(routeContext).pop();
    await controller.stopPairing();
    await action();
  }

  Future<void> _resetDataset(BuildContext context) async {
    final action = onResetDataset;
    if (action == null) return;
    final trusted = controller.devices
        .where((device) => !device.revoked)
        .length;
    final confirmed = await ResetDatasetDialog.show(
      context,
      trustedDeviceCount: trusted,
    );
    if (confirmed) await action();
  }

  Future<void> _renameDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    var name = device.friendlyName;
    final l = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.devicesRenameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.devicesRenameSubtitle,
              style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
            ),
            const SizedBox(height: 14),
            FiTextInput(
              key: const Key('device-name'),
              initialValue: name,
              onChanged: (value) => name = value,
              autofocus: true,
              label: l.devicesNameLabel,
              required: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.commonCancel),
          ),
          FilledButton(
            onPressed: () async {
              await controller.rename(device, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: Text(l.commonSave),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    final l = context.l10n;
    final confirmed = await showConfirmDialog(
      context,
      title: l.devicesRevokeTitle(device.friendlyName),
      body: l.devicesRevokeBody,
      destructive: l.devicesRevoke,
      safe: l.devicesKeepDevice,
      dialogKey: const Key('revoke-dialog'),
      destructiveKey: const Key('revoke-confirm'),
      safeKey: const Key('revoke-keep'),
    );
    if (confirmed) await controller.revoke(device);
  }

  Future<void> _deleteDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    final l = context.l10n;
    final confirmed = await showConfirmDialog(
      context,
      title: l.devicesDeleteTitle,
      body: l.devicesDeleteBody(device.friendlyName),
      destructive: l.commonDelete,
      safe: l.devicesKeep,
      dialogKey: const Key('delete-dialog'),
      destructiveKey: const Key('delete-confirm'),
      safeKey: const Key('delete-keep'),
    );
    if (confirmed) await controller.delete(device);
  }
}

/// The two installation-level networking switches. Each shows the value Rust
/// stored; a failed toggle leaves it unchanged with an error line under it.
class _ConnectionSwitches extends StatelessWidget {
  const _ConnectionSwitches({required this.controller});
  final DevicesController controller;

  @override
  Widget build(BuildContext context) {
    final preferences = controller.preferences;
    final enabled = !controller.busy;
    final l = context.l10n;
    return Column(
      key: const Key('connection-switches'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionLabel(l.devicesConnections),
        const SizedBox(height: 10),
        NocturneCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              FiSwitchTile(
                key: const Key('pref-discoverable'),
                value: preferences.discoverable,
                onChanged: enabled ? controller.setDiscoverable : null,
                leading: const IconTile(FiIcons.network, size: 32),
                title: _SwitchTitle(l.devicesDiscoverable, HelpId.discoverable),
                subtitle: Text(l.devicesDiscoverableSubtitle),
              ),
              if (controller.discoverableError)
                const _SwitchError(Key('pref-discoverable-error')),
              const FadedRule(indent: 16),
              FiSwitchTile(
                key: const Key('pref-sync'),
                value: preferences.syncEnabled,
                onChanged: enabled ? controller.setSyncEnabled : null,
                leading: const IconTile(FiIcons.syncing, size: 32),
                title: _SwitchTitle(l.devicesSyncEnabled, HelpId.syncEnabled),
                subtitle: Text(l.devicesSyncEnabledSubtitle),
              ),
              if (controller.syncError)
                const _SwitchError(Key('pref-sync-error')),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Couldn't change this. Try again." under the switch whose toggle failed.
class _SwitchError extends StatelessWidget {
  const _SwitchError(Key key) : super(key: key);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(60, 0, 16, 12),
    child: Row(
      children: [
        const Icon(FiIcons.error, size: 14, color: Nocturne.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            context.l10n.devicesSwitchError,
            style: const TextStyle(fontSize: 12, color: Nocturne.error),
          ),
        ),
      ],
    ),
  );
}

class _SwitchTitle extends StatelessWidget {
  const _SwitchTitle(this.label, this.help);
  final String label;
  final HelpId help;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(child: Text(label)),
      HelpButton(help),
    ],
  );
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.status, required this.phone});
  final SyncStatusDto status;
  final bool phone;
  @override
  Widget build(BuildContext context) => Row(
    key: const Key('sync-status'),
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(_statusIcon(status), size: 14, color: Nocturne.accent),
      const SizedBox(width: 6),
      Flexible(
        child: Text(switch (status) {
          SyncStatusDto.paused when phone =>
            context.l10n.devicesChipPausedShort,
          SyncStatusDto.paused => context.l10n.devicesChipPaused,
          _ => _statusText(context.l10n, status),
        }, style: TextStyle(fontSize: 12, color: Nocturne.muted(.6))),
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message),
    actions: const [SizedBox.shrink()],
  );
}

/// The dashed "Trusted devices" empty state (mock devices) with the one way into pairing.
class _NoDevices extends StatelessWidget {
  const _NoDevices({
    required this.phone,
    required this.discoveryOff,
    required this.onStart,
  });

  final bool phone;
  final bool discoveryOff;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) => DashedSlot(
    key: const Key('no-devices'),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      child: Column(
        children: [
          const IconTile(FiIcons.devices),
          const SizedBox(height: 12),
          Text(
            context.l10n.devicesNoneYet,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            phone
                ? context.l10n.devicesNoneBodyPhone
                : context.l10n.devicesNoneBody,
            key: const Key('no-devices-body'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
          ),
          if (discoveryOff) ...[
            const SizedBox(height: 6),
            Text(
              PairingCard.discoveryOffNote(context.l10n),
              key: const Key('discovery-off-note'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.5)),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('start-pairing'),
            style: phone
                ? FilledButton.styleFrom(minimumSize: const Size(0, 46))
                : null,
            onPressed: onStart,
            icon: const Icon(FiIcons.link),
            label: Text(context.l10n.pairingStart),
          ),
        ],
      ),
    ),
  );
}

/// Announces a finished pairing until dismissed or pairing starts again.
class _PairedBanner extends StatelessWidget {
  const _PairedBanner({
    required this.name,
    required this.onDismiss,
    required this.onPairAnother,
  });

  final String name;
  final VoidCallback onDismiss;
  final VoidCallback? onPairAnother;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('paired-banner'),
    padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
    decoration: BoxDecoration(
      color: Nocturne.accent900,
      borderRadius: BorderRadius.circular(Nocturne.radius),
      border: Border.all(color: Nocturne.accent700),
    ),
    child: Row(
      children: [
        const Icon(FiIcons.verified, size: 18, color: Nocturne.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            context.l10n.devicesPairedBanner(name),
            style: const TextStyle(fontSize: 13, color: Nocturne.accent100),
          ),
        ),
        TextButton(
          key: const Key('pair-another'),
          onPressed: onPairAnother,
          child: Text(context.l10n.devicesPairAnother),
        ),
        FiIconButton(
          key: const Key('dismiss-paired-banner'),
          icon: FiIcons.close,
          tooltip: context.l10n.devicesDismiss,
          color: Nocturne.accent100,
          onPressed: onDismiss,
        ),
      ],
    ),
  );
}

/// The "This device" section (mock devices): pairing name, the DeviceId grouped (shortened on a
/// phone) with Copy ID, and the reset entry. Without an identity it says networking is not set
/// up.
class _LocalIdentity extends StatefulWidget {
  const _LocalIdentity({
    required this.device,
    required this.phone,
    required this.showReset,
    required this.onReset,
  });
  final LocalDeviceDto? device;
  final bool phone;
  final bool showReset;
  final VoidCallback? onReset;

  @override
  State<_LocalIdentity> createState() => _LocalIdentityState();
}

class _LocalIdentityState extends State<_LocalIdentity> {
  /// "ID copied" stands in for Copy ID until this fires.
  Timer? _copied;

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  Future<void> _copy(String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    _copied?.cancel();
    setState(
      () => _copied = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = null);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final phone = widget.phone;
    final showReset = widget.showReset;
    final onReset = widget.onReset;
    return NocturneCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: device == null
                ? Row(
                    key: const Key('local-device-missing'),
                    children: [
                      const IconTile(
                        FiIcons.offline,
                        size: 32,
                        fill: Nocturne.neutral800,
                        color: Nocturne.text,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.devicesNetworkingMissing,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              context.l10n.devicesNetworkingMissingBody,
                              style: TextStyle(
                                fontSize: 12,
                                color: Nocturne.muted(.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const IconTile(FiIcons.phone, size: 32),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.pairingName,
                              key: const Key('local-device-name'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              context.l10n.devicesLocalNameHint,
                              key: const Key('local-device-name-hint'),
                              style: TextStyle(
                                fontSize: 12,
                                color: Nocturne.muted(.55),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              phone
                                  ? shortDeviceId(device.deviceId)
                                  : groupedDeviceId(device.deviceId),
                              key: const Key('local-device-id'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: Nocturne.monoFamily,
                                color: Nocturne.muted(.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_copied != null)
                        Padding(
                          key: const Key('local-id-copied'),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                FiIcons.check,
                                size: 16,
                                color: Nocturne.accent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                context.l10n.devicesIdCopied,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Nocturne.accent200,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        TextButton.icon(
                          key: const Key('copy-local-id'),
                          onPressed: () => unawaited(_copy(device.deviceId)),
                          icon: const Icon(FiIcons.copy, size: 16),
                          label: Text(context.l10n.devicesCopyId),
                        ),
                    ],
                  ),
          ),
          if (showReset) ...[
            const FadedRule(indent: 16),
            InkWell(
              key: const Key('reset-dataset'),
              onTap: onReset,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(Nocturne.radius),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    const IconTile(
                      FiIcons.reset,
                      size: 32,
                      fill: Nocturne.neutral800,
                      color: Nocturne.text,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.l10n.shellResetData,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            context.l10n.devicesResetBody,
                            style: TextStyle(
                              fontSize: 12,
                              color: Nocturne.muted(.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      FiIcons.chevronRight,
                      size: 16,
                      color: Nocturne.muted(.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
