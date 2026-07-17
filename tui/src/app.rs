//! Application state and list navigation for the issue TUI.

use ratatui::widgets::ListState;

use crate::github::{self, Issue, Label};
use crate::models;
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
    /// Models offered by the picker (first entry is always `auto`).
    pub models: Vec<String>,
    /// Selection within the model picker popup.
    pub model_state: ListState,
    /// Whether the model picker popup is open.
    model_picker_open: bool,
    /// The chosen model, or `None` for `auto` (let Copilot pick).
    selected_model: Option<String>,
}

impl App {
    /// Build an app around an already-fetched list of issues.
    pub fn new(issues: Vec<Issue>) -> Self {
        let mut state = ListState::default();
        if !issues.is_empty() {
            state.select(Some(0));
        }
        let models = models::available();
        let mut model_state = ListState::default();
        model_state.select(Some(0));
        Self {
            issues,
            state,
            status: None,
            should_quit: false,
            limit: DEFAULT_LIMIT,
            runner: LoopRunner::new(),
            models,
            model_state,
            model_picker_open: false,
            selected_model: None,
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
        let model = self.selected_model().map(str::to_owned);
        match self.runner.start(&script, &repo, &log, model.as_deref()) {
            Ok(pid) => {
                self.status = Some(format!(
                    "Background loop started (pid {pid}, model {}). Log: {}",
                    self.current_model_label(),
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

    /// Whether the model picker popup is currently open.
    pub fn model_picker_open(&self) -> bool {
        self.model_picker_open
    }

    /// The chosen model, or `None` when `auto` (let Copilot pick). Used to build
    /// the loop's `--model` argument.
    pub fn selected_model(&self) -> Option<&str> {
        self.selected_model.as_deref()
    }

    /// A human label for the current model: the id, or `auto` when unset.
    pub fn current_model_label(&self) -> &str {
        self.selected_model.as_deref().unwrap_or(models::AUTO_MODEL)
    }

    /// Open the model picker, highlighting the currently selected model.
    pub fn open_model_picker(&mut self) {
        if self.models.is_empty() {
            self.status = Some("No models available.".to_string());
            return;
        }
        let current = self.current_model_label();
        let index = self.models.iter().position(|m| m == current).unwrap_or(0);
        self.model_state.select(Some(index));
        self.model_picker_open = true;
    }

    /// Close the model picker without changing the selection.
    pub fn close_model_picker(&mut self) {
        self.model_picker_open = false;
    }

    /// Move the picker highlight down by one, clamped to the last model.
    pub fn model_next(&mut self) {
        if self.models.is_empty() {
            return;
        }
        let last = self.models.len() - 1;
        let next = self.model_state.selected().map_or(0, |i| (i + 1).min(last));
        self.model_state.select(Some(next));
    }

    /// Move the picker highlight up by one, clamped to the first model.
    pub fn model_previous(&mut self) {
        if self.models.is_empty() {
            return;
        }
        let prev = self
            .model_state
            .selected()
            .map_or(0, |i| i.saturating_sub(1));
        self.model_state.select(Some(prev));
    }

    /// Commit the highlighted model as the loop's model and close the picker.
    ///
    /// The `auto` sentinel clears the selection so no `--model` is passed. A
    /// running loop keeps its model — the change applies the next time the loop
    /// is started — so the status line says so.
    pub fn confirm_model(&mut self) {
        let Some(index) = self.model_state.selected() else {
            self.model_picker_open = false;
            return;
        };
        let Some(model) = self.models.get(index) else {
            self.model_picker_open = false;
            return;
        };

        self.selected_model = if models::is_auto(model) {
            None
        } else {
            Some(model.clone())
        };
        self.model_picker_open = false;

        let label = self.current_model_label().to_string();
        self.status = Some(if self.runner.is_running() {
            format!("Model set to {label} (applies when the loop restarts).")
        } else {
            format!("Model set to {label}.")
        });
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

    #[test]
    fn model_defaults_to_auto() {
        let app = app_with(3);
        assert_eq!(app.selected_model(), None);
        assert_eq!(app.current_model_label(), "auto");
        assert!(!app.model_picker_open());
    }

    #[test]
    fn open_picker_highlights_current_model() {
        let mut app = app_with(0);
        app.open_model_picker();
        assert!(app.model_picker_open());
        // auto is the current model and the first entry.
        assert_eq!(app.model_state.selected(), Some(0));
    }

    #[test]
    fn confirm_a_non_auto_model_sets_it_and_records_status() {
        let mut app = app_with(0);
        let target = app.models[1].clone();

        app.open_model_picker();
        app.model_next();
        app.confirm_model();

        assert!(!app.model_picker_open());
        assert_eq!(app.selected_model(), Some(target.as_str()));
        assert_eq!(app.current_model_label(), target);
        assert_eq!(
            app.status.as_deref(),
            Some(format!("Model set to {target}.").as_str())
        );
    }

    #[test]
    fn confirm_auto_clears_the_selection() {
        let mut app = app_with(0);
        app.open_model_picker();
        app.model_next();
        app.confirm_model();
        assert!(app.selected_model().is_some());

        // Re-open and pick the first entry (auto) again.
        app.open_model_picker();
        app.model_previous();
        app.model_previous();
        app.confirm_model();

        assert_eq!(app.selected_model(), None);
        assert_eq!(app.current_model_label(), "auto");
    }

    #[test]
    fn model_navigation_clamps_at_both_ends() {
        let mut app = app_with(0);
        let last = app.models.len() - 1;
        app.open_model_picker();

        app.model_previous();
        assert_eq!(app.model_state.selected(), Some(0)); // clamps at top

        for _ in 0..app.models.len() + 2 {
            app.model_next();
        }
        assert_eq!(app.model_state.selected(), Some(last)); // clamps at bottom
    }

    #[test]
    fn close_picker_keeps_the_current_model() {
        let mut app = app_with(0);
        app.open_model_picker();
        app.model_next();
        app.close_model_picker();
        assert!(!app.model_picker_open());
        // Cancelled without confirming: still auto.
        assert_eq!(app.selected_model(), None);
    }
}
