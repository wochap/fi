import 'dart:async';

import 'package:fi/build_label.dart';
import 'package:fi/l10n/l10n.dart';
import 'package:fi/l10n/language.dart';
import 'package:fi/platform_capabilities.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/inputs.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/ui_prefs.dart';
import 'package:fi/voice/models_card.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The Network row of About; mirrors `DEFAULT_SYNC_PORT_RANGE` in
/// `crates/app_core/src/application.rs` and mDNS on 5353.
String networkSummary(AppLocalizations l) =>
    l.settingsNetworkSummary(47380, 47389, 5353);

typedef _Section = ({String label, Widget child});

/// Settings (mock settings): sections chosen by platform capability.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.buildInfo,
    this.localAddresses = const [],
    super.key,
  });

  /// The build identity for About, when known.
  final BuildInfoDto? buildInfo;

  /// This device's sync addresses as `ip:port`, for About › This device.
  final List<String> localAddresses;

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
    final phone = MediaQuery.sizeOf(context).width < 720;
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
                  context.l10n.settingsTitle,
                  style: phone
                      ? Theme.of(context).textTheme.headlineSmall
                      : Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
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
            ),
          ),
        ),
      ],
    );
  }

  Widget _about() {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final thisDevice = _ThisDeviceAddresses(addresses: widget.localAddresses);
    return NocturneCard(
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
          if (wide)
            _AboutRow(
              key: const Key('settings-this-device'),
              label: context.l10n.aboutThisDevice,
              value: thisDevice,
            )
          else
            Padding(
              key: const Key('settings-this-device'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [Text(context.l10n.aboutThisDevice), thisDevice],
              ),
            ),
          const FadedRule(),
          _AboutRow(
            key: const Key('settings-network'),
            label: context.l10n.settingsNetwork,
            detail: networkSummary(context.l10n),
          ),
        ],
      ),
    );
  }

  Widget _microphone(VoiceServices services) {
    final l = context.l10n;
    final (text, detail, icon) = switch (_permission) {
      MicPermission.granted => (
        l.settingsMicAllowed,
        null,
        const Icon(FiIcons.allowed, size: 16, color: Nocturne.accent200),
      ),
      MicPermission.notGranted => (
        l.settingsMicNotAllowed,
        l.settingsMicAsksFirst,
        Icon(FiIcons.notAllowedYet, size: 16, color: Nocturne.muted(.7)),
      ),
      MicPermission.permanentlyDenied => (
        l.settingsMicOff,
        l.settingsMicTurnOn,
        Icon(FiIcons.blocked, size: 16, color: Nocturne.muted(.7)),
      ),
      null => (_permissionKnown ? l.settingsMicUnknown : '…', null, null),
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
              if (icon != null) ...[icon, const SizedBox(width: 6)],
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
            child: OutlinedButton.icon(
              key: const Key('settings-android-settings'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, Nocturne.touchTarget),
              ),
              onPressed: () => unawaited(services.permission.openSettings()),
              icon: const Icon(FiIcons.systemSettings, size: 16),
              label: Text(l.settingsAndroidSettings),
            ),
          ),
        ],
      ),
    );
  }
}

/// The interface language (mock settings): a dropdown on desktop, a radio list
/// on Android. With on-device voice, a line or offer about voice input
/// follows the choices (mocks settings, settings-language).
class _LanguageSection extends StatefulWidget {
  const _LanguageSection();

  @override
  State<_LanguageSection> createState() => _LanguageSectionState();
}

class _LanguageSectionState extends State<_LanguageSection> {
  /// Card width from which the dropdown sits beside the label instead of below it.
  static const _wideLanguageWidth = 560.0;

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
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Text(l.langAppLanguage),
          Text(
            l.langAppLanguageHint,
            style: TextStyle(fontSize: 13, color: Nocturne.muted(.6)),
          ),
        ],
      );
      final dropdown = FiSelect<AppLanguage>(
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
      );
      return NocturneCard(
        key: const Key('settings-language'),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideLanguageWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: [
                if (wide)
                  Row(
                    spacing: 24,
                    children: [
                      Expanded(child: label),
                      SizedBox(width: 280, child: dropdown),
                    ],
                  )
                else ...[
                  label,
                  dropdown,
                ],
                if (voice != null) ...[const FadedRule(), voice],
              ],
            );
          },
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

