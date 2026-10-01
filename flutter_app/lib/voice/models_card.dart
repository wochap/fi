import 'dart:async';

import 'package:fi/l10n/l10n.dart';
import 'package:fi/theme/fi_icons.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/voice/services.dart';
import 'package:flutter/material.dart';

TextStyle _muted(double opacity, [double size = 12]) =>
    TextStyle(fontSize: size, color: Nocturne.muted(opacity), height: 1.4);

/// The display name of a model role.
String modelRoleName(AppLocalizations l, ModelRoleDto role) => switch (role) {
  ModelRoleDto.speech => l.modelRoleSpeech,
  ModelRoleDto.understanding => l.modelRoleUnderstanding,
};

/// The models' language as shown in the UI; null covers all languages.
String modelLanguageName(AppLocalizations l, String? code) =>
    code == null ? l.modelAllLanguages : languageEndonym(code);

/// The failure title and line for a failed status.
(String, String) modelFailureText(AppLocalizations l, ModelStatusDto status) {
  final error = status.error;
  return switch (error?.kind) {
    ModelErrorKindDto.network ||
    ModelErrorKindDto.httpStatus => (l.modelNetworkTitle, l.modelNetworkLine),
    ModelErrorKindDto.notEnoughStorage => (
      l.modelStorageTitle,
      l.modelStorageLine(formatBytes(error?.neededBytes ?? 0)),
    ),
    ModelErrorKindDto.checksum => () {
      final file =
          status.files.where((file) => file.name == error?.file).firstOrNull ??
          status.files
              .where((file) => file.state == ModelFileStateDto.damaged)
              .firstOrNull;
      return (
        l.modelDamagedTitle,
        l.modelDamagedLine(switch (file?.role ?? ModelRoleDto.understanding) {
          ModelRoleDto.speech => l.modelRoleSpeechInSentence,
          ModelRoleDto.understanding => l.modelRoleUnderstandingInSentence,
        }, formatBytes(file?.sizeBytes ?? status.remainingBytes)),
      );
    }(),
    _ => (l.modelIoTitle, l.modelIoLine),
  };
}

/// Asks before cancelling (mock 8e). Destructive action left, safe right.
Future<bool> showCancelDownloadDialog(BuildContext context, int doneBytes) =>
    _confirm(
      context,
      title: context.l10n.modelCancelDialogTitle,
      body: context.l10n.modelCancelDialogBody(formatBytes(doneBytes)),
      destructive: context.l10n.modelCancelDialogConfirm,
      destructiveKey: const Key('confirm-cancel-download'),
      safe: context.l10n.modelCancelDialogKeep,
    );

/// Asks before deleting the models (mock 8e).
Future<bool> showDeleteModelsDialog(BuildContext context, int sizeBytes) =>
    _confirm(
      context,
      title: context.l10n.modelDeleteDialogTitle,
      body: context.l10n.modelDeleteDialogBody(formatBytes(sizeBytes)),
      destructive: context.l10n.commonDelete,
      destructiveKey: const Key('confirm-delete-model'),
      safe: context.l10n.modelKeepModels,
    );

/// Asks before re-downloading the models.
Future<bool> showRedownloadModelsDialog(BuildContext context, int sizeBytes) =>
    _confirm(
      context,
      title: context.l10n.modelRedownloadDialogTitle,
      body: context.l10n.modelRedownloadDialogBody(formatBytes(sizeBytes)),
      destructive: context.l10n.modelRedownloadDialogConfirm,
      destructiveKey: const Key('confirm-redownload'),
      safe: context.l10n.modelKeepModels,
    );

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String destructive,
  required Key destructiveKey,
  required String safe,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: destructiveKey,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(destructive),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(safe),
          ),
        ],
      ),
    ) ??
    false;

/// The Settings voice models card content (mocks 8b, 8d): header, one row
/// per model, and the body of the current state.
class VoiceModelsCard extends StatefulWidget {
  const VoiceModelsCard({required this.models, required this.run, super.key});

  final VoiceModels models;

  /// Runs a model action, reporting a [ModelErrorDto] to the user.
  final Future<void> Function(Future<void> Function() action) run;

  @override
  State<VoiceModelsCard> createState() => _VoiceModelsCardState();
}

class _VoiceModelsCardState extends State<VoiceModelsCard> {
  int? _freeBytes;

  VoiceModels get models => widget.models;

  @override
  void initState() {
    super.initState();
    unawaited(_readFree());
  }

  Future<void> _readFree() async {
    int? free;
    try {
      free = await models.freeStorageBytes();
    } catch (_) {
      free = null;
    }
    if (mounted) setState(() => _freeBytes = free);
  }

