import 'dart:async';

import 'package:fi/build_label.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/voice/model_strings.dart';
import 'package:fi/voice/models_card.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

/// The Network row of About; mirrors `DEFAULT_SYNC_PORT_RANGE` in
/// `crates/app_core/src/application.rs` and mDNS on 5353.
const networkSummary = 'Local network only · UDP 47380–47389 · mDNS 5353';

typedef _Section = ({String label, Widget child});

/// Settings (mocks 8a, 8b): sections chosen by platform capability.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.buildInfo, super.key});

  /// The build identity for About, when known.
  final BuildInfoDto? buildInfo;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  MicPermission? _permission;
  var _permissionKnown = false;
  MicrophonePermission? _permissionService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The permission only matters where the Microphone section can show.
    final service = PlatformScope.of(context).android
        ? VoiceScope.scopeOf(context)?.services?.permission
        : null;
    if (service != _permissionService) {
      _permissionService = service;
      unawaited(_readPermission());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Returning from Android settings may have changed the permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_readPermission());
  }

  Future<void> _readPermission() async {
    final service = _permissionService;
    if (service == null) return;
    MicPermission? permission;
    try {
      permission = await service.status();
    } catch (_) {
      permission = null;
    }
    if (mounted) {
      setState(() {
        _permission = permission;
        _permissionKnown = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = PlatformScope.of(context);
    final services = VoiceScope.scopeOf(context)?.services;
    final voice = VoiceScope.of(context);
    final voiceShown = caps.onDeviceVoice && voice != null;
    final micShown = caps.android && voiceShown;
    // In display order; a new section (Language) is one more entry here.
    final sections = <_Section>[
      if (voiceShown)
        (label: 'Voice input', child: _VoiceInputSection(services: voice)),
      if (micShown && services != null)
        (label: 'Microphone', child: _microphone(services)),
      (label: 'About', child: _about()),
    ];
    return ListView(
      key: const Key('settings-page'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        if (!caps.android)
          Text(
            'Preferences for this computer.',
            key: const Key('settings-subtitle'),
            style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
          ),
        for (final (index, section) in sections.indexed) ...[
          SizedBox(height: index == 0 ? 22 : 26),
          SectionLabel(section.label),
          const SizedBox(height: 10),
          section.child,
        ],
      ],
    );
  }

  Widget _about() => NocturneCard(
    key: const Key('settings-about'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.buildInfo case final info?) ...[
          _AboutRow(label: 'Version', value: BuildLabel(info)),
          const FadedRule(),
        ],
        const _AboutRow(
          key: Key('settings-network'),
          label: 'Network',
          detail: networkSummary,
        ),
      ],
    ),
  );

  Widget _microphone(VoiceServices services) {
    final (text, detail) = switch (_permission) {
      MicPermission.granted => ('Allowed', null),
      MicPermission.notGranted => (
        'Not allowed yet',
        'Fi asks the first time you use voice.',
      ),
      MicPermission.permanentlyDenied => (
        'Off',
        'Turn it on in Android settings to fill by voice.',
      ),
      null => (_permissionKnown ? 'Unknown' : '…', null),
    };
    return NocturneCard(
      key: const Key('settings-microphone'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 6,
        children: [
          Row(
            children: [
              Icon(FiIcons.microphone, size: 18, color: Nocturne.muted(.7)),
              const SizedBox(width: 10),
              const Expanded(child: Text('Microphone access')),
              Text(
                text,
                key: const Key('settings-microphone-status'),
                style: TextStyle(fontSize: 13, color: Nocturne.muted(.7)),
              ),
            ],
          ),
          if (detail != null)
            Text(
              detail,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('settings-android-settings'),
              onPressed: () => unawaited(services.permission.openSettings()),
              child: const Text('Android settings'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One About row: label with an optional value, low-emphasis detail line and trailing widget.
class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.label,
    this.value,
    this.detail,
    // A trailing link (network docs) comes with a later change.
    // ignore: unused_element_parameter
    this.trailing,
    super.key,
  });

  final String label;
  final Widget? value;
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(label),
              if (detail case final detail?)
                Text(
                  detail,
                  style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
                ),
            ],
          ),
        ),
        ?value,
        ?trailing,
      ],
    ),
  );
}

class _VoiceInputSection extends StatelessWidget {
  const _VoiceInputSection({required this.services});

  final VoiceServices services;

  VoiceModels get models => services.models;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } on ModelErrorDto catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(switch (error.kind) {
            ModelErrorKindDto.notEnoughStorage =>
              'Not enough storage: ${formatBytes(error.neededBytes ?? 0)} needed.',
            ModelErrorKindDto.voiceTurnActive =>
              'Finish the voice fill in progress first.',
            _ => "Couldn't change the voice models. Try again.",
          }),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([models, services.prefs]),
    builder: (context, _) {
      final status = models.status;
      final size = formatBytes(status.totalBytes);
      final ready = models.ready;
      return NocturneCard(
        key: const Key('settings-voice'),
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: VoiceModelsCard(
                models: models,
                run: (action) => _run(context, action),
              ),
            ),
            if (ready) ...[
              const FadedRule(indent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          const Text('Hands-free spoken feedback'),
                          Text(
                            'Speaks the “still need” question and a short confirmation',
                            style: TextStyle(
                              fontSize: 12,
                              color: Nocturne.muted(.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Semantics(
                      label: 'Hands-free spoken feedback',
                      child: FiSwitch(
                        key: const Key('settings-hands-free'),
                        value: services.prefs.handsFree,
                        onChanged: (on) =>
                            unawaited(services.prefs.setHandsFree(on)),
                      ),
                    ),
                  ],
                ),
              ),
              const FadedRule(indent: 16),
              _actionRow(
                key: const Key('settings-redownload'),
                icon: FiIcons.refresh,
                label: ModelStrings.redownload,
                detail: size,
                onTap: () async {
                  if (!await showRedownloadModelsDialog(
                    context,
                    status.totalBytes,
                  )) {
                    return;
                  }
                  if (context.mounted) await _run(context, models.redownload);
                },
              ),
              const FadedRule(indent: 16),
              _actionRow(
                key: const Key('settings-delete-model'),
                icon: FiIcons.delete,
                label: ModelStrings.delete,
                detail: ModelStrings.frees(size),
                onTap: () async {
                  if (!await showDeleteModelsDialog(
                    context,
                    status.totalBytes,
                  )) {
                    return;
                  }
                  if (context.mounted) {
                    await _run(context, () async => models.delete());
                  }
                },
              ),
            ],
            const FadedRule(indent: 16),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Audio is processed on this device and never saved. English only for now.',
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _actionRow({
    required Key key,
    required IconData icon,
    required String label,
    required String detail,
    required VoidCallback onTap,
  }) => InkWell(
    key: key,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Nocturne.touchTarget + 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Nocturne.muted(.7)),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
            Text(
              detail,
              style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
            ),
          ],
        ),
      ),
    ),
  );
}
