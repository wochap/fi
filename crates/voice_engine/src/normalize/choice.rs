//! Choice labels: case-insensitive exact match, then the single closest label within an edit
//! distance of 2 and 30% of the label length. A tie is ambiguous and dropped.

use crate::{ChoiceOption, patch::normalize_text};

pub fn levenshtein(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = (above + 1)
                .min(row[j] + 1)
                .min(diagonal + usize::from(ca != *cb));
            diagonal = above;
        }
    }
    row[b.len()]
}

/// The matching option id.
pub fn normalize_choice(span: &str, options: &[ChoiceOption]) -> Option<String> {
    let span = normalize_text(span);
    if span.is_empty() {
        return None;
    }
    let labels: Vec<String> = options.iter().map(|o| normalize_text(&o.label)).collect();
    let exact: Vec<usize> = (0..options.len()).filter(|&i| labels[i] == span).collect();
    if let [index] = exact.as_slice() {
        return Some(options[*index].id.clone());
    }
    if exact.len() > 1 {
        return None;
    }
    let mut best: Option<(usize, usize)> = None;
    let mut tied = false;
    for (index, label) in labels.iter().enumerate() {
        let distance = levenshtein(&span, label);
        if distance > 2 || distance * 10 > label.chars().count() * 3 {
            continue;
        }
        match best {
            Some((_, best_distance)) if distance > best_distance => {}
            Some((_, best_distance)) if distance == best_distance => tied = true,
            _ => {
                best = Some((index, distance));
                tied = false;
            }
        }
    }
    match best {
        Some((index, _)) if !tied => Some(options[index].id.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(labels: &[&str]) -> Vec<ChoiceOption> {
        labels
            .iter()
            .map(|label| ChoiceOption {
                id: format!("id-{label}"),
                label: (*label).into(),
            })
            .collect()
    }

    #[test]
    fn distance() {
        assert_eq!(levenshtein("kitten", "sitting"), 3);
        assert_eq!(levenshtein("", "abc"), 3);
        assert_eq!(levenshtein("food", "food"), 0);
    }

    #[test]
    fn choices() {
        let expense = options(&["food", "transport", "home", "other"]);
        let ties = options(&["cats", "bats"]);
        for (span, options, expected) in [
            ("Food", &expense, Some("id-food")),
            ("food.", &expense, Some("id-food")),
            ("transprot", &expense, Some("id-transport")),
            ("tranport", &expense, Some("id-transport")),
            ("fod", &expense, Some("id-food")),
            ("fork", &expense, None),
            ("groceries", &expense, None),
            ("hats", &ties, None),
            ("cats", &ties, Some("id-cats")),
            ("", &expense, None),
        ] {
            assert_eq!(
                normalize_choice(span, options).as_deref(),
                expected,
                "{span}"
            );
        }
    }
}
