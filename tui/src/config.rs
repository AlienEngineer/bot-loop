//! User-level configuration file at `~/.config/bot-loop.yaml`.
//!
//! Controls how many bots the TUI spawns automatically on startup, keyed by
//! model. A missing, empty, or invalid config file is treated as "no automatic
//! spawns" so a bad edit never blocks the TUI.
//!
//! The count may carry a reasoning effort, forwarded to `copilot --effort`.
//! Copilot does not persist the effort picked in an interactive session, so it
//! has to be set here.
//!
//! Example `~/.config/bot-loop.yaml`:
//!
//! ```yaml
//! bots:
//!   automatic-spawn:
//!     claude-opus 4.5: 5
//!     gpt-5.6-luna: 3 max
//!     auto: 10
//! ```

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

/// The root configuration structure.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BotLoopConfig {
    pub bots: BotsConfig,
}

/// The `bots:` section.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BotsConfig {
    /// Model name → how many bots to spawn automatically on TUI startup and the
    /// reasoning effort they run at (`None` = the model's own default).
    pub automatic_spawn: HashMap<String, (usize, Option<String>)>,
}

/// A single entry in the automatic-spawn plan: start `count` workers using
/// `model` (`None` = auto) at `effort` (`None` = the model's own default).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnEntry {
    /// The model to pass to the loop (`None` = let Copilot pick / `auto`).
    pub model: Option<String>,
    pub count: usize,
    /// The reasoning effort to pass to the loop (`None` = the model's default).
    pub effort: Option<String>,
}

/// The reasoning effort levels `copilot --effort` accepts. `copilot` exits on
/// any other value, so the config parser drops what is not in this list.
pub const EFFORT_LEVELS: [&str; 7] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// Parse the value side of an `automatic-spawn` entry: a count, optionally
/// followed by a reasoning effort (`"3 max"`). An effort outside
/// [`EFFORT_LEVELS`] is dropped. Pure for testing.
pub fn parse_spawn_value(raw: &str) -> Option<(usize, Option<String>)> {
    let mut parts = raw.split_whitespace();
    let count = parts.next()?.parse::<usize>().ok()?;
    let effort = parts
        .next()
        .map(str::to_ascii_lowercase)
        .filter(|level| EFFORT_LEVELS.contains(&level.as_str()));
    Some((count, effort))
}

/// The resolved path to `~/.config/bot-loop.yaml`. `None` when the home
/// directory cannot be determined.
pub fn config_path() -> Option<PathBuf> {
    home_dir().map(|h| h.join(".config").join("bot-loop.yaml"))
}

/// Load and parse `~/.config/bot-loop.yaml`. Returns `None` (empty config) when
/// the file is absent, unreadable, or cannot be parsed, so startup is never
/// blocked by a bad config.
pub fn load() -> BotLoopConfig {
    load_from(config_path().as_deref())
}

/// Like [`load`] but reads from an explicit path, for testing.
pub fn load_from(path: Option<&std::path::Path>) -> BotLoopConfig {
    let Some(path) = path else {
        return BotLoopConfig::default();
    };
    let raw = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(_) => return BotLoopConfig::default(),
    };
    parse(&raw).unwrap_or_default()
}

/// Parse a raw YAML string into a [`BotLoopConfig`]. Returns `None` when the
/// YAML cannot be interpreted as config.
pub fn parse(raw: &str) -> Option<BotLoopConfig> {
    // Minimal hand-rolled YAML parser: we only need to handle the specific
    // shape:
    //   bots:
    //     automatic-spawn:
    //       <model>: <count>
    //
    // This avoids adding a YAML crate dependency.
    let mut automatic_spawn = HashMap::new();
    let mut in_bots = false;
    let mut in_auto_spawn = false;

    for line in raw.lines() {
        // Skip comments and blank lines.
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        // Count leading spaces to determine nesting level.
        let indent = line.len() - line.trim_start().len();

        if indent == 0 {
            in_bots = trimmed == "bots:";
            in_auto_spawn = false;
            continue;
        }

        if !in_bots {
            continue;
        }

        if indent == 2 {
            in_auto_spawn = trimmed == "automatic-spawn:";
            continue;
        }

        if !in_auto_spawn || indent < 4 {
            continue;
        }

        // Parse "<model>: <count> [<effort>]" lines.
        if let Some((key, val)) = trimmed.split_once(':') {
            let model = key.trim().to_string();
            if let Some((count, effort)) = parse_spawn_value(val)
                && count > 0
                && !model.is_empty()
            {
                automatic_spawn.insert(model, (count, effort));
            }
        }
    }

    Some(BotLoopConfig {
        bots: BotsConfig { automatic_spawn },
    })
}

