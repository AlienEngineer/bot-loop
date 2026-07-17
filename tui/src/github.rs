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

/// A comment on an issue. Only the body is modelled; the TUI reads the loop's
/// per-run cost out of it (the `AI Credits` line in a usage comment) so a closed
/// issue's total spend can be shown (#145).
#[derive(Debug, Clone, Deserialize)]
pub struct Comment {
    #[serde(default)]
    pub body: String,
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
    /// The issue's comments, requested only for the closed-issue view so each
    /// row's AI Credits spend can be totalled. Empty for the open list, which
    /// does not request comments (#145).
    #[serde(default)]
    pub comments: Vec<Comment>,
}

impl Issue {
    /// The issue's label names, in order.
    pub fn label_names(&self) -> Vec<&str> {
        self.labels.iter().map(|l| l.name.as_str()).collect()
    }

    /// Whether the issue already carries a label with the given name.
    pub fn has_label(&self, name: &str) -> bool {
        self.labels.iter().any(|l| l.name == name)
    }

    /// Whether the loop is currently working this issue (carries the
    /// in-progress label the loop adds while it runs).
    pub fn is_in_progress(&self) -> bool {
        self.has_label(IN_PROGRESS_LABEL)
    }

    /// The author login, or an empty string when unknown.
    pub fn author_login(&self) -> &str {
        self.author.as_ref().map(|a| a.login.as_str()).unwrap_or("")
    }

    /// Total AI Credits the loop spent on this issue, summed across every
    /// copilot-loop usage comment in its thread, or `None` when the issue
    /// carries no usage comment (e.g. closed by hand or never worked) (#145).
    pub fn credits_spent(&self) -> Option<f64> {
        let mut total = 0.0;
        let mut found = false;
        for comment in &self.comments {
            if let Some(credits) = parse_comment_credits(&comment.body) {
                total += credits;
                found = true;
            }
        }
        found.then_some(total)
    }
}

/// Parse the AI Credits figure from a single copilot-loop usage comment body, or
/// `None` when the comment is not a usage comment (missing [`USAGE_MARKER`]) or
/// carries no recognisable credits line. Both the current `AI Credits` label and
/// the legacy `Premium requests` label are accepted, mirroring
/// `parse_usage_stats` in `copilot-loop.sh`. Pure for testing (#145).
fn parse_comment_credits(body: &str) -> Option<f64> {
    if !body.contains(USAGE_MARKER) {
        return None;
    }
    for line in body.lines() {
        let line = line.trim();
        for label in ["AI Credits", "Premium requests"] {
            if let Some(rest) = line.strip_prefix(label) {
                let number: String = rest
                    .trim_start()
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == '.')
                    .collect();
                if let Ok(value) = number.parse::<f64>() {
                    return Some(value);
                }
            }
        }
    }
    None
}

/// A pull request the loop is working, mapped from `gh pr list --json ...`.
///
/// Only the fields the TUI needs to name the PR are modelled; the loop keys a
/// PR as "being worked" off the same [`IN_PROGRESS_LABEL`] it adds to issues, so
/// the query filters on that label rather than carrying it here (#133).
#[derive(Debug, Clone, Deserialize)]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
}

/// The `gh` JSON fields requested for each issue.
const GH_JSON_FIELDS: &str = "number,title,labels,author";

/// The `gh` JSON fields requested for each closed issue: the issue fields plus
/// its comments, so the loop's per-run cost can be totalled per issue (#145).
const GH_CLOSED_JSON_FIELDS: &str = "number,title,labels,author,comments";

/// The `gh` JSON fields requested for each in-progress pull request.
const GH_PR_JSON_FIELDS: &str = "number,title";

/// The label the loop watches for, when `TRIGGER_LABEL` is unset.
pub const READY_LABEL: &str = "ready";

/// Hidden marker `copilot-loop.sh` tags every per-run cost comment with (its
/// `USAGE_MARKER`), so the TUI can pick the loop's usage comments out of an
/// issue's thread when totalling spend (#145).
pub const USAGE_MARKER: &str = "<!-- copilot-loop:usage -->";

/// The label the loop adds to an issue while it is actively working on it,
/// mirroring `INPROGRESS_LABEL` in `copilot-loop.sh`. The TUI keys its
/// "which issue is the loop working" display off this label (#115).
pub const IN_PROGRESS_LABEL: &str = "in-progress";

