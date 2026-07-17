//! GitHub issue model and retrieval via the `gh` CLI.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::process::Command;

/// A label attached to an issue.
#[derive(Debug, Clone, Deserialize)]
pub struct Label {
    pub name: String,
}

/// The author of an issue.
#[derive(Debug, Clone, Deserialize)]
pub struct Author {
    #[serde(default)]
    pub login: String,
}

/// A single GitHub issue, mapped from `gh issue list --json ...`.
#[derive(Debug, Clone, Deserialize)]
pub struct Issue {
    pub number: u64,
    pub title: String,
    #[serde(default)]
    pub labels: Vec<Label>,
    #[serde(default)]
    pub author: Option<Author>,
}

impl Issue {
    /// The issue's label names, in order.
    pub fn label_names(&self) -> Vec<&str> {
        self.labels.iter().map(|l| l.name.as_str()).collect()
    }

    /// The author login, or an empty string when unknown.
    pub fn author_login(&self) -> &str {
        self.author.as_ref().map(|a| a.login.as_str()).unwrap_or("")
    }
}

/// The `gh` JSON fields requested for each issue.
const GH_JSON_FIELDS: &str = "number,title,labels,author";

/// Parse the JSON array produced by `gh issue list --json ...`.
pub fn parse_issues(json: &str) -> Result<Vec<Issue>> {
    serde_json::from_str(json).context("failed to parse `gh issue list` JSON output")
}

/// Fetch open issues for the current repository using the `gh` CLI.
///
/// Runs `gh issue list` and parses its JSON output. Returns an error when `gh`
/// is missing, not authenticated, or the command otherwise fails.
pub fn fetch_issues(limit: u32) -> Result<Vec<Issue>> {
    let output = Command::new("gh")
        .args([
            "issue",
            "list",
            "--state",
            "open",
            "--limit",
            &limit.to_string(),
            "--json",
            GH_JSON_FIELDS,
        ])
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "`gh issue list` failed: {}",
            stderr.trim().replace('\n', " ")
        );
    }

    parse_issues(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"[
        {"number": 96, "title": "create a TUI", "state": "OPEN",
         "labels": [{"name": "in-progress"}], "author": {"login": "octocat"}},
        {"number": 51, "title": "make the TUI in rust", "state": "OPEN",
         "labels": [], "author": {"login": "hubot"}}
    ]"#;

    #[test]
    fn parses_a_list_of_issues() {
        let issues = parse_issues(SAMPLE).expect("should parse");
        assert_eq!(issues.len(), 2);
        assert_eq!(issues[0].number, 96);
        assert_eq!(issues[0].title, "create a TUI");
        assert_eq!(issues[0].label_names(), vec!["in-progress"]);
        assert_eq!(issues[0].author_login(), "octocat");
    }

    #[test]
    fn parses_an_empty_list() {
        let issues = parse_issues("[]").expect("should parse");
        assert!(issues.is_empty());
    }

    #[test]
    fn tolerates_missing_optional_fields() {
        let json = r#"[{"number": 1, "title": "bare"}]"#;
        let issues = parse_issues(json).expect("should parse");
        assert_eq!(issues.len(), 1);
        assert!(issues[0].labels.is_empty());
        assert_eq!(issues[0].author_login(), "");
    }

    #[test]
    fn reports_invalid_json() {
        assert!(parse_issues("not json").is_err());
    }

    #[test]
    fn ignores_extra_fields_from_real_gh_output() {
        // Shape mirrors real `gh issue list --json ...`: nested objects carry
        // fields we do not model (id, is_bot, name, color, description).
        let json = r#"[{
            "author": {"id": "MDQ6VX", "is_bot": false, "login": "AlienEngineer", "name": "Sérgio"},
            "labels": [{"id": "LA_k", "name": "in-progress", "description": "wip", "color": "fbca04"}],
            "number": 96,
            "title": "create a TUI that displays a list of github issues"
        }]"#;
        let issues = parse_issues(json).expect("should ignore unknown fields");
        assert_eq!(issues.len(), 1);
        assert_eq!(issues[0].number, 96);
        assert_eq!(issues[0].author_login(), "AlienEngineer");
        assert_eq!(issues[0].label_names(), vec!["in-progress"]);
    }
}
