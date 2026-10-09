//! Dictation cleanup: the instruction model returns the transcript with self-corrections and
//! filler removed, and deterministic code accepts that only when it deletes words.
//!
//! Words compare after the evidence normalizer (case, accents, apostrophes, punctuation). The
//! output must be a subsequence of the transcript's words, matched greedily from the end: a
//! correction takes back earlier words, so a repeated word is kept at its last occurrence. The cleaned text is
//! rebuilt from the transcript's own tokens, so a model that changes casing is not an invention.

use crate::{Grammar, VoiceLanguage, patch::normalize_text};

/// A dictation turn's result. `removed` holds the indexes of the transcript's whitespace-separated
/// tokens that the cleanup dropped; it is empty when `cleaned` equals the transcript.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Dictation {
    pub transcript: String,
    pub cleaned: String,
    pub removed: Vec<u32>,
}

impl Dictation {
    /// The transcript unchanged.
    pub fn unchanged(transcript: &str) -> Self {
        let transcript = transcript.trim().to_owned();
        Self {
            cleaned: transcript.clone(),
            transcript,
            removed: Vec::new(),
        }
    }
}

/// A single JSON string.
pub(crate) fn grammar() -> Grammar {
    Grammar::fixed(concat!(
        "root ::= \"\\\"\" char* \"\\\"\"\n",
        "char ::= [^\"\\\\\\x7F\\x00-\\x1F] | \"\\\\\" ([\"\\\\/bfnrt] | \"u\" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])\n",
    ))
}

const SYSTEM: &str = "You clean up a dictated note. Remove self-corrections (the words the speaker \
took back and the phrase that takes them back, such as \"no wait\", \"I mean\", \"scratch that\", \
\"nevermind\", \"actually\") and filler such as \"um\" and \"uh\". Keep every other word exactly as \
spoken and in the same order. Never add, reword, translate or reorder words. If nothing needs \
removing, return the note unchanged. Output one JSON string only.";

const EXAMPLES_EN: &[(&str, &str)] = &[
    ("Buy oat milk, no wait, almond milk", "Buy almond milk"),
    (
        "Call um the dentist on Tuesday, I mean Wednesday",
        "Call the dentist on Wednesday",
    ),
    ("Team lunch at Wagamama", "Team lunch at Wagamama"),
];

const EXAMPLES_ES: &[(&str, &str)] = &[
    (
        "Comprar leche de avena, digo, leche de almendra",
        "Comprar leche de almendra",
    ),
    (
        "Llamar al dentista el martes, perdón, mejor dicho el miércoles",
        "Llamar al dentista el miércoles",
    ),
    ("Este, comprar pan", "comprar pan"),
    ("Almuerzo con Sam", "Almuerzo con Sam"),
];

/// The Qwen chat prompt for one cleanup.
pub fn build_prompt(transcript: &str, language: VoiceLanguage) -> String {
    let mut system = SYSTEM.to_owned();
    if language == VoiceLanguage::Es {
        system.push_str(
            " The note is in Spanish: \"digo\", \"perdón\", \"mejor dicho\", \"no, espera\" take \
words back, and \"este\" and \"eh\" are filler. Do not translate.",
        );
    }
    let examples = match language {
        VoiceLanguage::En => EXAMPLES_EN,
        VoiceLanguage::Es => EXAMPLES_ES,
    };
    let mut prompt = format!("<|im_start|>system\n{system}<|im_end|>\n");
    let quote = |text: &str| serde_json::to_string(text).expect("strings serialize");
    for (heard, cleaned) in examples {
        prompt.push_str(&format!(
            "<|im_start|>user\n{heard}<|im_end|>\n<|im_start|>assistant\n{}<|im_end|>\n",
            quote(cleaned)
        ));
    }
    prompt.push_str(&format!(
        "<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
        transcript.trim()
    ));
    prompt
}

/// The model's string; anything else reads as empty.
fn parse_output(output: &str) -> String {
    serde_json::from_str::<String>(output.trim()).unwrap_or_default()
}

/// Which transcript tokens the output keeps, or `None` when the output is not the transcript
/// with words deleted. Tokens with no word (a lone dash) are kept with the word before them.
pub fn kept_tokens(transcript: &str, output: &str) -> Option<Vec<bool>> {
    let tokens: Vec<String> = transcript.split_whitespace().map(normalize_text).collect();
    let words: Vec<String> = output
        .split_whitespace()
        .map(normalize_text)
        .filter(|word| !word.is_empty())
        .collect();
    let mut kept = vec![false; tokens.len()];
    let mut end = tokens.len();
    for word in words.iter().rev() {
        let found = (0..end).rev().find(|&index| &tokens[index] == word)?;
        kept[found] = true;
        end = found;
    }
    let mut previous_kept = true;
    for (index, token) in tokens.iter().enumerate() {
        if token.is_empty() {
            kept[index] = previous_kept;
        } else {
            previous_kept = kept[index];
        }
    }
    Some(kept)
}