/// The network an About address belongs to: "Tailnet" for 100.64.0.0/10,
/// "LAN" for anything else, including a host that is not IPv4.
String addressNetwork(AppLocalizations l, String address) {
  final octets = address.split(':').first.split('.');
  final a = octets.length == 4 ? int.tryParse(octets[0]) : null;
  final b = octets.length == 4 ? int.tryParse(octets[1]) : null;
  final tailnet = a == 100 && b != null && b >= 64 && b <= 127;
  return tailnet ? l.aboutNetworkTailnet : l.aboutNetworkLan;
}

/// About › This device (mock settings-about): one line per address with its
/// network label and a copy action that confirms inline.
class _ThisDeviceAddresses extends StatefulWidget {
  const _ThisDeviceAddresses({required this.addresses});

  final List<String> addresses;

  @override
  State<_ThisDeviceAddresses> createState() => _ThisDeviceAddressesState();
}

class _ThisDeviceAddressesState extends State<_ThisDeviceAddresses> {
  static const _confirmFor = Duration(seconds: 2);

  String? _copied;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _copied = address);
    _timer = Timer(_confirmFor, () {
      if (mounted) setState(() => _copied = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final muted = TextStyle(fontSize: 12, color: Nocturne.muted(.55));
    if (widget.addresses.isEmpty) {
      return Text(
        l.aboutNotOnLocalNetwork,
        style: TextStyle(fontSize: 13, color: Nocturne.muted(.55)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final addr in widget.addresses)
          ConstrainedBox(
            key: Key('settings-address-$addr'),
            constraints: const BoxConstraints(minHeight: Nocturne.touchTarget),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(addressNetwork(l, addr), style: muted),
                ),
                Flexible(
                  child: SelectableText(
                    addr,
                    maxLines: 1,
                    style: const TextStyle(
                      fontFamily: Nocturne.monoFamily,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (_copied == addr)
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        const Icon(
                          FiIcons.check,
                          size: 16,
                          color: Nocturne.accent200,
                        ),
                        Text(
                          l.aboutAddressCopied,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Nocturne.accent200,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  IconButton(
                    key: Key('settings-copy-address-$addr'),
                    tooltip: l.aboutCopyAddress,
                    icon: const Icon(FiIcons.copy, size: 16),
                    onPressed: () => unawaited(_copy(addr)),
                  ),
              ],
            ),
          ),
      ],
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
        if (value case final value?) Flexible(child: value),
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
      final muted = TextStyle(fontSize: 12, color: Nocturne.muted(.55));
      return Column(
        key: const Key('settings-voice'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (speechModelMissing(status))
            if (status.files
                    .where((file) => file.role == ModelRoleDto.speech)
                    .firstOrNull
                case final speech?)
              Text(
                context.l10n.voiceNeedsSpeechModel(
                  languageEndonym(status.language),
                  status.language,
                  formatBytes(speech.sizeBytes),
                ),
                key: const Key('settings-voice-needs-model'),
                style: TextStyle(fontSize: 13, color: Nocturne.muted(.7)),
              ),
          NocturneCard(
            key: const Key('settings-voice-models'),
            child: VoiceModelsCard(
              models: models,
              run: (action) => _run(context, action),
            ),
          ),
          Text(
            context.l10n.voicePrivacyLine,
            key: const Key('settings-voice-privacy'),
            style: muted,
          ),
          if (models.ready)
            NocturneCard(
              key: const Key('settings-hands-free-card'),
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
                          style: muted,
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
        ],
      );
    },
  );
}
