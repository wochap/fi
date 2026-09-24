import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fi/bridge/collection_bridge.dart';
import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/collections_page.dart';
import 'package:fi/pairing_card.dart';
import 'package:fi/reset_dialog.dart';
import 'package:fi/status_time.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CollectionApp extends StatefulWidget {
  const CollectionApp({
    required this.bridge,
    required this.initializeRust,
    required this.dataDirProvider,
    this.setPlatformForeground,
    super.key,
  });

  final CollectionBridge bridge;
  final Future<void> Function() initializeRust;
  final Future<String> Function() dataDirProvider;
  final Future<void> Function(bool foreground)? setPlatformForeground;

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
  static const _platform = MethodChannel('fi/platform');

  @override
  void initState() {
    super.initState();
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
    await _setForeground(true);
    // Only after the core exists (bridge.initialize) and foreground is set, so
    // every call in DevicesController.start() succeeds and the aggregate
    // status reads Searching rather than Offline on a rootless device.
    if (controller.fatalError == null && !_devicesStarted) {
      _devicesStarted = true;
      await devices.start();
    }
  }

  /// Runs a confirmed dataset reset. The devices controller is restarted
  /// afterwards so its streams observe the reopened core rather than the one
  /// the bridge shut down.
  Future<void> _resetDataset() async {
    await controller.resetDataset();
    if (controller.fatalError != null) return;
    await _setForeground(true);
    _devicesStarted = true;
    await devices.restart();
  }

  Future<void> _confirmResetFromError(BuildContext context) async {
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          "This device's local data cannot be opened by this version of the "
          'app. Resetting it lets you create a new dataset or join one from '
          'another device.',
    );
    if (confirmed) await _resetDataset();
  }

  /// Deliberate escape from a recovery that no other device can complete.
  /// Never automatic: the user confirms abandoning the recorded root.
  Future<void> _confirmResetFromRecovery(BuildContext context) async {
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          'Recovery needs one of your other devices. Resetting instead '
          'abandons the dataset recorded on this device; if you own no other '
          'device holding it, the set-aside copy is kept on disk but this app '
          'cannot read it.',
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
    devices.dispose();
    controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setForeground(false));
    unawaited(widget.bridge.shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fi',
    debugShowCheckedModeBanner: false,
    theme: nocturneTheme(),
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const _CenteredSurface(
            key: Key('bootstrap-loading'),
            child: CircularProgressIndicator(),
          );
        }
        if (controller.fatalError case final message?) {
          return _CenteredSurface(
            key: const Key('bootstrap-error'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                if (controller.fatalSecureStoreLocked)
                  FilledButton.icon(
                    key: const Key('retry-after-unlock'),
                    onPressed: controller.retryingNetworking
                        ? null
                        : () => unawaited(controller.retryNetworking()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry after unlocking'),
                  )
                else if (controller.fatalResetResolvable)
                  FilledButton(
                    key: const Key('reset-dataset'),
                    onPressed: () => unawaited(_confirmResetFromError(context)),
                    child: const Text("Reset this device's data"),
                  )
                else
                  FilledButton(
                    key: const Key('retry-bootstrap'),
                    onPressed: () => unawaited(_start()),
                    child: const Text('Retry'),
                  ),
              ],
            ),
          );
        }
        final surface = switch (controller.state?.kind) {
          BootstrapKindDto.ready => CollectionShell(
            bridge: widget.bridge,
            devices: devices,
            onResetDataset: _resetDataset,
          ),
          BootstrapKindDto.needsDecision => OnboardingPage(
            controller: controller,
            devices: devices,
            onResetDataset: _resetDataset,
          ),
          BootstrapKindDto.joining => switch (controller.state?.recovery) {
            final recovery? when recovery.isActive => RecoverySurface(
              recovery: recovery,
              onResetDataset: () => _confirmResetFromRecovery(context),
            ),
            _ => JoiningSurface(devices: devices),
          },
          BootstrapKindDto.creating => const _CenteredSurface(
            child: CircularProgressIndicator(),
          ),
          _ => const _CenteredSurface(
            child: Text('The local collection service is unavailable.'),
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
                retryError: controller.networkingRetryError,
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

/// Explains why peer networking is off and offers the retry that resumes it.
/// A locked keyring names the keyring and the unlock, because that is the
/// action that fixes it; an unavailable store has no such action.
class _NetworkingDeferredBanner extends StatelessWidget {
  const _NetworkingDeferredBanner({
    required this.deferred,
    required this.retryError,
    required this.busy,
    required this.onRetry,
  });

  final NetworkingDeferredDto deferred;
  final String? retryError;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final locked = deferred.kind == NetworkingDeferredKindDto.secureStoreLocked;
    return MaterialBanner(
      key: const Key('networking-deferred-banner'),
      leading: Icon(locked ? Icons.lock_outline : Icons.cloud_off),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            locked
                ? 'Your login keyring is locked, so this device cannot reach '
                      'your other devices. Unlock the keyring, then retry. '
                      'Everything stored here still works.'
                : deferred.message,
            key: const Key('networking-deferred-message'),
          ),
          if (retryError case final message?) ...[
            const SizedBox(height: 8),
            Text(message, key: const Key('networking-retry-error')),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('retry-networking'),
          onPressed: busy ? null : onRetry,
          child: const Text('Retry'),
        ),
      ],
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

extension RecoveryDtoState on RecoveryDto {
  /// Whether the dataset is still being recovered (or waiting for a device
  /// that can supply it), as opposed to a completed or decided recovery.
  bool get isActive =>
      outcome == RecoveryOutcomeDto.recovering ||
      outcome == RecoveryOutcomeDto.noPeerAvailable;
}

/// Shown instead of an indeterminate spinner or a fatal error while a lost
/// or corrupt root snapshot is being recovered from the user's other devices.
/// States plainly when another device is required, and never offers to
/// create a new dataset as a fallback: that would split from the recorded
/// root and never merge again.
class RecoverySurface extends StatelessWidget {
  const RecoverySurface({
    required this.recovery,
    required this.onResetDataset,
    super.key,
  });
  final RecoveryDto recovery;
  final Future<void> Function() onResetDataset;

  @override
  Widget build(BuildContext context) {
    final root = recovery.rootId;
    final rootLabel = root == null ? '' : ' (${_shortRootId(root)})';
    return switch (recovery.outcome) {
      RecoveryOutcomeDto.noPeerAvailable => _CenteredSurface(
        key: const Key('recovery-no-peer'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.devices_other, size: 48),
              const SizedBox(height: 12),
              Text(
                'Recovery needs another device',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'This device lost its local copy of your dataset$rootLabel. '
                'None of your other devices is reachable right now. Bring '
                'one of them online and recovery continues automatically; '
                'no pairing is needed.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('recovery-reset-dataset'),
                onPressed: () => unawaited(onResetDataset()),
                child: const Text("Reset this device's data instead"),
              ),
            ],
          ),
        ),
      ),
      _ => _CenteredSurface(
        key: const Key('recovery-recovering'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Recovering your dataset from your other devices$rootLabel…',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              switch (recovery.reason) {
                RecoveryReasonDto.rootSnapshotCorrupt =>
                  'The local copy could not be read and was set aside. '
                      'Nothing was deleted.',
                _ => 'The local copy was missing. Nothing was deleted.',
              },
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    };
  }
}