/// Checks the model's output against the transcript and rebuilds the cleaned text.
pub fn accept(transcript: &str, output: &str) -> Dictation {
    let cleaned_output = parse_output(output);
    let Some(kept) = kept_tokens(transcript, &cleaned_output) else {
        return Dictation::unchanged(transcript);
    };
    let tokens: Vec<&str> = transcript.split_whitespace().collect();
    let has_word = |index: usize| !normalize_text(tokens[index]).is_empty();
    if !(0..tokens.len()).any(|index| kept[index] && has_word(index)) {
        return Dictation::unchanged(transcript);
    }
    let removed: Vec<u32> = (0..tokens.len())
        .filter(|&index| !kept[index])
        .map(|index| index as u32)
        .collect();
    if removed.is_empty() {
        return Dictation::unchanged(transcript);
    }
    let kept_indexes: Vec<usize> = (0..tokens.len()).filter(|&index| kept[index]).collect();
    let mut parts: Vec<String> = Vec::with_capacity(kept_indexes.len());
    for (position, &index) in kept_indexes.iter().enumerate() {
        let mut token = tokens[index].to_owned();
        // A comma or similar before a removed run belonged to the removed words.
        let next_kept = kept_indexes.get(position + 1).copied();
        let gap_follows = match next_kept {
            Some(next) => next != index + 1,
            None => index + 1 != tokens.len(),
        };
        if gap_follows {
            token.truncate(token.trim_end_matches([',', ';', ':']).len());
        }
        parts.push(token);
    }
    // The sentence's capital moves to the first kept word when the first word was removed.
    if kept_indexes[0] != 0 && tokens[0].chars().next().is_some_and(char::is_uppercase) {
        let first = &parts[0];
        let mut chars = first.chars();
        if let Some(c) = chars.next() {
            parts[0] = c.to_uppercase().chain(chars).collect();
        }
    }
    // Ending punctuation removed with the last words carries over.
    if let Some(&last) = tokens.last()
        && !kept[tokens.len() - 1]
        && let Some(end) = last.chars().last().filter(|c| matches!(c, '.' | '!' | '?'))
        && let Some(part) = parts.last_mut()
        && !part.ends_with(['.', '!', '?'])
    {
        part.push(end);
    }
    Dictation {
        transcript: transcript.trim().to_owned(),
        cleaned: parts.join(" "),
        removed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(text: &str) -> String {
        serde_json::to_string(text).unwrap()
    }

    #[test]
    fn grammar_is_one_string() {
        assert!(
            grammar()
                .gbnf()
                .starts_with("root ::= \"\\\"\" char* \"\\\"\"")
        );
    }

    #[test]
    fn prompt_has_examples_and_the_transcript() {
        let prompt = build_prompt(" Buy eggs ", VoiceLanguage::En);
        assert!(prompt.contains("scratch that"));
        assert!(prompt.contains("\"Buy almond milk\""));
        assert!(prompt.ends_with("<|im_start|>user\nBuy eggs<|im_end|>\n<|im_start|>assistant\n"));
        let spanish = build_prompt("Comprar pan", VoiceLanguage::Es);
        assert!(spanish.contains("mejor dicho"));
        assert!(spanish.contains("Do not translate"));
    }

    #[test]
    fn subsequence_with_case_and_punctuation() {
        assert_eq!(
            kept_tokens("Buy oat milk, no wait, almond milk", "buy almond MILK"),
            Some(vec![true, false, false, false, false, true, true])
        );
        assert_eq!(
            kept_tokens("Lunch at Wagamama", "Lunch at the Wagamama"),
            None
        );
        assert_eq!(
            kept_tokens("¿Compraste pan?", "compraste"),
            Some(vec![true, false])
        );
        assert_eq!(
            kept_tokens("Café — té", "cafe te"),
            Some(vec![true, true, true])
        );
    }

    #[test]
    fn rebuilds_from_transcript_tokens() {
        let dictation = accept(
            "Pick up oat milk, no wait, almond milk, and eggs, I mean a dozen eggs",
            &output("pick up almond milk and a dozen eggs"),
        );
        assert_eq!(dictation.cleaned, "Pick up almond milk, and a dozen eggs");
        assert_eq!(dictation.removed, vec![2, 3, 4, 5, 9, 10, 11]);
    }
}
