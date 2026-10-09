//! On-device voice fill; see the `voice_engine` crate.
//!
//! The native engine (whisper.cpp and llama.cpp) is built on Android arm64, and on other
//! platforms with the `voice-native` feature. Elsewhere every call reports the engine as
//! unavailable. The instruction model is loaded once on a worker thread and kept until
//! [`voice_release`]; Whisper is loaded for each turn. Audio and transcripts are never logged.

use flutter_rust_bridge::frb;
use voice_engine::{
    ChoiceOption, Dictation, FieldKind, PatchEntry, TypedValue, VoiceError, VoiceField,
    VoiceLanguage,
};

use crate::{
    api::models::{FieldTypeKindDto, FieldValueDto, FieldValueKindDto},
    frb_generated::StreamSink,
};

/// One live option of a Choice field.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceOptionDto {
    pub id: String,
    pub label: String,
}

/// One active field, as the engine sees it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceFieldDto {
    pub id: String,
    pub name: String,
    pub kind: FieldTypeKindDto,
    pub scale: Option<u8>,
    pub required: bool,
    pub options: Vec<VoiceOptionDto>,
    pub max_length: Option<u32>,
}

/// A draft value, as display text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceDraftValueDto {
    pub field_id: String,
    pub text: String,
}

/// What one turn fills, with the device's local date, minute and UTC offset.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceFillRequestDto {
    pub collection_id: String,
    pub fields: Vec<VoiceFieldDto>,
    pub draft: Vec<VoiceDraftValueDto>,
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub minute_of_day: u32,
    pub utc_offset_minutes: i32,
    /// The voice language code: "en" or "es". Anything else reads as English.
    pub language: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoicePatchEntryDto {
    pub field_id: String,
    pub value: FieldValueDto,
    pub evidence: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VoiceErrorKindDto {
    NoSpeech,
    NothingMatched,
    ModelLoadFailed,
    LowMemory,
    Cancelled,
}

impl From<VoiceError> for VoiceErrorKindDto {
    fn from(error: VoiceError) -> Self {
        match error {
            VoiceError::NoSpeech => Self::NoSpeech,
            VoiceError::NothingMatched => Self::NothingMatched,
            VoiceError::ModelLoadFailed => Self::ModelLoadFailed,
            VoiceError::LowMemory => Self::LowMemory,
            VoiceError::Cancelled => Self::Cancelled,
        }
    }
}

/// A dictation turn's cleaned text. `removed` holds the indexes of the transcript's
/// whitespace-separated tokens that the cleanup dropped.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceDictationDto {
    pub cleaned: String,
    pub removed: Vec<u32>,
}

/// One event of a turn: the transcript first, then either the patch (fill turn), the dictation
/// (dictation turn) or a failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VoiceTurnEventDto {
    pub transcript: Option<String>,
    pub patch: Option<Vec<VoicePatchEntryDto>>,
    pub dictation: Option<VoiceDictationDto>,
    pub error: Option<VoiceErrorKindDto>,
}

#[cfg_attr(
    not(any(
        feature = "voice-native",
        all(target_os = "android", target_arch = "aarch64")
    )),
    allow(dead_code, reason = "used only by the native voice worker")
)]
impl VoiceTurnEventDto {
    pub(crate) fn transcript(text: String) -> Self {
        Self {
            transcript: Some(text),
            patch: None,
            dictation: None,
            error: None,
        }
    }

    pub(crate) fn patch(patch: Vec<PatchEntry>) -> Self {
        Self {
            transcript: None,
            patch: Some(patch.into_iter().map(entry_dto).collect()),
            dictation: None,
            error: None,
        }
    }

    pub(crate) fn dictation(dictation: Dictation) -> Self {
        Self {
            transcript: None,
            patch: None,
            dictation: Some(VoiceDictationDto {
                cleaned: dictation.cleaned,
                removed: dictation.removed,
            }),
            error: None,
        }
    }

    pub(crate) fn failed(error: VoiceError) -> Self {
        Self {
            transcript: None,
            patch: None,
            dictation: None,
            error: Some(error.into()),
        }
    }
}