/// Expand the `automatic-spawn` map into an ordered list of [`SpawnEntry`]
/// values, one per model. The model string `"auto"` is normalised to `None` so
/// it forwards to Copilot's own picker. Entries with count 0 are dropped.
pub fn spawn_plan(config: &BotLoopConfig) -> Vec<SpawnEntry> {
    let mut entries: Vec<SpawnEntry> = config
        .bots
        .automatic_spawn
        .iter()
        .filter(|(_, (count, _))| *count > 0)
        .map(|(model, (count, effort))| SpawnEntry {
            model: if crate::models::is_auto(model.trim()) {
                None
            } else {
                Some(model.clone())
            },
            count: *count,
            effort: effort.clone(),
        })
        .collect();
    // Stable sort so tests are deterministic (alphabetical by model display name,
    // with None last).
    entries.sort_by(|a, b| match (&a.model, &b.model) {
        (Some(ma), Some(mb)) => ma.cmp(mb),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => std::cmp::Ordering::Equal,
    });
    entries
}

/// The current user's home directory. Checks `HOME` first (Unix), then
/// `USERPROFILE` (Windows). Returns `None` when neither is set (rare, but safe).
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_yaml_with_multiple_models() {
        let yaml = r#"
bots:
  automatic-spawn:
    claude-opus 4.5: 5
    claude-opus 5: 2
    auto: 10
"#;
        let config = parse(yaml).unwrap();
        assert_eq!(config.bots.automatic_spawn["claude-opus 4.5"].0, 5);
        assert_eq!(config.bots.automatic_spawn["claude-opus 5"].0, 2);
        assert_eq!(config.bots.automatic_spawn["auto"].0, 10);
    }

    #[test]
    fn parse_missing_file_returns_default() {
        let config = load_from(Some(std::path::Path::new(
            "/nonexistent/path/bot-loop.yaml",
        )));
        assert!(config.bots.automatic_spawn.is_empty());
    }

    #[test]
    fn parse_invalid_yaml_returns_empty_config() {
        let config = parse("not: valid: yaml: at: all:").unwrap();
        // Should not crash, just return empty automatic-spawn.
        assert!(config.bots.automatic_spawn.is_empty());
    }

    #[test]
    fn parse_empty_string_returns_empty_config() {
        let config = parse("").unwrap();
        assert!(config.bots.automatic_spawn.is_empty());
    }

    #[test]
    fn load_from_none_path_returns_default() {
        let config = load_from(None);
        assert!(config.bots.automatic_spawn.is_empty());
    }

    #[test]
    fn spawn_plan_normalises_auto_to_none() {
        let yaml = "bots:\n  automatic-spawn:\n    auto: 3\n";
        let config = parse(yaml).unwrap();
        let plan = spawn_plan(&config);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].model, None);
        assert_eq!(plan[0].count, 3);
    }

    #[test]
    fn spawn_plan_keeps_named_model() {
        let yaml = "bots:\n  automatic-spawn:\n    claude-opus 4.5: 2\n";
        let config = parse(yaml).unwrap();
        let plan = spawn_plan(&config);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].model.as_deref(), Some("claude-opus 4.5"));
        assert_eq!(plan[0].count, 2);
    }

    #[test]
    fn spawn_plan_drops_zero_count_entries() {
        let yaml = "bots:\n  automatic-spawn:\n    gpt-4o: 0\n    claude-opus 4.5: 1\n";
        let config = parse(yaml).unwrap();
        let plan = spawn_plan(&config);
        assert_eq!(plan.len(), 1);
    }

    #[test]
    fn parse_reads_the_effort_after_the_count() {
        let yaml = "bots:\n  automatic-spawn:\n    gpt-5.6-luna: 3 max\n";
        let plan = spawn_plan(&parse(yaml).unwrap());
        assert_eq!(plan[0].count, 3);
        assert_eq!(plan[0].effort.as_deref(), Some("max"));
    }

    #[test]
    fn parse_drops_an_unknown_effort_but_keeps_the_count() {
        assert_eq!(parse_spawn_value("3 turbo"), Some((3, None)));
        assert_eq!(parse_spawn_value("3"), Some((3, None)));
        assert_eq!(parse_spawn_value("3 MAX"), Some((3, Some("max".into()))));
        assert_eq!(parse_spawn_value("max"), None);
    }

    #[test]
    fn parse_ignores_comments_and_blank_lines() {
        let yaml = r#"
# This is a comment
bots:
  # Another comment
  automatic-spawn:
    # Model list
    claude-opus 4.5: 3
"#;
        let config = parse(yaml).unwrap();
        assert_eq!(config.bots.automatic_spawn["claude-opus 4.5"].0, 3);
    }

    #[test]
    fn parse_actual_file_roundtrip() {
        use std::io::Write;
        let dir =
            std::env::temp_dir().join(format!("copilot-loop-config-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("bot-loop.yaml");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(
            f,
            "bots:\n  automatic-spawn:\n    claude-opus 4.5: 2\n    auto: 5\n"
        )
        .unwrap();
        let config = load_from(Some(&path));
        assert_eq!(config.bots.automatic_spawn["claude-opus 4.5"].0, 2);
        assert_eq!(config.bots.automatic_spawn["auto"].0, 5);
    }
}
