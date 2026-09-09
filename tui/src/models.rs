//! Discovering and caching the Copilot models offered in the picker.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Sentinel model meaning "let Copilot choose".
pub const AUTO_MODEL: &str = "auto";

/// Models stay current for one day before the next TUI start refreshes them.
pub const MODEL_CACHE_TTL_SECS: u64 = 24 * 60 * 60;

const CACHE_FILE: &str = "models.json";
const MODEL_LIST_PROMPT: &str = "/model --list --json";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ModelCache {
    fetched_at: u64,
    models: Vec<String>,
}

/// The repository-local cache path. It lives beside the other ignored TUI state.
pub fn cache_path(repo_root: &Path) -> PathBuf {
    repo_root.join(".copilot-loop").join("tui").join(CACHE_FILE)
}

/// The safe picker fallback when Copilot cannot provide a model list.
pub fn fallback() -> Vec<String> {
    vec![AUTO_MODEL.to_string()]
}

/// Parse Copilot's JSON model response and return model IDs with `auto` added.
/// Accepts either `{ "models": [...] }` or a bare array for small CLI format
/// changes. Pure for testing.
pub fn parse_model_list(raw: &str) -> Option<Vec<String>> {
    parse_json_model_list(raw).or_else(|| {
        let block = raw.split("```").nth(1)?.trim_start();
        parse_json_model_list(block.strip_prefix("json").unwrap_or(block).trim())
    })
}

fn parse_json_model_list(raw: &str) -> Option<Vec<String>> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let entries = value
        .get("models")
        .and_then(Value::as_array)
        .or_else(|| value.as_array())?;

    let mut ids = Vec::new();
    for entry in entries {
        let Some(id) = entry
            .as_str()
            .or_else(|| entry.get("id").and_then(Value::as_str))
        else {
            continue;
        };
        let id = id.trim();
        if !id.is_empty() && !ids.iter().any(|known| known == id) {
            ids.push(id.to_string());
        }
    }

    (!ids.is_empty()).then(|| with_auto(ids))
}

/// Load the cached list, refreshing it only when it is older than a day.
pub fn available(repo_root: &Path) -> Vec<String> {
    let path = cache_path(repo_root);
    let cached = load_cache(&path);
    let now = unix_now();

    if let Some(cache) = cached.as_ref()
        && cache_is_fresh(cache.fetched_at, now)
    {
        return cache.models.clone();
    }

    match fetch(repo_root) {
        Ok(models) => {
            save_cache(&path, now, &models);
            models
        }
        Err(_) => {
            let models = cached.map(|cache| cache.models).unwrap_or_else(fallback);
            save_cache(&path, now, &models);
            models
        }
    }
}

/// Whether a cached fetch is younger than the refresh interval. Pure for testing.
pub fn cache_is_fresh(fetched_at: u64, now: u64) -> bool {
    now >= fetched_at && now - fetched_at < MODEL_CACHE_TTL_SECS
}

/// Whether a model ID is the `auto` sentinel (case-insensitive).
pub fn is_auto(model: &str) -> bool {
    model.eq_ignore_ascii_case(AUTO_MODEL)
}

/// Environment variable overriding the model that writes the close summary (#161).
pub const SUMMARY_MODEL_ENV: &str = "SUMMARY_MODEL";

/// Default *light* model used to summarize a closed issue's session, chosen to
/// keep the summary cheap (#161). It is separate from the picker catalogue.
pub const DEFAULT_SUMMARY_MODEL: &str = "gpt-5-mini";

/// Resolve the model that writes the close summary (#161).
pub fn summary_model() -> Option<String> {
    resolve_summary_model(std::env::var(SUMMARY_MODEL_ENV).ok().as_deref())
}

/// Pure core of [`summary_model`]: map a raw `SUMMARY_MODEL` value (or `None`
/// when unset) to the model to use, or `None` for "let Copilot pick".
pub fn resolve_summary_model(raw: Option<&str>) -> Option<String> {
    let trimmed = raw.unwrap_or_default().trim();
    match trimmed.to_ascii_lowercase().as_str() {
        "" => Some(DEFAULT_SUMMARY_MODEL.to_string()),
        "auto" | "off" | "none" | "0" => None,
        _ => Some(trimmed.to_string()),
    }
}

fn with_auto(mut models: Vec<String>) -> Vec<String> {
    if !models.iter().any(|model| is_auto(model)) {
        models.insert(0, AUTO_MODEL.to_string());
    }
    models
}

fn fetch(repo_root: &Path) -> Result<Vec<String>> {
    let output = Command::new("copilot")
        .current_dir(repo_root)
        .args(["--silent", "-p", MODEL_LIST_PROMPT])
        .output()
        .context("failed to run `copilot` while loading models")?;
    if !output.status.success() {
        anyhow::bail!("`copilot` model list failed");
    }
    parse_model_list(&String::from_utf8_lossy(&output.stdout))
        .context("`copilot` returned an unreadable model list")
}

fn load_cache(path: &Path) -> Option<ModelCache> {
    let raw = fs::read_to_string(path).ok()?;
    let mut cache: ModelCache = serde_json::from_str(&raw).ok()?;
    cache.models = with_auto(cache.models);
    Some(cache)
}

fn save_cache(path: &Path, fetched_at: u64, models: &[String]) {
    let Some(parent) = path.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let cache = ModelCache {
        fetched_at,
        models: models.to_vec(),
    };
    if let Ok(raw) = serde_json::to_string_pretty(&cache) {
        let _ = fs::write(path, raw);
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_is_auto_only() {
        assert_eq!(fallback(), vec![AUTO_MODEL]);
    }

    #[test]
    fn parse_model_list_extracts_ids_and_deduplicates() {
        let models = parse_model_list(
            r#"{"models":[{"id":"gpt-5.4","name":"GPT-5.4"},{"id":"gpt-5.4"},"claude-sonnet-5"]}"#,
        )
        .unwrap();
        assert_eq!(models, vec!["auto", "gpt-5.4", "claude-sonnet-5"]);
    }

    #[test]
    fn parse_model_list_accepts_a_bare_array() {
        assert_eq!(
            parse_model_list(r#"["gpt-5.4"]"#).unwrap(),
            vec!["auto", "gpt-5.4"]
        );
    }

    #[test]
    fn parse_model_list_accepts_a_fenced_json_response() {
        assert_eq!(
            parse_model_list("Here is the list:\n```json\n[\"gpt-5.4\"]\n```").unwrap(),
            vec!["auto", "gpt-5.4"]
        );
    }

    #[test]
    fn parse_model_list_rejects_empty_or_invalid_json() {
        assert_eq!(parse_model_list(r#"{"models":[]}"#), None);
        assert_eq!(parse_model_list("not json"), None);
    }

    #[test]
    fn cache_expires_after_one_day() {
        assert!(cache_is_fresh(100, 100 + MODEL_CACHE_TTL_SECS - 1));
        assert!(!cache_is_fresh(100, 100 + MODEL_CACHE_TTL_SECS));
        assert!(!cache_is_fresh(100, 99));
    }

    #[test]
    fn cache_path_is_under_the_ignored_tui_state_dir() {
        assert_eq!(
            cache_path(Path::new("/repo")),
            PathBuf::from("/repo/.copilot-loop/tui/models.json")
        );
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