fn field(dto: VoiceFieldDto) -> VoiceField {
    VoiceField {
        id: dto.id,
        name: dto.name,
        kind: match dto.kind {
            FieldTypeKindDto::Text => FieldKind::Text,
            FieldTypeKindDto::Integer => FieldKind::Integer,
            FieldTypeKindDto::FixedDecimal => FieldKind::Decimal {
                scale: dto.scale.unwrap_or(0),
            },
            FieldTypeKindDto::Boolean => FieldKind::Boolean,
            FieldTypeKindDto::Date => FieldKind::Date,
            FieldTypeKindDto::DateTime => FieldKind::DateTime,
            FieldTypeKindDto::Duration => FieldKind::Duration,
            FieldTypeKindDto::Enum => FieldKind::Choice,
        },
        required: dto.required,
        options: dto
            .options
            .into_iter()
            .map(|option| ChoiceOption {
                id: option.id,
                label: option.label,
            })
            .collect(),
        max_length: dto.max_length,
    }
}

fn request(dto: VoiceFillRequestDto) -> Option<voice_engine::FillRequest> {
    Some(voice_engine::FillRequest {
        collection_id: dto.collection_id,
        fields: dto.fields.into_iter().map(field).collect(),
        draft: dto
            .draft
            .into_iter()
            .map(|value| (value.field_id, value.text))
            .collect(),
        today: chrono::NaiveDate::from_ymd_opt(dto.year, dto.month, dto.day)?,
        now: chrono::NaiveTime::from_num_seconds_from_midnight_opt(dto.minute_of_day * 60, 0)?,
        utc_offset_minutes: dto.utc_offset_minutes,
        language: VoiceLanguage::from_code(&dto.language),
    })
}

#[cfg_attr(
    not(any(
        feature = "voice-native",
        all(target_os = "android", target_arch = "aarch64")
    )),
    allow(dead_code, reason = "used only by the native voice worker")
)]
fn entry_dto(entry: PatchEntry) -> VoicePatchEntryDto {
    let (kind, integer_value, text_value, boolean_value) = match entry.value {
        TypedValue::Text(text) => (FieldValueKindDto::Text, None, Some(text), None),
        TypedValue::Integer(value) => (FieldValueKindDto::Integer, Some(value), None, None),
        TypedValue::Decimal(value) => (FieldValueKindDto::FixedDecimal, Some(value), None, None),
        TypedValue::Boolean(value) => (FieldValueKindDto::Boolean, None, None, Some(value)),
        TypedValue::Date(value) => (FieldValueKindDto::Date, Some(value), None, None),
        TypedValue::DateTime(value) => (FieldValueKindDto::DateTime, Some(value), None, None),
        TypedValue::Duration(value) => (FieldValueKindDto::Duration, Some(value), None, None),
        TypedValue::Choice(id) => (FieldValueKindDto::Enum, None, Some(id), None),
    };
    VoicePatchEntryDto {
        field_id: entry.field_id,
        value: FieldValueDto {
            kind,
            integer_value,
            text_value,
            boolean_value,
        },
        evidence: entry.evidence,
    }
}

/// Whether this build has the on-device engine. True whether or not the models are downloaded,
/// so the first-use download flow can run.
#[frb(sync)]
#[must_use]
pub fn voice_native_available() -> bool {
    crate::voice_worker::AVAILABLE
}

/// Starts loading the instruction model in the background when the models are ready. Idempotent.
#[frb(sync)]
pub fn voice_prepare(models_dir: String) {
    crate::voice_worker::prepare(&models_dir);
}

/// Transcribes and fills one turn of 16 kHz mono PCM16 audio. The sink receives the transcript,
/// then the patch or a failure, and closes.
pub fn voice_fill_turn(
    models_dir: String,
    pcm: Vec<i16>,
    request: VoiceFillRequestDto,
    sink: StreamSink<VoiceTurnEventDto>,
) {
    let Some(request) = self::request(request) else {
        let _ = sink.add(VoiceTurnEventDto::failed(VoiceError::NothingMatched));
        return;
    };
    crate::voice_worker::fill_turn(&models_dir, pcm, request, move |event| {
        let _ = sink.add(event);
    });
}

