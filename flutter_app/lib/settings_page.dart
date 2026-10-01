import 'dart:async';

import 'package:fi/build_label.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/l10n/language.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/models_card.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

/// The Network row of About; mirrors `DEFAULT_SYNC_PORT_RANGE` in
/// `crates/app_core/src/application.rs` and mDNS on 5353.
String networkSummary(AppLocalizations l) =>
    l.settingsNetworkSummary(47380, 47389, 5353);

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
    // In display order.
    final sections = <_Section>[
      (label: context.l10n.settingsLanguage, child: const _LanguageSection()),
      if (voiceShown)
        (
          label: context.l10n.settingsVoiceInput,
          child: _VoiceInputSection(services: voice),
        ),
      if (micShown && services != null)
        (label: context.l10n.settingsMicrophone, child: _microphone(services)),
      (label: context.l10n.settingsAbout, child: _about()),
    ];
    return ListView(
      key: const Key('settings-page'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text(
          context.l10n.settingsTitle,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        if (!caps.android)
          Text(
            context.l10n.settingsSubtitle,
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
          _AboutRow(
            label: context.l10n.settingsVersion,
            value: BuildLabel(info),
          ),
          const FadedRule(),
        ],
        _AboutRow(
          key: const Key('settings-network'),
          label: context.l10n.settingsNetwork,
          detail: networkSummary(context.l10n),
        ),
      ],
    ),
  );

  Widget _microphone(VoiceServices services) {
    final l = context.l10n;
    final (text, detail) = switch (_permission) {
      MicPermission.granted => (l.settingsMicAllowed, null),
      MicPermission.notGranted => (
        l.settingsMicNotAllowed,
        l.settingsMicAsksFirst,
      ),
      MicPermission.permanentlyDenied => (
        l.settingsMicOff,
        l.settingsMicTurnOn,
      ),
      null => (_permissionKnown ? l.settingsMicUnknown : '…', null),
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
              Expanded(child: Text(l.settingsMicAccess)),
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
              child: Text(l.settingsAndroidSettings),
            ),
          ),
        ],
      ),
    );
  }
}

/// The interface language (mocks 8a, 8b): a dropdown on desktop, a radio list
/// on Android. With on-device voice, a line or offer about voice input
/// follows the choices (mocks 8b, 8c).
class _LanguageSection extends StatefulWidget {
  const _LanguageSection();

  @override
  State<_LanguageSection> createState() => _LanguageSectionState();
}

class _LanguageSectionState extends State<_LanguageSection> {
  /// The language code whose speech model offer was dismissed.
  String? _offerDismissedFor;

  static Key _optionKey(AppLanguage language) => Key(
    'language-option-${language == AppLanguage.system ? 'system' : language.code}',
  );