/// Resolve the trigger label from an optional env value, mirroring the loop's
/// `TRIGGER_LABEL="${TRIGGER_LABEL:-ready}"`. Empty falls back to the default.
fn resolve_label(env: Option<String>) -> String {
    env.filter(|s| !s.is_empty())
        .unwrap_or_else(|| READY_LABEL.to_string())
}

/// The label to add when marking an issue ready, honouring `TRIGGER_LABEL` so
/// the TUI and `copilot-loop.sh` stay in sync.
pub fn ready_label() -> String {
    resolve_label(std::env::var("TRIGGER_LABEL").ok())
}

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

/// Fetch the most recently updated closed issues for the current repository,
/// including their comments so the loop's per-run cost can be totalled per issue
/// (#145).
///
/// Runs `gh issue list --state closed` requesting each issue's comments, then
/// parses the JSON. Returns an error when `gh` is missing, not authenticated, or
/// the command otherwise fails.
pub fn fetch_closed_issues(limit: u32) -> Result<Vec<Issue>> {
    let output = Command::new("gh")
        .args([
            "issue",
            "list",
            "--state",
            "closed",
            "--limit",
            &limit.to_string(),
            "--json",
            GH_CLOSED_JSON_FIELDS,
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
pub fn parse_pull_requests(json: &str) -> Result<Vec<PullRequest>> {
    serde_json::from_str(json).context("failed to parse `gh pr list` JSON output")
}

/// Fetch the open pull requests the loop is currently working, i.e. those
/// carrying the in-progress label (#133).
///
/// PRs are not returned by `gh issue list`, so a PR the loop is resolving
/// (conflicts or failing checks) is invisible to the issue view. Listing the
/// in-progress ones lets the TUI show that work is happening. Returns an error
/// when `gh` is missing, not authenticated, or the command otherwise fails.
pub fn fetch_in_progress_prs() -> Result<Vec<PullRequest>> {
    let output = Command::new("gh")
        .args([
            "pr",
            "list",
            "--state",
            "open",
            "--label",
            IN_PROGRESS_LABEL,
            "--json",
            GH_PR_JSON_FIELDS,
        ])
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("`gh pr list` failed: {}", stderr.trim().replace('\n', " "));
    }

    parse_pull_requests(&String::from_utf8_lossy(&output.stdout))
}

/// Build the `gh issue edit` arguments to add a label. Pure for testing.
fn add_label_args(number: u64, label: &str) -> Vec<String> {
    vec![
        "issue".to_string(),
        "edit".to_string(),
        number.to_string(),
        "--add-label".to_string(),
        label.to_string(),
    ]
}

/// Build the `gh label create` arguments used to ensure the label exists. Pure
/// for testing. Mirrors `ensure_label` in `copilot-loop.sh` (same colour/desc).
fn create_label_args(label: &str) -> Vec<String> {
    vec![
        "label".to_string(),
        "create".to_string(),
        label.to_string(),
        "--color".to_string(),
        "0e8a16".to_string(),
        "--description".to_string(),
        "Ready for the copilot loop to pick up".to_string(),
    ]
}

/// Add a label to an issue using the `gh` CLI.
///
/// First ensures the label exists (`gh issue edit --add-label` fails on an
/// unknown label), ignoring the "already exists" error the same way the loop's
/// `ensure_label` does. Then runs `gh issue edit <number> --add-label <label>`.
/// Returns an error when `gh` is missing, not authenticated, or the edit fails.
pub fn add_label(number: u64, label: &str) -> Result<()> {
    // Best-effort create; a failure here (usually "already exists") is ignored
    // so a genuine problem surfaces on the edit below instead.
    let _ = Command::new("gh").args(create_label_args(label)).output();

    let output = Command::new("gh")
        .args(add_label_args(number, label))
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "`gh issue edit` failed: {}",
            stderr.trim().replace('\n', " ")
        );
    }

    Ok(())
}

/// Build the `gh issue edit` arguments to remove a label. Pure for testing.
fn remove_label_args(number: u64, label: &str) -> Vec<String> {
    vec![
        "issue".to_string(),
        "edit".to_string(),
        number.to_string(),
        "--remove-label".to_string(),
        label.to_string(),
    ]
}

/// Remove a label from an issue using the `gh` CLI.
///
/// Runs `gh issue edit <number> --remove-label <label>`. Unlike [`add_label`]
/// there is no need to ensure the label exists first. Returns an error when
/// `gh` is missing, not authenticated, or the edit fails.
pub fn remove_label(number: u64, label: &str) -> Result<()> {
    let output = Command::new("gh")
        .args(remove_label_args(number, label))
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "`gh issue edit` failed: {}",
            stderr.trim().replace('\n', " ")
        );
    }

    Ok(())
}

