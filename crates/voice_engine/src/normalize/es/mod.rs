//! Spanish span-to-value rules. A Spanish turn uses only these word tables; text and choice
//! rules are shared with English.

mod dates;
mod duration;
mod numbers;

pub use dates::{normalize_date, normalize_date_time};
pub use duration::normalize_duration;
pub use numbers::{normalize_decimal, normalize_integer, parse_number_es};

/// Lowercases and folds Spanish diacritics (á é í ó ú ü) to their base letter. Keeps ñ.
pub(crate) fn fold(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .map(fold_char)
        .collect()
}

/// Folds one lowercase Spanish diacritic to its base letter.
pub(crate) fn fold_char(c: char) -> char {
    match c {
        'á' => 'a',
        'é' => 'e',
        'í' => 'i',
        'ó' => 'o',
        'ú' | 'ü' => 'u',
        c => c,
    }
}

pub fn normalize_boolean(span: &str) -> Option<bool> {
    match fold(&crate::patch::normalize_text(span)).as_str() {
        "si" | "verdadero" | "activado" | "encendido" | "claro" => Some(true),
        "no" | "falso" | "desactivado" | "apagado" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold_drops_accents_and_keeps_n_tilde() {
        assert_eq!(fold("Sí, CAFÉ pingüino Año"), "si, cafe pinguino año");
    }
}