String _shortRootId(String id) =>
    id.length <= 8 ? id : '${id.substring(0, 8)}…';

/// Shown while a received root is being joined. Names the provisioning device
/// when the pairing session that started the join is still known.
class JoiningSurface extends StatelessWidget {
  const JoiningSurface({required this.devices, super.key});
  final DevicesController devices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: devices,
    builder: (context, _) => _CenteredSurface(
      key: const Key('joining-surface'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(switch (devices.peerName) {
            final name? => 'Joining dataset from $name…',
            null => 'Waiting for this local dataset to become available.',
          }, textAlign: TextAlign.center),
        ],
      ),
    ),
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
  bool showPairing = false;

  bool get _pairingActive => widget.devices.pairing.kind != PairingKindDto.idle;

  Future<void> _create() async {
    // Unconditional, not gated on the observed pairing state: the stream may
    // not have delivered an open window yet. A window advertises the root state
    // captured when it opened, so it must be closed before a root exists or a
    // peer may provision against a state that no longer holds. Stopping from
    // idle is a no-op in Rust.
    await widget.devices.stopPairing();
    await widget.controller.createNewDataset();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.devices,
    builder: (context, _) {
      final controller = widget.controller;
      final createBlocked = controller.creating || _pairingActive;
      return Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Your private collection space',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Create a new local dataset, or join the dataset on one of '
                    'your other devices. Nothing is sent to a server.',
                  ),
                  if (controller.state?.recovery case final recovery?
                      when recovery.outcome ==
                          RecoveryOutcomeDto.quarantined) ...[
                    const SizedBox(height: 16),
                    const MaterialBanner(
                      key: Key('recovery-quarantined'),
                      content: Text(
                        'Data found on this device was set aside because its '
                        'dataset record was missing. Nothing was deleted: '
                        'joining the same dataset from another device '
                        'restores it.',
                      ),
                      actions: [SizedBox.shrink()],
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('create-dataset'),
                    onPressed: createBlocked ? null : _create,
                    icon: const Icon(Icons.add_circle_outline),
                    label: Text(
                      controller.creating ? 'Creating…' : 'Create new dataset',
                    ),
                  ),
                  if (_pairingActive) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Creating is unavailable while pairing is active. '
                      'Stop pairing to create a new dataset here.',
                      key: Key('create-blocked-reason'),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('join-dataset'),
                    onPressed: controller.creating
                        ? null
                        : () => setState(() => showPairing = !showPairing),
                    icon: Icon(showPairing ? Icons.expand_less : Icons.link),
                    label: const Text('Join an existing dataset'),
                  ),
                  if (showPairing) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'The other device must already have a dataset. Start '
                      'pairing on both devices, then tap Connect on one device '
                      'only.',
                      key: Key('pairing-preconditions'),
                    ),
                    const SizedBox(height: 12),
                    if (widget.devices.errorMessage case final error?)
                      _ErrorBanner(error),
                    PairingCard(
                      controller: widget.devices,
                      onResetDataset: widget.onResetDataset,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class CollectionShell extends StatefulWidget {
  const CollectionShell({
    required this.bridge,
    required this.devices,
    this.onResetDataset,
    super.key,
  });
  final CollectionBridge bridge;
  final DevicesController devices;
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
    controller = CollectionsController(widget.bridge);
    unawaited(controller.start());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _select(int value) => setState(() => selected = value);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, devices]),
    builder: (context, _) {
      final page = IndexedStack(
        index: selected,
        children: [
          CollectionsPage(controller: controller),
          DevicesPage(
            controller: devices,
            onResetDataset: widget.onResetDataset,
          ),
        ],
      );
      if (MediaQuery.sizeOf(context).width >= 720) {
        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(
                selected: selected,
                onSelected: _select,
                devices: devices,
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
        ),
        1 => const _MobileTopRow(),
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
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.grid_view_outlined),
                label: 'Collections',
              ),
              NavigationDestination(
                icon: Icon(Icons.devices_outlined),
                label: 'Devices',
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The wide-layout navigation: brand, destinations, and the aggregate sync status at the foot.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selected,
    required this.onSelected,
    required this.devices,
  });

  final int selected;
  final ValueChanged<int> onSelected;
  final DevicesController devices;

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
          icon: Icons.grid_view_outlined,
          label: 'Collections',
          selected: selected == 0,
          onTap: () => onSelected(0),
        ),
        const SizedBox(height: 4),
        _NavRow(
          icon: Icons.devices_outlined,
          label: 'Devices',
          selected: selected == 1,
          onTap: () => onSelected(1),
        ),
        const Spacer(),
        _SidebarStatus(devices: devices),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
  const _SidebarStatus({required this.devices});
  final DevicesController devices;

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
    return Container(
      key: const Key('app-bar-sync-status'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Nocturne.radius),
        border: Border.all(color: Nocturne.neutral800),
      ),
      child: Row(
        children: [
          _StatusDot(status: devices.syncStatus),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _statusText(devices.syncStatus),
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
                Text(
                  '${trusted.length} paired · '
                  '${reachable == 0 ? 'none nearby' : '$reachable connected'}',
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

/// The aggregate status as a dot: lit while the device is reaching peers, dim when offline.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, this.size = 8, this.ring = true});
  final SyncStatusDto status;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) => switch (status) {
    SyncStatusDto.offline => GlowDot(
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
  const _MobileTopRow({this.status});
  final SyncStatusDto? status;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
    child: Row(
      children: [
        const FiLogoTile(),
        const Spacer(),
        if (status case final status?)
          Row(
            key: const Key('app-bar-sync-status'),
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusDot(status: status, size: 7, ring: false),
              const SizedBox(width: 6),
              Text(
                _statusText(status),
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
              ),
            ],
          ),
      ],
    ),
  );
}

String _statusText(SyncStatusDto status) => switch (status) {
  SyncStatusDto.offline => 'Offline',
  // Not "Searching": that word belongs to pairing discovery on the pairing card, and the
  // aggregate status is already `Searching` at boot before the user has touched pairing.
  SyncStatusDto.searching => 'Looking for paired devices',
  SyncStatusDto.connected => 'Connected',
  SyncStatusDto.syncing => 'Syncing',
  SyncStatusDto.synced => 'Synced',
  SyncStatusDto.error => 'Error',
};

/// One distinct icon per aggregate status, so the state is readable without the label.
IconData _statusIcon(SyncStatusDto status) => switch (status) {
  SyncStatusDto.offline => Icons.cloud_off,
  SyncStatusDto.searching => Icons.radar,
  SyncStatusDto.connected => Icons.link,
  SyncStatusDto.syncing => Icons.sync,
  SyncStatusDto.synced => Icons.cloud_done,
  SyncStatusDto.error => Icons.error_outline,
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

  @override
  Widget build(BuildContext context) {
    // `clock` rather than `DateTime.now()` so widget tests can advance time.
    final now = clock.now();
    final phone = MediaQuery.sizeOf(context).width < 720;
    final theme = Theme.of(context);
    final trusted = controller.devices;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Reset this device's data",
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text(
          'Abandon the dataset here to create a new one or join '
          "another device's. Your device identity is kept.",
          style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
        ),
      ],
    );
    final button = OutlinedButton.icon(
      key: const Key('reset-dataset'),
      onPressed: controller.busy ? null : () => _resetDataset(context),
      icon: const Icon(Icons.restart_alt),
      label: const Text('Reset data…'),
    );
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
                  'Devices',
                  style: phone
                      ? theme.textTheme.headlineSmall
                      : theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                if (!phone)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Devices you trust sync this dataset directly with each other.',
                      style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
                    ),
                  ),
                _SyncChip(status: controller.syncStatus),
                const SizedBox(height: 22),
                if (controller.errorMessage case final error?)
                  _ErrorBanner(error),
                if (controller.rotationError case final error?)
                  MaterialBanner(
                    key: const Key('rotation-error'),
                    content: Text(
                      'The device was revoked, but the discovery secret could not be '
                      'rotated: $error',
                    ),
                    actions: [
                      TextButton(
                        key: const Key('retry-rotation'),
                        onPressed: controller.busy
                            ? null
                            : controller.retryRotation,
                        child: const Text('Retry rotation'),
                      ),
                    ],
                  ),
                PairingCard(
                  controller: controller,
                  onResetDataset: onResetDataset,
                ),
                const SizedBox(height: 26),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    const SectionLabel('Trusted devices'),
                    const SizedBox(width: 10),
                    Text(
                      '${trusted.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Nocturne.muted(.45),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (trusted.isEmpty)
                  Text(
                    'No devices have been paired yet.',
                    style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
                  )
                else
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
                if (onResetDataset != null) ...[
                  const SizedBox(height: 26),
                  const SectionLabel('This device'),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Nocturne.radius),
                      border: Border.all(color: Nocturne.divider),
                    ),
                    child: phone
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              info,
                              const SizedBox(height: 12),
                              button,
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: info),
                              const SizedBox(width: 16),
                              button,
                            ],
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One trusted device (mocks 1b, 2i): kind tile, name with its connection tag, the id in mono
  /// with when it was last seen and synced, and its actions.
  Widget _deviceRow(
    BuildContext context,
    TrustedDeviceDto device,
    DateTime now, {
    required bool phone,
  }) => Padding(
    key: Key('device-${device.deviceId}'),
    padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
    child: Row(
      children: [
        IconTile(
          device.revoked ? Icons.block : Icons.devices_other,
          fill: Nocturne.neutral800,
          color: Nocturne.text,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      device.friendlyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  switch ((device.revoked, device.connection)) {
                    (true, _) => const Tag.neutral('Revoked'),
                    (
                      _,
                      PeerConnectionKindDto.offline ||
                          PeerConnectionKindDto.error,
                    ) =>
                      Tag.neutral(_connectionText(device.connection)),
                    _ => Tag(_connectionText(device.connection)),
                  },
                ],
              ),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(
                  children: [
                    if (!phone) ...[
                      TextSpan(
                        text: _shortDeviceId(device.deviceId),
                        style: const TextStyle(fontFamily: Nocturne.monoFamily),
                      ),
                      const TextSpan(text: ' · '),
                    ],
                    TextSpan(
                      text:
                          'Last seen ${formatStatusTime(device.lastSeenMs, now: now)} · '
                          'Last sync ${formatStatusTime(device.lastSyncMs, now: now)}',
                    ),
                  ],
                ),
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            if (action == 'rename') _renameDevice(context, device);
            if (action == 'revoke') _revokeDevice(context, device);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            if (!device.revoked)
              const PopupMenuItem(
                value: 'revoke',
                child: Text('Revoke / unpair'),
              ),
          ],
        ),
      ],
    ),
  );

  Future<void> _resetDataset(BuildContext context) async {
    final action = onResetDataset;
    if (action == null) return;
    final trusted = controller.devices
        .where((device) => !device.revoked)
        .length;
    final confirmed = await ResetDatasetDialog.show(
      context,
      lead:
          'You are about to abandon the dataset on this device and return to '
          'onboarding.',
      trustedDeviceCount: trusted,
    );
    if (confirmed) await action();
  }

  Future<void> _renameDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    var name = device.friendlyName;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename device'),
        content: FiTextInput(
          key: const Key('device-name'),
          initialValue: name,
          onChanged: (value) => name = value,
          autofocus: true,
          label: 'Friendly name',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await controller.rename(device, name);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeDevice(
    BuildContext context,
    TrustedDeviceDto device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Revoke ${device.friendlyName}?'),
        content: const Text(
          'This device will be disconnected and will no longer be trusted. '
          'Its record is retained as revoked.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.revoke(device);
  }
}

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.status});
  final SyncStatusDto status;
  @override
  Widget build(BuildContext context) => Row(
    key: const Key('sync-status'),
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(_statusIcon(status), size: 14, color: Nocturne.accent),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          _statusText(status),
          style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
        ),
      ),
    ],
  );
}

String _shortDeviceId(String id) => id.length <= 16
    ? id
    : '${id.substring(0, 8)}…${id.substring(id.length - 8)}';
String _connectionText(PeerConnectionKindDto state) => switch (state) {
  PeerConnectionKindDto.offline => 'Offline',
  PeerConnectionKindDto.searching => 'Searching',
  PeerConnectionKindDto.connected => 'Connected',
  PeerConnectionKindDto.syncing => 'Syncing',
  PeerConnectionKindDto.synced => 'Synced',
  PeerConnectionKindDto.error => 'Error',
};

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => MaterialBanner(
    content: Text(message),
    actions: const [SizedBox.shrink()],
  );
}