/// Build the `gh issue close` arguments. Pure for testing.
fn close_issue_args(number: u64) -> Vec<String> {
    vec!["issue".to_string(), "close".to_string(), number.to_string()]
}

/// Close a GitHub issue by number using the `gh` CLI.
///
/// Runs `gh issue close <number>`. Returns an error when `gh` is missing, not
/// authenticated, or the command otherwise fails.
pub fn close_issue(number: u64) -> Result<()> {
    let output = Command::new("gh")
        .args(close_issue_args(number))
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "`gh issue close` failed: {}",
            stderr.trim().replace('\n', " ")
        );
    }

    Ok(())
}

/// Build the `gh issue create` arguments for a new issue. Pure for testing.
///
/// Only `--title` and `--body` are passed, so GitHub applies no labels by
/// default — exactly the "basic information" issue #102 asks for.
fn create_issue_args(title: &str, body: &str) -> Vec<String> {
    vec![
        "issue".to_string(),
        "create".to_string(),
        "--title".to_string(),
        title.to_string(),
        "--body".to_string(),
        body.to_string(),
    ]
}

/// Extract the trailing issue number from `gh issue create` output, whose last
/// line is the new issue's URL (e.g. `https://github.com/o/r/issues/123`). Pure
/// for testing.
fn parse_created_number(stdout: &str) -> Option<u64> {
    let url = stdout.trim().lines().last()?.trim();
    url.rsplit('/').next()?.parse().ok()
}