  @override
  Widget build(BuildContext context) {
    final controller = LanguageScope.of(context);
    final l = context.l10n;
    final systemName = languageEndonym(
      resolveAppLocale(
        WidgetsBinding.instance.platformDispatcher.locales,
        AppLocalizations.supportedLocales,
      ).languageCode,
    );
    void choose(AppLanguage? value) {
      if (value != null) unawaited(controller.set(value));
    }

    String name(AppLanguage language) => switch (language) {
      AppLanguage.system => l.langSystemDefaultNamed(systemName),
      AppLanguage.english => languageEndonym('en'),
      AppLanguage.spanish => languageEndonym('es'),
    };

    final services = VoiceScope.of(context);
    final voice = PlatformScope.of(context).onDeviceVoice && services != null
        ? _voice(services)
        : null;
    if (!PlatformScope.of(context).android) {
      return NocturneCard(
        key: const Key('settings-language'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Text(l.langAppLanguage),
            Text(
              l.langAppLanguageHint,
              style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
            ),
            DropdownButton<AppLanguage>(
              isExpanded: true,
              key: const Key('settings-language-dropdown'),
              value: controller.value,
              onChanged: choose,
              items: [
                for (final language in AppLanguage.values)
                  DropdownMenuItem(
                    key: _optionKey(language),
                    value: language,
                    child: Text(name(language)),
                  ),
              ],
            ),
            if (voice != null) ...[const FadedRule(), voice],
          ],
        ),
      );
    }
    return NocturneCard(
      key: const Key('settings-language'),
      padding: EdgeInsets.zero,
      child: RadioGroup<AppLanguage>(
        groupValue: controller.value,
        onChanged: choose,
        child: Column(
          children: [
            for (final language in AppLanguage.values)
              RadioListTile<AppLanguage>(
                key: _optionKey(language),
                value: language,
                title: Text(
                  language == AppLanguage.system
                      ? l.langSystemDefault
                      : name(language),
                ),
                subtitle: language == AppLanguage.system
                    ? Text(l.langSameAsPhone(systemName))
                    : null,
              ),
            if (voice != null) ...[
              const FadedRule(indent: 16),
              Padding(padding: const EdgeInsets.all(16), child: voice),
            ],
          ],
        ),
      ),
    );
  }

  /// The voice input line, or the offer to download the speech model the
  /// app language needs.
  Widget _voice(VoiceServices services) => ListenableBuilder(
    listenable: Listenable.merge([
      services.models,
      services.languageListenable,
    ]),
    builder: (context, _) {
      final l = context.l10n;
      final lang = services.language;
      final status = services.models.status;
      final muted = TextStyle(fontSize: 13, color: Nocturne.muted(.6));
      if (status.kind == ModelStatusKindDto.ready) {
        return Text(
          l.langVoiceReady(lang),
          key: const Key('language-voice-line'),
          style: muted,
        );
      }
      if (!speechModelMissing(status) || _offerDismissedFor == lang) {
        return Text(
          l.langVoiceFollows,
          key: const Key('language-voice-line'),
          style: muted,
        );
      }
      int sizeOf(ModelRoleDto role) =>
          status.files
              .where((file) => file.role == role)
              .firstOrNull
              ?.sizeBytes ??
          0;
      return Container(
        key: const Key('language-voice-offer'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Nocturne.bg,
          borderRadius: BorderRadius.circular(Nocturne.radius),
          border: Border.all(color: Nocturne.accent700),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Text(
              l.langVoiceOfferTitle(
                lang,
                formatBytes(sizeOf(ModelRoleDto.speech)),
              ),
            ),
            Text(
              l.langVoiceOfferBody(
                formatBytes(sizeOf(ModelRoleDto.understanding)),
              ),
              style: muted,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('language-voice-offer-later'),
                  onPressed: () => setState(() => _offerDismissedFor = lang),
                  child: Text(l.voiceNotNow),
                ),
                FilledButton(
                  key: const Key('language-voice-offer-download'),
                  onPressed: () => unawaited(
                    _runModelAction(context, services.models.start),
                  ),
                  child: Text(l.langVoiceDownload),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// Runs a model action, reporting a [ModelErrorDto] in a snackbar.
Future<void> _runModelAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l10n;
  try {
    await action();
  } on ModelErrorDto catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(switch (error.kind) {
          ModelErrorKindDto.notEnoughStorage => l.settingsNotEnoughStorage(
            formatBytes(error.neededBytes ?? 0),
          ),
          ModelErrorKindDto.voiceTurnActive => l.settingsFinishVoiceFirst,
          _ => l.settingsCouldntChangeModels,
        }),
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

  Future<void> _run(BuildContext context, Future<void> Function() action) =>
      _runModelAction(context, action);

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
            if (speechModelMissing(status))
              if (status.files
                      .where((file) => file.role == ModelRoleDto.speech)
                      .firstOrNull
                  case final speech?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    context.l10n.voiceNeedsSpeechModel(
                      languageEndonym(status.language),
                      status.language,
                      formatBytes(speech.sizeBytes),
                    ),
                    key: const Key('settings-voice-needs-model'),
                    style: TextStyle(fontSize: 13, color: Nocturne.muted(.7)),
                  ),
                ),
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
                          Text(context.l10n.settingsHandsFree),
                          Text(
                            context.l10n.settingsHandsFreeDetail,
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
                      label: context.l10n.settingsHandsFree,
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
                label: context.l10n.modelRedownload,
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
                label: context.l10n.modelDelete,
                detail: context.l10n.modelFrees(size),
                onTap: () async {
                  if (!await showDeleteModelsDialog(
                    context,
                    modelDeleteBytes(status),
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
                context.l10n.voicePrivacyLine,
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
