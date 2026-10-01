// English strings of the voice model UI: the Settings card, its dialogs, and
// the sheet's download offer and downloading card. Change 5 (i18n-en-es-ui)
// moves these to ARB.

import 'package:fi/src/rust/api/voice_models.dart' show ModelRoleDto;

abstract final class ModelStrings {
  static const cardTitle = 'Voice models';

  // State tags.
  static const tagNotDownloaded = 'Not downloaded';
  static const tagDownloading = 'Downloading';
  static const tagReconnecting = 'Reconnecting';
  static const tagVerifying = 'Verifying';
  static const tagPaused = 'Paused';
  static const tagFailed = 'Failed';
  static const tagReady = 'Ready';

  static String roleName(ModelRoleDto role) => switch (role) {
    ModelRoleDto.speech => 'Speech recognition',
    ModelRoleDto.understanding => 'Understanding',
  };

  /// The role as it reads inside a sentence: "the understanding model".
  static String roleInSentence(ModelRoleDto role) => switch (role) {
    ModelRoleDto.speech => 'speech recognition',
    ModelRoleDto.understanding => 'understanding',
  };

  static String languageName(String? code) => switch (code) {
    'en' => 'English',
    'es' => 'Spanish',
    null => 'All languages',
    _ => code,
  };

  // Card summaries.
  static String summaryTotal(String language, String total) =>
      '$language · $total total';
  static String summaryProgress(String language, String done, String total) =>
      '$language · $done of $total';
  static String summarySize(String language, String total) =>
      '$language · $total';
  static String summaryPaused(String language, String done, String total) =>
      '$language · paused at $done of $total';
  static String summaryStopped(String language, String done) =>
      '$language · stopped at $done';
  static String summaryCheckFailed(String language) =>
      '$language · check failed';
  static String summaryReady(String language, String total) =>
      '$language · $total used on this phone';

  // Model rows.
  static String rowProgress(String stored, String size) => '$stored of $size';
  static const rowChecking = 'Checking';
  static String rowDamaged(String size) => '$size · damaged';

  // Card bodies.
  static const wifiRecommended = 'Wi-Fi recommended';
  static String needsSpace(String needed, String? free) => free == null
      ? 'Needs $needed'
      : 'Needs $needed · $free free on this phone';
  static String download(String size) => 'Download $size';
  static const pause = 'Pause';
  static const resume = 'Resume';
  static const cancel = 'Cancel';
  static const retry = 'Retry';
  static const cancelAndDelete = 'Cancel and delete';
  static String percent(int percent) => '$percent%';
  static String timeLeft(String time) => 'about $time';
  static const reconnectingTitle = 'Connection lost — reconnecting…';
  static const reconnectingResumes = 'The download resumes where it stopped.';
  static const reconnectingKeepOpen =
      'Leaving Fi can pause the network. Keep it open to finish faster.';
  static const verifyingTitle = 'Checking downloaded data…';
  static const resumesFromHere = 'resumes from here';

  // Failures.
  static const networkTitle = 'No connection';
  static const networkLine =
      "Couldn't reach the download server. Check your Wi-Fi, then retry. "
      'Downloaded data is kept.';
  static const storageTitle = 'Not enough storage';
  static String storageLine(String needed) =>
      'Free up $needed on this phone, then retry.';
  static const damagedTitle = 'Downloaded file is damaged';
  static String damagedLine(ModelRoleDto role, String size) =>
      'The ${roleInSentence(role)} model failed its check. '
      'Retry downloads it again ($size).';
  static const ioTitle = "Couldn't save the download";
  static const ioLine = 'Storage error. Retry; downloaded data is kept.';

  // Ready actions.
  static const redownload = 'Re-download models';
  static const delete = 'Delete models';
  static String frees(String size) => 'frees $size';

  // Dialogs.
  static const cancelDialogTitle = 'Cancel download?';
  static String cancelDialogBody(String done) =>
      'Downloaded data ($done) will be deleted.';
  static const cancelDialogConfirm = 'Cancel download';
  static const cancelDialogKeep = 'Keep downloading';
  static const deleteDialogTitle = 'Delete voice models?';
  static String deleteDialogBody(String size) =>
      'Frees $size. Voice fill won’t work until you download them again.';
  static const deleteDialogConfirm = 'Delete';
  static const deleteDialogKeep = 'Keep models';
  static const redownloadDialogTitle = 'Re-download voice models?';
  static String redownloadDialogBody(String size) =>
      'The models are deleted and downloaded again ($size).';
  static const redownloadDialogConfirm = 'Re-download';
  static const redownloadDialogKeep = 'Keep models';

  // Sheet offer and downloading card.
  static const offerTitle = 'Download voice models';
  static String offerLine(String language, String size) =>
      '$language · $size total, one time. Everything runs on this phone.';
  static const onMobileData = "You're on mobile data";
  static const onWifi = "You're on Wi-Fi";
  static const storage = 'Storage';
  static String free(String size) => '$size free';
  static const later = 'Later';
  static const downloadingTitle = 'Downloading voice models';
  static const reconnectingShort = 'Reconnecting…';
  static const pausedTitle = 'Download paused';
  static String progressLine(String done, String total, int percent) =>
      '$done of $total · $percent%';
  static const keepFilling =
      "Keep filling by hand. The mic turns on when it's ready.";
  static const pauseDownload = 'Pause download';
  static const resumeDownload = 'Resume download';
  static const hide = 'Hide';
  static String errorLine(String title, String line) => '$title. $line';
}
