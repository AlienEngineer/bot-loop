//! The list of Copilot models offered in the picker.
//!
//! `copilot` has no stable "list models" command, so the TUI ships a small
//! curated default list. It is overridable via `COPILOT_MODELS` (whitespace- or
//! comma-separated) so a user is never stuck with a stale catalogue, and `auto`
//! — "let Copilot pick" — is always present as the first, safe default.

/// Environment variable overriding the built-in model list.
pub const MODELS_ENV: &str = "COPILOT_MODELS";

/// Environment variable overriding the model that writes the close summary (#161).
pub const SUMMARY_MODEL_ENV: &str = "SUMMARY_MODEL";

/// Sentinel model meaning "let Copilot choose". Selecting it passes no
/// `--model` to the loop, matching an empty `COPILOT_MODEL`.
pub const AUTO_MODEL: &str = "auto";

/// Default *light* model used to summarize a closed issue's session, chosen to
/// keep the summary cheap (#161). Deliberately a mini model; overridable via
/// `SUMMARY_MODEL` for when the catalogue moves on.
pub const DEFAULT_SUMMARY_MODEL: &str = "gpt-5-mini";

/// Built-in fallback catalogue. Deliberately short and overridable; the exact
/// set is data, not logic — the picker works with whatever list it is given.
const DEFAULT_MODELS: &[&str] = &[
    AUTO_MODEL,
    "claude-opus-4.5",
    "claude-sonnet-4.5",
    "claude-sonnet-4",
    "gpt-5.4",
    "gpt-5",
    "gpt-5-mini",
    "o4-mini",
    "gemini-2.5-pro",
];

/// Parse a raw model list, splitting on commas and whitespace, trimming, and
/// dropping empties and duplicates while preserving order. `auto` is always
/// guaranteed to be present (prepended when missing) so the default is always
/// selectable. Pure for testing.
pub fn parse_models(raw: &str) -> Vec<String> {
    let mut models: Vec<String> = Vec::new();
    for token in raw.split([',', ' ', '\t', '\n', '\r']) {
        let token = token.trim();
        if token.is_empty() || models.iter().any(|m| m == token) {
            continue;
        }
        models.push(token.to_string());
    }
    if !models.iter().any(|m| m == AUTO_MODEL) {
        models.insert(0, AUTO_MODEL.to_string());
    }
    models
}

/// The models to offer, honouring `COPILOT_MODELS` then falling back to the
/// built-in list.
pub fn available() -> Vec<String> {
    match std::env::var(MODELS_ENV) {
        Ok(raw) if !raw.trim().is_empty() => parse_models(&raw),
        _ => DEFAULT_MODELS.iter().map(|m| m.to_string()).collect(),
    }
}

/// Whether a model id is the "auto" sentinel (case-insensitive).
pub fn is_auto(model: &str) -> bool {
    model.eq_ignore_ascii_case(AUTO_MODEL)
}

/// Resolve the model that writes the close summary (#161).
///
/// `SUMMARY_MODEL` wins when set to a real id; unset (or empty) falls back to the
/// built-in light [`DEFAULT_SUMMARY_MODEL`] so the summary stays cheap by default.
/// `auto`/`off`/`none`/`0` return `None` so no `--model` is passed and Copilot
/// picks — the feature's on/off switch lives separately in the TUI, so this only
/// chooses *which* model, never whether to summarize.
pub fn summary_model() -> Option<String> {
    resolve_summary_model(std::env::var(SUMMARY_MODEL_ENV).ok().as_deref())
}

/// Pure core of [`summary_model`]: map a raw `SUMMARY_MODEL` value (or `None`
/// when unset) to the model to use, or `None` for "let Copilot pick". Pure for
/// testing.
pub fn resolve_summary_model(raw: Option<&str>) -> Option<String> {
    let trimmed = raw.unwrap_or_default().trim();
    match trimmed.to_ascii_lowercase().as_str() {
        "" => Some(DEFAULT_SUMMARY_MODEL.to_string()),
        "auto" | "off" | "none" | "0" => None,
        _ => Some(trimmed.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_list_leads_with_auto() {
        let models = available();
        assert_eq!(models.first().map(String::as_str), Some(AUTO_MODEL));
        assert!(models.len() > 1);
    }

    #[test]
    fn parse_splits_on_commas_and_whitespace() {
        let models = parse_models("auto, gpt-5.4\nclaude-opus-4.5  o4-mini");
        assert_eq!(
            models,
            vec!["auto", "gpt-5.4", "claude-opus-4.5", "o4-mini"]
        );
    }

    #[test]
    fn parse_dedupes_and_drops_empties() {
        let models = parse_models("gpt-5,,gpt-5, ,gpt-5-mini");
        assert_eq!(models, vec!["auto", "gpt-5", "gpt-5-mini"]);
    }

    #[test]
    fn parse_prepends_auto_when_missing() {
        assert_eq!(parse_models("gpt-5")[0], "auto");
    }

    #[test]
    fn parse_keeps_existing_auto_position() {
        let models = parse_models("gpt-5, auto, gpt-5-mini");
        assert_eq!(models, vec!["gpt-5", "auto", "gpt-5-mini"]);
    }

    #[test]
    fn is_auto_is_case_insensitive() {
        assert!(is_auto("auto"));
        assert!(is_auto("AUTO"));
        assert!(!is_auto("gpt-5"));
    }

    #[test]
    fn summary_model_defaults_to_the_light_model_when_unset_or_empty() {
        assert_eq!(
            resolve_summary_model(None).as_deref(),
            Some(DEFAULT_SUMMARY_MODEL)
        );
        assert_eq!(
            resolve_summary_model(Some("   ")).as_deref(),
            Some(DEFAULT_SUMMARY_MODEL)
        );
    }

    #[test]
    fn summary_model_uses_an_explicit_id_verbatim() {
        assert_eq!(
            resolve_summary_model(Some(" o4-mini ")).as_deref(),
            Some("o4-mini")
        );
    }

    #[test]
    fn summary_model_disable_words_mean_let_copilot_pick() {
        for raw in ["auto", "off", "None", "0"] {
            assert_eq!(resolve_summary_model(Some(raw)), None, "raw = {raw}");
        }
    }
}
