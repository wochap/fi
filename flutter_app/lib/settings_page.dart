import 'dart:async';

import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

/// The phone Settings tab (mock 7i): Voice input, Microphone and About.
class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.buildLabel, super.key});

  /// The build label for About, when the build identity is known.
  final Widget? buildLabel;

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
    final service = VoiceScope.scopeOf(context)?.services?.permission;
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
    final services = VoiceScope.scopeOf(context)?.services;
    final voice = VoiceScope.of(context);
    return ListView(
      key: const Key('settings-page'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        if (voice != null) ...[
          const SizedBox(height: 22),
          const SectionLabel('Voice input'),
          const SizedBox(height: 10),
          _VoiceInputSection(services: voice),
        ],
        if (services != null) ...[
          const SizedBox(height: 26),
          const SectionLabel('Microphone'),
          const SizedBox(height: 10),
          _microphone(services),
        ],
        if (widget.buildLabel case final label?) ...[
          const SizedBox(height: 26),
          const SectionLabel('About'),
          const SizedBox(height: 10),
          NocturneCard(
            key: const Key('settings-about'),
            child: Row(
              children: [
                const Expanded(child: Text('Build')),
                label,
              ],
            ),
          ),
        ],
      ],
    );
  }

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

class _VoiceInputSection extends StatelessWidget {
  const _VoiceInputSection({required this.services});

  final VoiceServices services;

  VoiceModels get models => services.models;

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    required Key key,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: key,
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

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
            _ => "Couldn't change the voice model. Try again.",
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
      final ready = status.kind == ModelStatusKindDto.ready;
      return NocturneCard(
        key: const Key('settings-voice'),
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: _modelRow(context, status, size),
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
                label: 'Re-download model',
                detail: size,
                onTap: () async {
                  if (!await _confirm(
                    context,
                    title: 'Re-download voice model?',
                    body: 'The model is deleted and downloaded again ($size).',
                    action: 'Re-download',
                    key: const Key('confirm-redownload'),
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
                label: 'Delete model',
                detail: 'frees $size',
                onTap: () async {
                  if (!await _confirm(
                    context,
                    title: 'Delete voice model?',
                    body:
                        'This frees $size. Voice fill needs it downloaded again.',
                    action: 'Delete',
                    key: const Key('confirm-delete-model'),
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

  Widget _modelRow(BuildContext context, ModelStatusDto status, String size) {
    final header = Row(
      children: [
        const Icon(FiIcons.waveform, size: 20, color: Nocturne.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              const Text('Voice model'),
              Text(
                'English · $size',
                key: const Key('settings-model-size'),
                style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
              ),
            ],
          ),
        ),
        switch (status.kind) {
          ModelStatusKindDto.ready => Container(
            key: const Key('settings-model-ready'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Nocturne.accent900,
              borderRadius: BorderRadius.circular(Nocturne.radiusLg),
              border: Border.all(color: Nocturne.accent700),
            ),
            child: const Text(
              'Ready',
              style: TextStyle(fontSize: 11, color: Nocturne.accent100),
            ),
          ),
          ModelStatusKindDto.downloading ||
          ModelStatusKindDto.paused => IconButton(
            key: const Key('settings-model-pause'),
            tooltip: status.kind == ModelStatusKindDto.paused
                ? 'Resume download'
                : 'Pause download',
            onPressed: () => unawaited(
              status.kind == ModelStatusKindDto.paused
                  ? _run(context, models.start)
                  : models.pause(),
            ),
            icon: Icon(
              status.kind == ModelStatusKindDto.paused
                  ? FiIcons.download
                  : FiIcons.pause,
              size: 18,
            ),
          ),
          _ => Text(
            'Not downloaded',
            key: const Key('settings-model-missing'),
            style: TextStyle(fontSize: 12, color: Nocturne.muted(.6)),
          ),
        },
      ],
    );
    final progress = status.totalBytes == 0
        ? 0.0
        : status.doneBytes / status.totalBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        header,
        if (status.kind == ModelStatusKindDto.downloading ||
            status.kind == ModelStatusKindDto.paused) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              color: Nocturne.accent,
              backgroundColor: Nocturne.neutral700,
            ),
          ),
          Text(
            '${formatBytes(status.doneBytes)} of $size · ${(progress * 100).floor()}%'
            '${status.kind == ModelStatusKindDto.paused ? ' · Paused' : ''}',
            key: const Key('settings-model-progress'),
            style: TextStyle(
              fontSize: 12,
              color: Nocturne.muted(.6),
              fontFeatures: Nocturne.tabular,
            ),
          ),
        ],
        if (status.kind == ModelStatusKindDto.notDownloaded ||
            status.kind == ModelStatusKindDto.failed)
          Row(
            children: [
              FilledButton.icon(
                key: const Key('settings-model-download'),
                onPressed: () => unawaited(_run(context, models.start)),
                icon: const Icon(FiIcons.download, size: 18),
                label: Text('Download ${formatBytes(status.remainingBytes)}'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  status.kind == ModelStatusKindDto.failed
                      ? "The last download didn't finish."
                      : 'Wi-Fi recommended',
                  style: TextStyle(fontSize: 12, color: Nocturne.muted(.55)),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
