import 'package:fi/src/rust/api/models.dart';
import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Every icon the app draws, named by meaning and pointing at a Phosphor glyph.
///
/// Feature code and tests use these names only, never Material icons or a Phosphor class directly,
/// so an icon change touches this one file. Regular weight unless the name says otherwise.
abstract final class FiIcons {
  // Actions.
  static const IconData add = PhosphorIconsRegular.plus;
  static const IconData addCircle = PhosphorIconsRegular.plusCircle;
  static const IconData remove = PhosphorIconsRegular.minus;
  static const IconData delete = PhosphorIconsRegular.trash;
  static const IconData edit = PhosphorIconsRegular.pencilSimple;
  static const IconData copy = PhosphorIconsRegular.copy;
  static const IconData refresh = PhosphorIconsRegular.arrowsClockwise;
  static const IconData reset = PhosphorIconsRegular.arrowCounterClockwise;
  static const IconData link = PhosphorIconsRegular.link;
  static const IconData search = PhosphorIconsRegular.magnifyingGlass;
  static const IconData microphone = PhosphorIconsRegular.microphone;
  static const IconData filter = PhosphorIconsRegular.slidersHorizontal;
  static const IconData select = PhosphorIconsRegular.checkSquare;
  static const IconData selectAll = PhosphorIconsRegular.checks;
  static const IconData reorder = PhosphorIconsRegular.arrowsDownUp;
  static const IconData importExport = PhosphorIconsRegular.arrowsDownUp;
  static const IconData dragHandle = PhosphorIconsRegular.dotsSixVertical;

  // Navigation and disclosure.
  static const IconData back = PhosphorIconsRegular.arrowLeft;
  static const IconData close = PhosphorIconsRegular.x;
  static const IconData clear = PhosphorIconsRegular.x;
  static const IconData more = PhosphorIconsRegular.dotsThreeVertical;
  static const IconData moreHorizontal = PhosphorIconsRegular.dotsThree;
  static const IconData expand = PhosphorIconsRegular.caretDown;
  static const IconData collapse = PhosphorIconsRegular.caretUp;
  static const IconData unfold = PhosphorIconsRegular.caretUpDown;

  // Status and feedback.
  static const IconData error = PhosphorIconsRegular.warningCircle;
  static const IconData needed = PhosphorIconsRegular.warningCircle;
  static const IconData warning = PhosphorIconsRegular.warning;
  static const IconData info = PhosphorIconsRegular.info;
  static const IconData help = PhosphorIconsRegular.question;
  static const IconData locked = PhosphorIconsRegular.lockSimple;
  static const IconData verified = PhosphorIconsRegular.sealCheck;
  static const IconData blocked = PhosphorIconsRegular.prohibit;
  static const IconData paused = PhosphorIconsRegular.pauseCircle;
  static const IconData rule = PhosphorIconsRegular.listChecks;
  static const IconData voice = PhosphorIconsFill.sparkle;
  static const IconData sparkle = PhosphorIconsRegular.sparkle;
  static const IconData defaultValue = PhosphorIconsRegular.arrowBendDownRight;

  // Sync and devices.
  static const IconData offline = PhosphorIconsRegular.cloudSlash;
  static const IconData synced = PhosphorIconsRegular.cloudCheck;
  static const IconData syncing = PhosphorIconsRegular.arrowsClockwise;
  // Phosphor has no radar glyph; a target reads as "looking for peers".
  static const IconData searching = PhosphorIconsRegular.target;
  static const IconData devices = PhosphorIconsRegular.devices;
  static const IconData phone = PhosphorIconsRegular.deviceMobile;
  static const IconData network = PhosphorIconsRegular.broadcast;

  // Collections, widgets and queries.
  static const IconData collection = PhosphorIconsRegular.squaresFour;
  static const IconData widget = PhosphorIconsRegular.squaresFour;
  static const IconData query = PhosphorIconsRegular.chartLine;
  static const IconData lineChart = PhosphorIconsRegular.chartLine;
  static const IconData barChart = PhosphorIconsRegular.chartBar;
  static const IconData scatterChart = PhosphorIconsRegular.chartScatter;
  static const IconData formula = PhosphorIconsRegular.function;
  static const IconData number = PhosphorIconsRegular.hash;

  // Field types (see [fieldTypeIcon]).
  static const IconData text = PhosphorIconsRegular.textAa;
  static const IconData integer = PhosphorIconsRegular.hash;
  static const IconData decimal = PhosphorIconsRegular.percent;
  static const IconData boolean = PhosphorIconsRegular.toggleLeft;
  static const IconData date = PhosphorIconsRegular.calendarBlank;
  static const IconData dateTime = PhosphorIconsRegular.calendarCheck;
  static const IconData duration = PhosphorIconsRegular.timer;
  static const IconData choice = PhosphorIconsRegular.listBullets;
}

/// The one icon for a field type of [kind].
IconData fieldTypeIcon(FieldTypeKindDto kind) => switch (kind) {
  FieldTypeKindDto.text => FiIcons.text,
  FieldTypeKindDto.integer => FiIcons.integer,
  FieldTypeKindDto.fixedDecimal => FiIcons.decimal,
  FieldTypeKindDto.boolean => FiIcons.boolean,
  FieldTypeKindDto.date => FiIcons.date,
  FieldTypeKindDto.dateTime => FiIcons.dateTime,
  FieldTypeKindDto.duration => FiIcons.duration,
  FieldTypeKindDto.enum_ => FiIcons.choice,
};