/// Create a new GitHub issue with the given title and body using the `gh` CLI.
///
/// Runs `gh issue create --title <title> --body <body>`. Passing no `--label`
/// means GitHub adds none, matching issue #102's "no label by default". Returns
/// the new issue number parsed from the URL `gh` prints. Errors when the title
/// is empty, `gh` is missing or unauthenticated, or the command fails.
pub fn create_issue(title: &str, body: &str) -> Result<u64> {
    if title.trim().is_empty() {
        anyhow::bail!("issue title must not be empty");
    }

    let output = Command::new("gh")
        .args(create_issue_args(title, body))
        .output()
        .context("failed to run `gh` — is the GitHub CLI installed and on PATH?")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "`gh issue create` failed: {}",
            stderr.trim().replace('\n', " ")
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_created_number(&stdout).with_context(|| {
        format!(
            "could not parse issue number from `gh` output: {}",
            stdout.trim()
        )
    })
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
    fn parses_a_list_of_pull_requests() {
        let json = r#"[
            {"number": 12, "title": "resolve conflicts"},
            {"number": 15, "title": "fix failing checks"}
        ]"#;
        let prs = parse_pull_requests(json).expect("should parse");
        assert_eq!(prs.len(), 2);
        assert_eq!(prs[0].number, 12);
        assert_eq!(prs[0].title, "resolve conflicts");
        assert_eq!(prs[1].number, 15);
    }

    #[test]
    fn parses_an_empty_pull_request_list() {
        assert!(parse_pull_requests("[]").expect("should parse").is_empty());
    }

    #[test]
    fn pull_request_parsing_ignores_extra_fields() {
        // Real `gh pr list --json` output carries fields the TUI does not model.
        let json = r#"[{"number": 12, "title": "t", "mergeable": "CONFLICTING",
                        "labels": [{"name": "in-progress"}]}]"#;
        let prs = parse_pull_requests(json).expect("should ignore unknown fields");
        assert_eq!(prs.len(), 1);
        assert_eq!(prs[0].number, 12);
    }

    #[test]
    fn detects_labels_by_name() {
        let json = r#"[{"number":1,"title":"t","labels":[{"name":"ready"}]}]"#;
        let issue = &parse_issues(json).unwrap()[0];
        assert!(issue.has_label("ready"));
        assert!(!issue.has_label("in-progress"));
    }

    #[test]
    fn detects_in_progress_issues() {
        let json = r#"[{"number":1,"title":"t","labels":[{"name":"in-progress"}]},
                       {"number":2,"title":"t","labels":[{"name":"ready"}]}]"#;
        let issues = parse_issues(json).unwrap();
        assert!(issues[0].is_in_progress());
        assert!(!issues[1].is_in_progress());
    }

    #[test]
    fn resolve_label_defaults_and_overrides() {
        assert_eq!(resolve_label(None), "ready");
        assert_eq!(resolve_label(Some(String::new())), "ready");
        assert_eq!(resolve_label(Some("custom".to_string())), "custom");
    }

    #[test]
    fn builds_add_label_args() {
        assert_eq!(
            add_label_args(96, "ready"),
            vec!["issue", "edit", "96", "--add-label", "ready"]
        );
    }

    #[test]
    fn builds_remove_label_args() {
        assert_eq!(
            remove_label_args(96, "ready"),
            vec!["issue", "edit", "96", "--remove-label", "ready"]
        );
    }

    #[test]
    fn builds_create_label_args() {
        assert_eq!(
            create_label_args("ready"),
            vec![
                "label",
                "create",
                "ready",
                "--color",
                "0e8a16",
                "--description",
                "Ready for the copilot loop to pick up",
            ]
        );
    }

    #[test]
    fn builds_close_issue_args() {
        assert_eq!(close_issue_args(96), vec!["issue", "close", "96"]);
    }

    #[test]
    fn builds_create_issue_args_with_no_label() {
        let args = create_issue_args("My title", "A body");
        assert_eq!(
            args,
            vec!["issue", "create", "--title", "My title", "--body", "A body"]
        );
        // No label flag is ever passed, so GitHub adds none by default (#102).
        assert!(!args.iter().any(|a| a.contains("label")));
    }

    #[test]
    fn parses_created_issue_number_from_url() {
        let out = "https://github.com/owner/repo/issues/123\n";
        assert_eq!(parse_created_number(out), Some(123));
    }

    #[test]
    fn parses_created_number_from_last_line() {
        // `gh` may print notices before the URL; the URL is the final line.
        let out = "Creating issue in owner/repo\n\nhttps://github.com/owner/repo/issues/7\n";
        assert_eq!(parse_created_number(out), Some(7));
    }

    #[test]
    fn create_number_is_none_without_a_url() {
        assert_eq!(parse_created_number(""), None);
        assert_eq!(parse_created_number("no url here"), None);
    }

    #[test]
    fn create_issue_rejects_an_empty_title() {
        // Bails before invoking `gh`, so this makes no network/CLI call.
        let err = create_issue("   ", "body").unwrap_err();
        assert!(err.to_string().contains("title must not be empty"));
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

    /// A realistic usage comment body as `copilot-loop.sh` posts it (#145).
    fn usage_comment(credits: &str) -> String {
        format!(
            "**copilot-loop usage** (model: claude-opus-4.5)\n\n```\nAI Credits {credits} (9m 0s)\nTokens     ↑ 3.4m (3.2m cached) • ↓ 39.2k\n```\n\n<!-- copilot-loop:usage -->"
        )
    }

    #[test]
    fn parses_credits_from_a_usage_comment() {
        assert_eq!(parse_comment_credits(&usage_comment("335")), Some(335.0));
        assert_eq!(parse_comment_credits(&usage_comment("25.7")), Some(25.7));
    }

    #[test]
    fn parses_the_legacy_premium_requests_label() {
        let body = "```\nPremium requests 1.5 (8s)\n```\n<!-- copilot-loop:usage -->";
        assert_eq!(parse_comment_credits(body), Some(1.5));
    }

    #[test]
    fn credits_require_the_usage_marker() {
        // Same credits line, but no marker — not a loop usage comment.
        assert_eq!(parse_comment_credits("AI Credits 335 (9m 0s)"), None);
    }

    #[test]
    fn credits_are_none_when_the_marker_has_no_credits_line() {
        assert_eq!(
            parse_comment_credits("a human note <!-- copilot-loop:usage -->"),
            None
        );
    }

    #[test]
    fn totals_credits_across_all_usage_comments() {
        let json = format!(
            r#"[{{"number":1,"title":"t","comments":[
                {{"body":{first}}},
                {{"body":{second}}},
                {{"body":"just a human comment"}}
            ]}}]"#,
            first = serde_json::to_string(&usage_comment("100")).unwrap(),
            second = serde_json::to_string(&usage_comment("50.5")).unwrap(),
        );
        let issue = &parse_issues(&json).unwrap()[0];
        assert_eq!(issue.credits_spent(), Some(150.5));
    }

    #[test]
    fn credits_spent_is_none_without_usage_comments() {
        let with_human = r#"[{"number":1,"title":"t","comments":[{"body":"hi"}]}]"#;
        assert_eq!(parse_issues(with_human).unwrap()[0].credits_spent(), None);
        // No comments field at all (the open-list shape).
        let bare = r#"[{"number":1,"title":"t"}]"#;
        assert_eq!(parse_issues(bare).unwrap()[0].credits_spent(), None);
    }
}
