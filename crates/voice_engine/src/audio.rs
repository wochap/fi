//! Pure audio and transcript helpers around Whisper: PCM conversion, silence trimming and
//! non-speech token cleanup.

/// 16 kHz mono.
pub const SAMPLE_RATE: usize = 16_000;
/// 20 ms frames for the energy gate.
const FRAME: usize = SAMPLE_RATE / 50;
/// RMS below this (on a 0..1 scale) is silence.
pub const SILENCE_RMS: f32 = 0.01;
/// Speech kept on each side of the trimmed span.
const PADDING: usize = SAMPLE_RATE / 5;

pub fn pcm16_to_f32(pcm: &[i16]) -> Vec<f32> {
    pcm.iter().map(|&s| f32::from(s) / 32_768.0).collect()
}

fn rms(frame: &[f32]) -> f32 {
    (frame.iter().map(|s| s * s).sum::<f32>() / frame.len().max(1) as f32).sqrt()
}

/// The samples between the first and last frame above the silence level, padded a little;
/// `None` when every frame is silent.
pub fn trim_silence(samples: &[f32]) -> Option<&[f32]> {
    let loud: Vec<usize> = samples
        .chunks(FRAME)
        .enumerate()
        .filter(|(_, frame)| rms(frame) >= SILENCE_RMS)
        .map(|(index, _)| index)
        .collect();
    let first = *loud.first()? * FRAME;
    let last = ((*loud.last()? + 1) * FRAME).min(samples.len());
    Some(&samples[first.saturating_sub(PADDING)..(last + PADDING).min(samples.len())])
}

/// The samples of a 16-bit PCM WAV file, as used by the fixtures and the eval; `None` for other
/// formats.
pub fn wav_pcm16(bytes: &[u8]) -> Option<Vec<i16>> {
    if bytes.get(0..4)? != b"RIFF" || bytes.get(8..12)? != b"WAVE" {
        return None;
    }
    let mut offset = 12;
    let mut format_ok = false;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().ok()?) as usize;
        let body = bytes.get(offset + 8..(offset + 8 + size).min(bytes.len()))?;
        if id == b"fmt " {
            let format = u16::from_le_bytes(body.get(0..2)?.try_into().ok()?);
            let bits = u16::from_le_bytes(body.get(14..16)?.try_into().ok()?);
            format_ok = format == 1 && bits == 16;
        } else if id == b"data" {
            return format_ok.then(|| {
                body.chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                    .collect()
            });
        }
        offset += 8 + size + size % 2;
    }
    None
}

/// Whisper text without bracketed or starred non-speech tokens (`[BLANK_AUDIO]`, `(music)`,
/// `*coughs*`), with whitespace collapsed.
pub fn clean_transcript(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut closer: Option<char> = None;
    for c in text.chars() {
        match closer {
            Some(end) if c == end => closer = None,
            Some(_) => {}
            None => match c {
                '[' => closer = Some(']'),
                '(' => closer = Some(')'),
                '*' => closer = Some('*'),
                '♪' => {}
                c => out.push(c),
            },
        }
    }
    let cleaned = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().any(char::is_alphanumeric) {
        cleaned
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_has_no_speech() {
        assert!(trim_silence(&vec![0.0; SAMPLE_RATE]).is_none());
        assert!(trim_silence(&vec![0.001; SAMPLE_RATE]).is_none());
        assert!(trim_silence(&[]).is_none());
    }

    #[test]
    fn speech_is_trimmed_with_padding() {
        let mut samples = vec![0.0; SAMPLE_RATE * 3];
        for sample in &mut samples[SAMPLE_RATE..SAMPLE_RATE * 2] {
            *sample = 0.2;
        }
        let trimmed = trim_silence(&samples).unwrap();
        assert_eq!(trimmed.len(), SAMPLE_RATE + 2 * PADDING);
    }

    #[test]
    fn pcm_scales_to_unit_range() {
        assert_eq!(pcm16_to_f32(&[0, -32_768, 16_384]), vec![0.0, -1.0, 0.5]);
    }

    #[test]
    fn fixture_wavs_read_as_pcm16() {
        let speech = wav_pcm16(include_bytes!("../tests/fixtures/lunch.wav")).unwrap();
        assert!(trim_silence(&pcm16_to_f32(&speech)).is_some());
        let silence = wav_pcm16(include_bytes!("../tests/fixtures/silence.wav")).unwrap();
        assert_eq!(silence.len(), 2 * SAMPLE_RATE);
        assert!(trim_silence(&pcm16_to_f32(&silence)).is_none());
        assert!(wav_pcm16(b"nope").is_none());
    }

    #[test]
    fn non_speech_tokens_are_removed() {
        assert_eq!(clean_transcript(" [BLANK_AUDIO] "), "");
        assert_eq!(clean_transcript("(music) ♪"), "");
        assert_eq!(
            clean_transcript(" Lunch at Nando's, *coughs* twelve fifty. [Music]"),
            "Lunch at Nando's, twelve fifty."
        );
        assert_eq!(clean_transcript("..."), "");
    }
}