  Future<void> _cancel(ModelStatusDto status) async {
    if (status.doneBytes > 0 &&
        !await showCancelDownloadDialog(context, status.doneBytes)) {
      return;
    }
    await widget.run(models.cancel);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: models,
    builder: (context, _) {
      final status = models.status;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          _header(status),
          Column(
            spacing: 8,
            children: [for (final file in status.files) _row(file)],
          ),
          ..._body(status),
        ],
      );
    },
  );

  Widget _header(ModelStatusDto status) {
    final language = modelLanguageName(context.l10n, status.speechLanguage);
    final total = formatBytes(status.totalBytes);
    final done = formatBytes(status.doneBytes);
    final summary = switch (status.kind) {
      ModelStatusKindDto.notDownloaded => context.l10n.modelSummaryTotal(
        language,
        total,
      ),
      ModelStatusKindDto.downloading || ModelStatusKindDto.reconnecting =>
        context.l10n.modelSummaryProgress(language, done, total),
      ModelStatusKindDto.verifying => context.l10n.modelSummarySize(
        language,
        total,
      ),
      ModelStatusKindDto.paused => context.l10n.modelSummaryPaused(
        language,
        done,
        total,
      ),
      ModelStatusKindDto.failed =>
        status.error?.kind == ModelErrorKindDto.checksum
            ? context.l10n.modelSummaryCheckFailed(language)
            : context.l10n.modelSummaryStopped(language, done),
      ModelStatusKindDto.ready => context.l10n.modelSummaryReady(
        language,
        total,
      ),
    };
    return Row(
      children: [
        const Icon(FiIcons.waveform, size: 20, color: Nocturne.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(context.l10n.modelCardTitle),
              Text(
                summary,
                key: const Key('settings-model-summary'),
                style: _muted(.55),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        KeyedSubtree(key: const Key('settings-model-tag'), child: _tag(status)),
      ],
    );
  }

  Widget _tag(ModelStatusDto status) => switch (status.kind) {
    ModelStatusKindDto.notDownloaded => Tag.neutral(
      context.l10n.modelTagNotDownloaded,
      leading: FiIcons.download,
    ),
    ModelStatusKindDto.downloading => Tag(
      context.l10n.modelTagDownloading,
      leading: FiIcons.syncing,
    ),
    ModelStatusKindDto.reconnecting => Tag.neutral(
      context.l10n.modelTagReconnecting,
      leading: FiIcons.offline,
    ),
    ModelStatusKindDto.verifying => Tag(
      context.l10n.modelTagVerifying,
      leading: FiIcons.searching,
    ),
    ModelStatusKindDto.paused => Tag.neutral(
      context.l10n.modelTagPaused,
      leading: FiIcons.paused,
    ),
    ModelStatusKindDto.failed => Tag(
      context.l10n.modelTagFailed,
      background: Nocturne.neutral800,
      color: Nocturne.error,
      leading: FiIcons.error,
    ),
    ModelStatusKindDto.ready => Tag(
      context.l10n.modelTagReady,
      background: Nocturne.accent900,
      leading: FiIcons.check,
    ),
  };

  Widget _row(ModelFileDto file) {
    final size = formatBytes(file.sizeBytes);
    final detail = switch (file.state) {
      ModelFileStateDto.checking => context.l10n.modelRowChecking,
      ModelFileStateDto.damaged => context.l10n.modelRowDamaged(size),
      ModelFileStateDto.ready => size,
      _ when file.storedBytes > 0 && file.storedBytes < file.sizeBytes =>
        context.l10n.modelRowProgress(formatBytes(file.storedBytes), size),
      _ => size,
    };
    return Row(
      key: Key('settings-model-row-${file.name}'),
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                modelRoleName(context.l10n, file.role),
                style: _muted(.55, 11),
              ),
              Text(file.label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        Text(
          detail,
          style: TextStyle(
            fontSize: 12,
            color: file.state == ModelFileStateDto.damaged
                ? Nocturne.error
                : Nocturne.muted(.6),
            fontFeatures: Nocturne.tabular,
          ),
        ),
      ],
    );
  }

  Widget _bar(ModelStatusDto status, {required bool frozen}) {
    final value = status.totalBytes == 0
        ? 0.0
        : status.doneBytes / status.totalBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: status.kind == ModelStatusKindDto.verifying ? null : value,
        minHeight: 4,
        color: frozen ? Nocturne.neutral500 : Nocturne.accent,
        backgroundColor: Nocturne.neutral700,
      ),
    );
  }

  int _percent(ModelStatusDto status) => status.totalBytes == 0
      ? 0
      : (status.doneBytes * 100 / status.totalBytes).floor();

  Widget _progressLine(ModelStatusDto status, String? trailing) => Row(
    children: [
      Expanded(
        child: Text(
          context.l10n.modelPercent(_percent(status)),
          key: const Key('settings-model-progress'),
          style: _muted(.6).copyWith(fontFeatures: Nocturne.tabular),
        ),
      ),
      if (trailing != null) Text(trailing, style: _muted(.6)),
    ],
  );

  Widget _buttons(List<Widget> buttons) =>
      Wrap(spacing: 12, runSpacing: 8, children: buttons);

  Widget _pauseButton() => OutlinedButton.icon(
    key: const Key('settings-model-pause'),
    onPressed: () => unawaited(models.pause()),
    icon: const Icon(FiIcons.pause, size: 18),
    label: Text(context.l10n.modelPause),
  );

  Widget _cancelButton(ModelStatusDto status) => TextButton(
    key: const Key('settings-model-cancel'),
    onPressed: () => unawaited(_cancel(status)),
    child: Text(context.l10n.commonCancel),
  );

  List<Widget> _body(ModelStatusDto status) {
    switch (status.kind) {
      case ModelStatusKindDto.notDownloaded:
        final remaining = formatBytes(status.remainingBytes);
        final free = _freeBytes == null ? null : formatBytes(_freeBytes!);
        return [
          Row(
            children: [
              Icon(FiIcons.wifi, size: 16, color: Nocturne.muted(.7)),
              const SizedBox(width: 8),
              Text(context.l10n.modelWifiRecommended, style: _muted(.7)),
            ],
          ),
          Text(
            free == null
                ? context.l10n.modelNeeds(remaining)
                : context.l10n.modelNeedsWithFree(remaining, free),
            style: _muted(.55),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              key: const Key('settings-model-download'),
              onPressed: () => unawaited(widget.run(models.start)),
              icon: const Icon(FiIcons.download, size: 18),
              label: Text(context.l10n.modelDownload(remaining)),
            ),
          ),
        ];
      case ModelStatusKindDto.downloading:
        return [
          _bar(status, frozen: false),
          _progressLine(
            status,
            status.secondsLeft == null
                ? null
                : formatTimeLeft(context.l10n, status.secondsLeft!),
          ),
          _buttons([_pauseButton(), _cancelButton(status)]),
        ];
      case ModelStatusKindDto.reconnecting:
        return [
          Row(
            children: [
              Icon(FiIcons.offline, size: 16, color: Nocturne.muted(.7)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.modelReconnectingTitle,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          _bar(status, frozen: true),
          Text(context.l10n.modelReconnectingResumes, style: _muted(.6)),
          Text(context.l10n.modelReconnectingKeepOpen, style: _muted(.55)),
          _buttons([_pauseButton(), _cancelButton(status)]),
        ];
      case ModelStatusKindDto.verifying:
        return [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.modelVerifyingTitle,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (status.secondsLeft case final seconds?)
                Text(formatTimeLeft(context.l10n, seconds), style: _muted(.6)),
            ],
          ),
          _bar(status, frozen: false),
          _buttons([_cancelButton(status)]),
        ];
      case ModelStatusKindDto.paused:
        return [
          _bar(status, frozen: true),
          _progressLine(status, context.l10n.modelResumesFromHere),
          _buttons([
            FilledButton.icon(
              key: const Key('settings-model-resume'),
              onPressed: () => unawaited(widget.run(models.start)),
              icon: const Icon(FiIcons.download, size: 18),
              label: Text(context.l10n.modelResume),
            ),
            _cancelButton(status),
          ]),
        ];
      case ModelStatusKindDto.failed:
        final (title, line) = modelFailureText(context.l10n, status);
        return [
          Container(
            key: const Key('settings-model-failure'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Nocturne.neutral900,
              borderRadius: BorderRadius.circular(Nocturne.radiusSm),
              border: Border.all(color: Nocturne.neutral700),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(FiIcons.warning, size: 18, color: Nocturne.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13)),
                      Text(line, style: _muted(.6)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _buttons([
            FilledButton.icon(
              key: const Key('settings-model-retry'),
              onPressed: () => unawaited(widget.run(models.start)),
              icon: const Icon(FiIcons.refresh, size: 18),
              label: Text(context.l10n.commonRetry),
            ),
            TextButton(
              key: const Key('settings-model-cancel-delete'),
              onPressed: () => unawaited(_cancel(status)),
              child: Text(context.l10n.modelCancelAndDelete),
            ),
          ]),
        ];
      case ModelStatusKindDto.ready:
        return const [];
    }
  }
}
