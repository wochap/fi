import 'package:fi/src/rust/api/models.dart';
import 'package:fi/voice/engine.dart';
import 'package:flutter/foundation.dart';

/// Where a draft field's value came from.
enum FieldOriginKind { empty, defaulted, typed, voice }

@immutable
final class FieldOrigin {
  const FieldOrigin._(this.kind) : turn = null, evidence = null;

  static const empty = FieldOrigin._(FieldOriginKind.empty);
  static const defaulted = FieldOrigin._(FieldOriginKind.defaulted);
  static const typed = FieldOrigin._(FieldOriginKind.typed);

  /// Filled by voice turn [turn] (1-based) from the transcript words [evidence].
  const FieldOrigin.voice({
    required int this.turn,
    required String this.evidence,
  }) : kind = FieldOriginKind.voice;

  final FieldOriginKind kind;
  final int? turn;
  final String? evidence;

  bool get isVoice => kind == FieldOriginKind.voice;

  @override
  bool operator ==(Object other) =>
      other is FieldOrigin &&
      other.kind == kind &&
      other.turn == turn &&
      other.evidence == evidence;

  @override
  int get hashCode => Object.hash(kind, turn, evidence);
}

/// Each draft field's origin, for one open New record sheet.
final class VoiceDraftState {
  VoiceDraftState([Map<String, FieldOrigin>? origins])
    : _origins = {...?origins};

  final Map<String, FieldOrigin> _origins;

  FieldOrigin of(String fieldId) => _origins[fieldId] ?? FieldOrigin.empty;

  Map<String, FieldOrigin> get origins => Map.unmodifiable(_origins);

  /// The user changed the field by hand: it counts as typed and loses any Voice marker.
  void markTyped(String fieldId) => _origins[fieldId] = FieldOrigin.typed;

  /// "Clear field": the field is empty and unmarked.
  void clear(String fieldId) => _origins[fieldId] = FieldOrigin.empty;

  void replaceAll(Map<String, FieldOrigin> origins) => _origins
    ..clear()
    ..addAll(origins);
}

/// What [applyPatch] did.
@immutable
final class PatchOutcome {
  const PatchOutcome({
    required this.draft,
    required this.origins,
    required this.applied,
    required this.keptTyped,
  });

  final Map<String, FieldValueDto> draft;
  final Map<String, FieldOrigin> origins;

  /// Field ids the patch changed, in patch order.
  final List<String> applied;

  /// Field ids the patch named but that keep the user's own value.
  final List<String> keptTyped;
}

/// Case, whitespace and punctuation folded away, for the evidence check.
String normalizeSpeech(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// Whether [evidence] is words of [transcript].
bool evidenceInTranscript(String evidence, String transcript) {
  final words = normalizeSpeech(evidence);
  if (words.isEmpty) return false;
  return ' ${normalizeSpeech(transcript)} '.contains(' $words ');
}

FieldValueKindDto _valueKindFor(FieldTypeKindDto kind) => switch (kind) {
  FieldTypeKindDto.text => FieldValueKindDto.text,
  FieldTypeKindDto.integer => FieldValueKindDto.integer,
  FieldTypeKindDto.fixedDecimal => FieldValueKindDto.fixedDecimal,
  FieldTypeKindDto.boolean => FieldValueKindDto.boolean,
  FieldTypeKindDto.date => FieldValueKindDto.date,
  FieldTypeKindDto.dateTime => FieldValueKindDto.dateTime,
  FieldTypeKindDto.duration => FieldValueKindDto.duration,
  FieldTypeKindDto.enum_ => FieldValueKindDto.enum_,
};

/// Whether [value] is a valid value of [field]'s type, options and bounds.
bool validVoiceValue(VoiceField field, FieldValueDto value) {
  if (value.kind != _valueKindFor(field.kind)) return false;
  switch (value.kind) {
    case FieldValueKindDto.text:
      final text = value.textValue?.trim() ?? '';
      if (text.isEmpty) return false;
      if (field.minLength case final min? when text.length < min) return false;
      if (field.maxLength case final max? when text.length > max) return false;
      return true;
    case FieldValueKindDto.enum_:
      return field.options.any((option) => option.id == value.textValue);
    case FieldValueKindDto.boolean:
      return value.booleanValue != null;
    case FieldValueKindDto.integer:
      final number = value.integerValue;
      if (number == null) return false;
      if (field.minInteger case final min? when number < min) return false;
      if (field.maxInteger case final max? when number > max) return false;
      return true;
    case FieldValueKindDto.fixedDecimal ||
        FieldValueKindDto.date ||
        FieldValueKindDto.dateTime ||
        FieldValueKindDto.duration:
      return value.integerValue != null;
    case FieldValueKindDto.null_:
      return false;
  }
}

/// Applies one turn's [patch] to [draft] under the voice rules:
/// - entries naming a field not in [fields] (unknown, deleted or computed) are ignored;
/// - entries whose value is invalid for the field are ignored;
/// - entries whose evidence is not in [transcript] are ignored;
/// - a field the user typed is never overwritten (it is reported in `keptTyped`);
/// - an empty, defaulted or earlier-voice field is replaced.
PatchOutcome applyPatch({
  required List<VoiceField> fields,
  required Map<String, FieldValueDto> draft,
  required Map<String, FieldOrigin> origins,
  required List<VoicePatchEntry> patch,
  required String transcript,
  required int turn,
}) {
  final byId = {for (final field in fields) field.id: field};
  final nextDraft = {...draft};
  final nextOrigins = {...origins};
  final applied = <String>[];
  final keptTyped = <String>[];
  for (final entry in patch) {
    final field = byId[entry.fieldId];
    if (field == null) continue;
    if (!validVoiceValue(field, entry.value)) continue;
    if (!evidenceInTranscript(entry.evidence, transcript)) continue;
    if (origins[field.id]?.kind == FieldOriginKind.typed) {
      if (!keptTyped.contains(field.id)) keptTyped.add(field.id);
      continue;
    }
    nextDraft[field.id] = entry.value;
    nextOrigins[field.id] = FieldOrigin.voice(
      turn: turn,
      evidence: entry.evidence,
    );
    if (!applied.contains(field.id)) applied.add(field.id);
  }
  return PatchOutcome(
    draft: nextDraft,
    origins: nextOrigins,
    applied: applied,
    keptTyped: keptTyped,
  );
}

/// Whether [value] holds nothing.
bool isEmptyValue(FieldValueDto? value) =>
    value == null ||
    value.kind == FieldValueKindDto.null_ ||
    (value.kind == FieldValueKindDto.text &&
        (value.textValue?.trim().isEmpty ?? true));