/// Transcribes one turn of 16 kHz mono PCM16 audio and cleans it for dictation into one field.
/// The sink receives the transcript, then the dictation or a failure, and closes. `language` is
/// the voice language code; anything but "es" reads as English.
pub fn voice_dictate_turn(
    models_dir: String,
    pcm: Vec<i16>,
    language: String,
    sink: StreamSink<VoiceTurnEventDto>,
) {
    crate::voice_worker::dictate_turn(
        &models_dir,
        pcm,
        VoiceLanguage::from_code(&language),
        move |event| {
            let _ = sink.add(event);
        },
    );
}

/// Stops the running turn at the next opportunity; it fails with `Cancelled`.
#[frb(sync)]
pub fn voice_cancel() {
    crate::voice_worker::cancel();
}

/// Releases the instruction model (backgrounded app or memory pressure).
#[frb(sync)]
pub fn voice_release() {
    crate::voice_worker::release();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request_dto() -> VoiceFillRequestDto {
        VoiceFillRequestDto {
            collection_id: "c".into(),
            fields: vec![VoiceFieldDto {
                id: "f".into(),
                name: "amount".into(),
                kind: FieldTypeKindDto::FixedDecimal,
                scale: Some(2),
                required: true,
                options: Vec::new(),
                max_length: None,
            }],
            draft: vec![VoiceDraftValueDto {
                field_id: "f".into(),
                text: "3.00".into(),
            }],
            year: 2026,
            month: 9,
            day: 28,
            minute_of_day: 14 * 60 + 7,
            utc_offset_minutes: 120,
            language: "es".into(),
        }
    }

    #[test]
    fn requests_convert_with_the_local_clock() {
        let request = request(request_dto()).unwrap();
        assert_eq!(request.fields[0].kind, FieldKind::Decimal { scale: 2 });
        assert_eq!(request.today.to_string(), "2026-09-28");
        assert_eq!(request.now.to_string(), "14:07:00");
        assert_eq!(request.draft, vec![("f".to_owned(), "3.00".to_owned())]);
        assert_eq!(request.language, VoiceLanguage::Es);
        let mut bad = request_dto();
        bad.month = 13;
        assert!(self::request(bad).is_none());
    }

    #[test]
    fn typed_values_become_field_value_dtos() {
        let entry = entry_dto(PatchEntry {
            field_id: "f".into(),
            value: TypedValue::Choice("opt".into()),
            evidence: "food".into(),
        });
        assert_eq!(entry.value.kind, FieldValueKindDto::Enum);
        assert_eq!(entry.value.text_value.as_deref(), Some("opt"));
        let entry = entry_dto(PatchEntry {
            field_id: "f".into(),
            value: TypedValue::Decimal(1250),
            evidence: "twelve fifty".into(),
        });
        assert_eq!(entry.value.integer_value, Some(1250));
    }

    #[test]
    fn dictation_events_carry_the_cleaned_text() {
        let event = VoiceTurnEventDto::dictation(Dictation {
            transcript: "Buy oat milk, no wait, almond milk".into(),
            cleaned: "Buy almond milk".into(),
            removed: vec![1, 2, 3, 4],
        });
        assert_eq!(
            event.dictation,
            Some(VoiceDictationDto {
                cleaned: "Buy almond milk".into(),
                removed: vec![1, 2, 3, 4],
            })
        );
        assert!(event.patch.is_none() && event.transcript.is_none());
    }

    #[cfg(not(any(
        feature = "voice-native",
        all(target_os = "android", target_arch = "aarch64")
    )))]
    #[test]
    fn the_stub_reports_unavailable_and_fails_turns() {
        assert!(!voice_native_available());
        let (sender, receiver) = std::sync::mpsc::channel();
        crate::voice_worker::fill_turn(
            "x",
            vec![0; 10],
            request(request_dto()).unwrap(),
            move |event| {
                sender.send(event).unwrap();
            },
        );
        assert_eq!(
            receiver.recv().unwrap().error,
            Some(VoiceErrorKindDto::ModelLoadFailed)
        );
        let (sender, receiver) = std::sync::mpsc::channel();
        crate::voice_worker::dictate_turn("x", vec![0; 10], VoiceLanguage::En, move |event| {
            sender.send(event).unwrap();
        });
        assert_eq!(
            receiver.recv().unwrap().error,
            Some(VoiceErrorKindDto::ModelLoadFailed)
        );
        voice_prepare("x".into());
        voice_cancel();
        voice_release();
    }
}
