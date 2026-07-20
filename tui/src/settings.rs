//! Persisting the user's TUI settings so their choices survive across runs (#195).
//!
//! When a user changes the model, toggles auto-merge, quality-assurance, or the
//! close summary, those choices are written to a small JSON file under the
//! repository's ignored `.copilot-loop/` directory and reloaded on the next
//! start. The file is *data*, not logic: a missing or corrupt file simply falls
//! back to the built-in defaults, so a bad edit never blocks the TUI.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The user-tunable loop settings persisted between runs (#195): the coding
/// model, whether PRs auto-merge, whether quality-assurance tests run, and
/// whether closing an issue posts a summary. Mirrors the toggles in the TUI so
/// what the user last chose is restored on the next start.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    /// The chosen coding model, or `None` for `auto` (let Copilot pick).
    #[serde(default)]
    pub model: Option<String>,
    /// Whether the loop enables GitHub auto-merge on each PR (#135). Off by default.
    #[serde(default)]
    pub auto_merge: bool,
    /// Whether the loop keeps quality-assurance tests on (#162). On by default.
    #[serde(default = "enabled")]
    pub quality_assurance: bool,
    /// Whether closing an issue posts a summary comment (#161). On by default.
    #[serde(default = "enabled")]
    pub report_on_close: bool,
}

/// Serde default for the flags that are on unless the user turns them off, so a
/// settings file missing those keys keeps the built-in "on" behaviour.
fn enabled() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            model: None,
            auto_merge: false,
            quality_assurance: true,
            report_on_close: true,
        }
    }
}

/// Where the TUI stores the persisted settings: alongside the worker logs under
/// the repository's ignored `.copilot-loop/tui/` directory. Pure for testing.
pub fn settings_path(repo_root: &Path) -> PathBuf {
    repo_root
        .join(".copilot-loop")
        .join("tui")
        .join("settings.json")
}

/// Parse a raw settings JSON string, or `None` when it is not valid settings so
/// the caller falls back to defaults. Pure for testing.
pub fn parse(raw: &str) -> Option<Settings> {
    serde_json::from_str(raw).ok()
}

/// Render settings as pretty JSON for writing to disk. Pure for testing.
pub fn to_json(settings: &Settings) -> String {
    serde_json::to_string_pretty(settings).unwrap_or_default()
}

/// Load persisted settings from `path`, or `None` when the file is missing or
/// unreadable/corrupt so the caller keeps its defaults.
pub fn load(path: &Path) -> Option<Settings> {
    let raw = fs::read_to_string(path).ok()?;
    parse(&raw)
}

/// Write `settings` to `path`, creating the parent directory if needed. Errors
/// are returned so the caller can decide whether to surface them; persistence is
/// best-effort and never blocks the UI.
pub fn save(path: &Path, settings: &Settings) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, to_json(settings))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A unique temp directory for a test, without pulling in a temp-file crate:
    /// combine the process id and a per-test counter so parallel tests never
    /// collide.
    fn temp_dir(tag: &str) -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "copilot-loop-settings-{}-{}-{}",
            std::process::id(),
            tag,
            n
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn default_settings_are_auto_off_on_on() {
        let s = Settings::default();
        assert_eq!(s.model, None);
        assert!(!s.auto_merge);
        assert!(s.quality_assurance);
        assert!(s.report_on_close);
    }

    #[test]
    fn save_then_load_round_trips() {
        let dir = temp_dir("roundtrip");
        let path = settings_path(&dir);
        let settings = Settings {
            model: Some("gpt-5.4".to_string()),
            auto_merge: true,
            quality_assurance: false,
            report_on_close: false,
        };
        save(&path, &settings).unwrap();
        assert_eq!(load(&path), Some(settings));
    }

    #[test]
    fn save_creates_the_parent_directory() {
        let dir = temp_dir("mkdir");
        let path = settings_path(&dir);
        assert!(!path.parent().unwrap().exists());
        save(&path, &Settings::default()).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn load_missing_file_is_none() {
        let dir = temp_dir("missing");
        assert_eq!(load(&settings_path(&dir)), None);
    }

    #[test]
    fn parse_missing_flags_keep_the_on_defaults() {
        // A file that only records the model must not silently turn QA and the
        // close summary off — the omitted flags stay on.
        let s = parse(r#"{"model":"gpt-5.4"}"#).unwrap();
        assert_eq!(s.model.as_deref(), Some("gpt-5.4"));
        assert!(s.quality_assurance);
        assert!(s.report_on_close);
        assert!(!s.auto_merge);
    }

    #[test]
    fn parse_invalid_json_is_none() {
        assert_eq!(parse("not json"), None);
    }

    #[test]
    fn settings_path_lives_under_the_ignored_copilot_loop_dir() {
        let path = settings_path(Path::new("/repo"));
        assert_eq!(path, PathBuf::from("/repo/.copilot-loop/tui/settings.json"));
    }
}
