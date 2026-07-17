//! Application state and list navigation for the issue TUI.

use ratatui::widgets::ListState;

use crate::github::{self, Issue, Label};
use crate::runner::{self, LoopRunner};

/// Default number of issues to request from `gh`.
pub const DEFAULT_LIMIT: u32 = 200;

/// Holds the issues, the selection, and a transient status message.
pub struct App {
    pub issues: Vec<Issue>,
    pub state: ListState,
    pub status: Option<String>,
    pub should_quit: bool,
    limit: u32,
    runner: LoopRunner,
}

impl App {
    /// Build an app around an already-fetched list of issues.
    pub fn new(issues: Vec<Issue>) -> Self {
        let mut state = ListState::default();
        if !issues.is_empty() {
            state.select(Some(0));
        }
        Self {
            issues,
            state,
            status: None,
            should_quit: false,
            limit: DEFAULT_LIMIT,
            runner: LoopRunner::new(),
        }
    }

    /// Replace the issue list, keeping the selection in bounds.
    pub fn set_issues(&mut self, issues: Vec<Issue>) {
        self.issues = issues;
        if self.issues.is_empty() {
            self.state.select(None);
        } else {
            let max = self.issues.len() - 1;
            let selected = self.state.selected().unwrap_or(0).min(max);
            self.state.select(Some(selected));
        }
    }

    /// Re-fetch issues from GitHub, updating the status line on error.
    pub fn refresh(&mut self) {
        match github::fetch_issues(self.limit) {
            Ok(issues) => {
                self.status = if issues.is_empty() {
                    Some("No open issues found.".to_string())
                } else {
                    None
                };
                self.set_issues(issues);
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// The currently selected issue, if any.
    pub fn selected(&self) -> Option<&Issue> {
        self.state.selected().and_then(|i| self.issues.get(i))
    }

    /// Mark the selected issue ready so the loop can pick it up.
    ///
    /// Adds the trigger label via `gh`, reflects it locally so the row updates
    /// without a refetch, and reports progress on the status line.
    pub fn mark_ready(&mut self) {
        let Some(index) = self.state.selected() else {
            return;
        };
        let Some(issue) = self.issues.get(index) else {
            return;
        };

        let number = issue.number;
        let label = github::ready_label();

        if issue.has_label(&label) {
            self.status = Some(format!("#{number} already labelled '{label}'."));
            return;
        }

        match github::add_label(number, &label) {
            Ok(()) => {
                self.issues[index].labels.push(Label {
                    name: label.clone(),
                });
                self.status = Some(format!("#{number} marked '{label}'."));
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// Start or stop the background loop that works through ready issues.
    ///
    /// When one is running it is stopped; otherwise a detached `copilot-loop.sh`
    /// is launched against this repository (output captured to a log). The loop
    /// keeps running after the TUI quits, matching the bash TUI's behaviour.
    pub fn toggle_loop(&mut self) {
        if self.runner.is_running() {
            self.runner.stop();
            self.status = Some("Background loop stopped.".to_string());
            return;
        }

        let repo = runner::repo_root();
        let Some(script) = runner::resolve_loop_script(&repo) else {
            self.status = Some(format!(
                "Cannot find {} — set {} to its path.",
                runner::LOOP_SCRIPT_NAME,
                runner::LOOP_SCRIPT_ENV
            ));
            return;
        };

        let log = runner::log_path(&repo);
        match self.runner.start(&script, &repo, &log) {
            Ok(pid) => {
                self.status = Some(format!(
                    "Background loop started (pid {pid}). Log: {}",
                    log.display()
                ));
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// Whether the background loop is currently running.
    pub fn loop_running(&mut self) -> bool {
        self.runner.is_running()
    }

    /// Move the selection down by one, clamped to the last item.
    pub fn next(&mut self) {
        if self.issues.is_empty() {
            return;
        }
        let last = self.issues.len() - 1;
        let next = self.state.selected().map_or(0, |i| (i + 1).min(last));
        self.state.select(Some(next));
    }

    /// Move the selection up by one, clamped to the first item.
    pub fn previous(&mut self) {
        if self.issues.is_empty() {
            return;
        }
        let prev = self.state.selected().map_or(0, |i| i.saturating_sub(1));
        self.state.select(Some(prev));
    }

    /// Jump to the first issue.
    pub fn first(&mut self) {
        if !self.issues.is_empty() {
            self.state.select(Some(0));
        }
    }

    /// Jump to the last issue.
    pub fn last(&mut self) {
        if !self.issues.is_empty() {
            self.state.select(Some(self.issues.len() - 1));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::github::parse_issues;

    fn app_with(count: usize) -> App {
        let items: Vec<String> = (0..count)
            .map(|i| format!(r#"{{"number": {i}, "title": "t{i}"}}"#))
            .collect();
        let json = format!("[{}]", items.join(","));
        App::new(parse_issues(&json).unwrap())
    }

    #[test]
    fn selects_first_when_non_empty() {
        assert_eq!(app_with(3).state.selected(), Some(0));
    }

    #[test]
    fn selects_nothing_when_empty() {
        let app = app_with(0);
        assert_eq!(app.state.selected(), None);
        assert!(app.selected().is_none());
    }

    #[test]
    fn next_and_previous_clamp() {
        let mut app = app_with(3);
        app.previous();
        assert_eq!(app.state.selected(), Some(0)); // clamps at top
        app.next();
        assert_eq!(app.state.selected(), Some(1));
        app.next();
        app.next();
        assert_eq!(app.state.selected(), Some(2)); // clamps at bottom
    }

    #[test]
    fn first_and_last_jump() {
        let mut app = app_with(5);
        app.last();
        assert_eq!(app.state.selected(), Some(4));
        app.first();
        assert_eq!(app.state.selected(), Some(0));
    }

    #[test]
    fn navigation_is_safe_on_empty() {
        let mut app = app_with(0);
        app.next();
        app.previous();
        app.first();
        app.last();
        assert_eq!(app.state.selected(), None);
    }

    #[test]
    fn set_issues_keeps_selection_in_bounds() {
        let mut app = app_with(5);
        app.last();
        assert_eq!(app.state.selected(), Some(4));
        app.set_issues(app_with(2).issues);
        assert_eq!(app.state.selected(), Some(1)); // clamped from 4
        app.set_issues(Vec::new());
        assert_eq!(app.state.selected(), None);
    }

    #[test]
    fn mark_ready_is_safe_when_nothing_selected() {
        let mut app = app_with(0);
        app.mark_ready();
        assert!(app.status.is_none());
    }

    #[test]
    fn mark_ready_short_circuits_when_already_labelled() {
        let label = github::ready_label();
        let json = format!(r#"[{{"number":7,"title":"t","labels":[{{"name":"{label}"}}]}}]"#);
        let mut app = App::new(parse_issues(&json).unwrap());

        app.mark_ready();

        // No gh call happened: label count is unchanged and the status explains why.
        assert_eq!(app.issues[0].labels.len(), 1);
        assert_eq!(
            app.status.as_deref(),
            Some(format!("#7 already labelled '{label}'.").as_str())
        );
    }

    #[test]
    fn loop_is_not_running_before_it_is_started() {
        let mut app = app_with(0);
        assert!(!app.loop_running());
    }
}
