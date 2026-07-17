//! Application state and list navigation for the issue TUI.

use std::path::PathBuf;

use ratatui::widgets::ListState;

use crate::github::{self, Issue, Label};
use crate::logs;
use crate::models;
use crate::runner::{self, LoopRunner};

/// Default number of issues to request from `gh`.
pub const DEFAULT_LIMIT: u32 = 200;

/// How much of a loop log to read for the output panel (its tail).
pub const OUTPUT_TAIL_BYTES: u64 = 64 * 1024;

/// Which input surface currently has focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Mode {
    /// Browsing the issue list.
    #[default]
    List,
    /// Filling in the new-issue form.
    Create,
}

/// The field of the create form that currently receives typing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CreateField {
    #[default]
    Title,
    Description,
}

/// State for the new-issue form: its two text fields and which one has focus.
#[derive(Debug, Default, Clone)]
pub struct CreateForm {
    pub title: String,
    pub description: String,
    pub field: CreateField,
}

impl CreateForm {
    /// The text of the currently focused field.
    fn focused_mut(&mut self) -> &mut String {
        match self.field {
            CreateField::Title => &mut self.title,
            CreateField::Description => &mut self.description,
        }
    }

    /// Append a typed character to the focused field.
    pub fn insert_char(&mut self, c: char) {
        self.focused_mut().push(c);
    }

    /// Delete the last character of the focused field.
    pub fn backspace(&mut self) {
        self.focused_mut().pop();
    }

    /// Move focus to the other field.
    pub fn toggle_field(&mut self) {
        self.field = match self.field {
            CreateField::Title => CreateField::Description,
            CreateField::Description => CreateField::Title,
        };
    }
}

/// Holds the issues, the selection, and a transient status message.
pub struct App {
    pub issues: Vec<Issue>,
    pub state: ListState,
    pub status: Option<String>,
    pub should_quit: bool,
    pub mode: Mode,
    pub form: CreateForm,
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
    repo_root: PathBuf,
    show_output: bool,
    /// The number of the issue awaiting a close confirmation, if any (#118).
    close_confirm: Option<u64>,
    /// In-progress issue numbers seen at the last refresh, so `auto_refresh`
    /// can announce when the loop *starts* a new issue (#119).
    known_in_progress: Vec<u64>,
    /// Whether the next loop start enables GitHub auto-merge on each PR (#135).
    auto_merge: bool,
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
            mode: Mode::List,
            form: CreateForm::default(),
            limit: DEFAULT_LIMIT,
            runner: LoopRunner::new(),
            models,
            model_state,
            model_picker_open: false,
            selected_model: None,
            repo_root: runner::repo_root(),
            show_output: false,
            close_confirm: None,
            known_in_progress: Vec::new(),
            auto_merge: false,
        }
    }

    /// Replace the issue list, keeping the selection on the same issue.
    ///
    /// Selection is preserved by issue number so a background refresh (or the
    /// list reordering) does not make the highlight jump to a different issue;
    /// when that issue is gone the prior index is reused, clamped in bounds.
    pub fn set_issues(&mut self, issues: Vec<Issue>) {
        let previous_number = self.selected().map(|issue| issue.number);
        self.issues = issues;
        if self.issues.is_empty() {
            self.state.select(None);
            return;
        }
        let max = self.issues.len() - 1;
        let selected = previous_number
            .and_then(|number| self.issues.iter().position(|i| i.number == number))
            .unwrap_or_else(|| self.state.selected().unwrap_or(0).min(max));
        self.state.select(Some(selected));
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

    /// Silently re-fetch issues so the list (and its in-progress labels) tracks
    /// the running loop without a manual refresh (#115), announcing when the
    /// loop *starts* on a new issue so the user gets feedback (#119).
    ///
    /// Unlike [`refresh`], this leaves the status line untouched on a plain
    /// refresh and swallows errors: it runs on a timer while the loop works, so
    /// a transient `gh` hiccup must not clobber the current status or spam the
    /// footer — a manual `r` still surfaces failures. The one time it does set
    /// the status is the discrete "loop started #N" event (#119).
    pub fn auto_refresh(&mut self) {
        if let Ok(issues) = github::fetch_issues(self.limit) {
            self.set_issues(issues);
            if let Some(message) = self.take_started_feedback() {
                self.status = Some(message);
            }
        }
    }

    /// Which issues the loop has newly started (gained the in-progress label)
    /// since the last check, as a feedback line, or `None` when nothing new.
    ///
    /// Updates the remembered in-progress set so each start is announced once
    /// (#119). Reads only local state (`self.issues`), so it makes no `gh` call.
    fn take_started_feedback(&mut self) -> Option<String> {
        let current = self.in_progress_numbers();
        let started = newly_started(&current, &self.known_in_progress);
        self.known_in_progress = current;
        started_message(&started, &self.issues)
    }

    /// Baseline the in-progress set to what is already labelled, so a later
    /// [`auto_refresh`] only announces issues the loop *newly* starts. Called
    /// when the loop starts so pre-existing in-progress labels are not
    /// mistaken for fresh work (#119).
    fn seed_in_progress_baseline(&mut self) {
        self.known_in_progress = self.in_progress_numbers();
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

    /// The number of the issue awaiting a close confirmation, if any (#118).
    pub fn close_confirm(&self) -> Option<u64> {
        self.close_confirm
    }

    /// Ask to close the selected issue: opens a confirmation prompt naming it.
    ///
    /// Closing is destructive, so nothing is sent to GitHub until the operator
    /// confirms via [`confirm_close`].
    pub fn request_close(&mut self) {
        if let Some(issue) = self.selected() {
            self.close_confirm = Some(issue.number);
        }
    }

    /// Dismiss the close confirmation without closing anything.
    pub fn cancel_close(&mut self) {
        if let Some(number) = self.close_confirm.take() {
            self.status = Some(format!("Close of #{number} cancelled."));
        }
    }

    /// Close the issue awaiting confirmation via `gh`, then drop it from the
    /// list.
    ///
    /// On success the now-closed issue is removed from the open list so it
    /// disappears without a refetch, and the selection is kept in bounds. A
    /// no-op when no confirmation is pending.
    pub fn confirm_close(&mut self) {
        let Some(number) = self.close_confirm.take() else {
            return;
        };

        match github::close_issue(number) {
            Ok(()) => {
                if let Some(pos) = self.issues.iter().position(|i| i.number == number) {
                    self.issues.remove(pos);
                    if self.issues.is_empty() {
                        self.state.select(None);
                    } else {
                        let max = self.issues.len() - 1;
                        let selected = self.state.selected().unwrap_or(0).min(max);
                        self.state.select(Some(selected));
                    }
                }
                self.status = Some(format!("Closed issue #{number}."));
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

        let repo = self.repo_root.clone();
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
        match self
            .runner
            .start(&script, &repo, &log, model.as_deref(), self.auto_merge)
        {
            Ok(pid) => {
                // Only announce issues the loop starts *after* this point; any
                // already-labelled in-progress issue predates the loop (#119).
                self.seed_in_progress_baseline();
                self.status = Some(format!(
                    "Background loop started (pid {pid}, model {}, auto-merge {}). Log: {}",
                    self.current_model_label(),
                    if self.auto_merge { "on" } else { "off" },
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

    /// Numbers of the issues the loop is currently working, i.e. those carrying
    /// the in-progress label, in list order (#115).
    pub fn in_progress_numbers(&self) -> Vec<u64> {
        self.issues
            .iter()
            .filter(|issue| issue.is_in_progress())
            .map(|issue| issue.number)
            .collect()
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

    /// Whether the loop will be started with GitHub auto-merge enabled (#135).
    pub fn auto_merge(&self) -> bool {
        self.auto_merge
    }

    /// Toggle whether the loop auto-merges each PR (#135).
    ///
    /// Like the model, the setting is read when the loop is *started*, so a
    /// running loop keeps its behaviour and the status line says the change
    /// applies on the next start.
    pub fn toggle_auto_merge(&mut self) {
        self.auto_merge = !self.auto_merge;
        let state = if self.auto_merge { "on" } else { "off" };
        self.status = Some(if self.runner.is_running() {
            format!("Auto-merge {state} (applies when the loop restarts).")
        } else {
            format!("Auto-merge {state}.")
        });
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

    /// Whether the output side panel is open.
    pub fn output_visible(&self) -> bool {
        self.show_output
    }

    /// Open or close the output side panel (#107).
    pub fn toggle_output(&mut self) {
        self.show_output = !self.show_output;
    }

    /// The selected issue's latest loop log path and its sanitized tail, or
    /// `None` when nothing is selected or the loop has produced no log yet.
    pub fn selected_output(&self, max_bytes: u64) -> Option<(PathBuf, String)> {
        let number = self.selected()?.number;
        let path = logs::latest_issue_log(&logs::logs_dir(&self.repo_root), number)?;
        let raw = logs::read_log_tail(&path, max_bytes).ok()?;
        Some((path, logs::sanitize(&raw)))
    }

    /// Whether the new-issue form is currently open.
    pub fn is_creating(&self) -> bool {
        self.mode == Mode::Create
    }

    /// Open the new-issue form with empty fields, focused on the title.
    pub fn open_create(&mut self) {
        self.mode = Mode::Create;
        self.form = CreateForm::default();
        self.status = None;
    }

    /// Cancel issue creation and return to the list.
    pub fn cancel_create(&mut self) {
        self.mode = Mode::List;
        self.form = CreateForm::default();
        self.status = Some("Issue creation cancelled.".to_string());
    }

    /// Type a character into the focused form field.
    pub fn form_input(&mut self, c: char) {
        self.form.insert_char(c);
    }

    /// Delete the last character of the focused form field.
    pub fn form_backspace(&mut self) {
        self.form.backspace();
    }

    /// Move focus between the title and description fields.
    pub fn form_toggle_field(&mut self) {
        self.form.toggle_field();
    }

    /// Handle Enter in the form: from the title it advances to the description,
    /// within the description it inserts a newline so bodies can span lines.
    pub fn form_newline(&mut self) {
        match self.form.field {
            CreateField::Title => self.form.field = CreateField::Description,
            CreateField::Description => self.form.insert_char('\n'),
        }
    }

    /// Submit the new-issue form: create the issue via `gh`, then refresh.
    ///
    /// Requires a non-empty title. On success the list is refetched so the new
    /// row appears and is selected, and the form closes; on failure the form
    /// stays open with the error on the status line.
    pub fn submit_create(&mut self) {
        let title = self.form.title.trim().to_string();
        if title.is_empty() {
            self.form.field = CreateField::Title;
            self.status = Some("Title is required to create an issue.".to_string());
            return;
        }
        let body = self.form.description.clone();

        match github::create_issue(&title, &body) {
            Ok(number) => {
                self.mode = Mode::List;
                self.form = CreateForm::default();
                self.refresh();
                if let Some(pos) = self.issues.iter().position(|i| i.number == number) {
                    self.state.select(Some(pos));
                }
                self.status = Some(format!("Created issue #{number}."));
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
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

    /// Point the app at a specific repository root (tests only).
    #[cfg(test)]
    pub fn set_repo_root(&mut self, repo_root: PathBuf) {
        self.repo_root = repo_root;
    }
}

/// Issue numbers present in `current` but not `known` — the ones the loop has
/// newly started since the last check, in `current` order. Pure for testing.
fn newly_started(current: &[u64], known: &[u64]) -> Vec<u64> {
    current
        .iter()
        .copied()
        .filter(|n| !known.contains(n))
        .collect()
}

/// The title of the issue with `number`, if present. Pure for testing.
fn issue_title(issues: &[Issue], number: u64) -> Option<&str> {
    issues
        .iter()
        .find(|issue| issue.number == number)
        .map(|issue| issue.title.as_str())
}

/// Build the "loop started" feedback line for the issues that just entered the
/// in-progress state, or `None` when none did. A single issue shows its title
/// for context; several are listed by number. Pure for testing (#119).
fn started_message(started: &[u64], issues: &[Issue]) -> Option<String> {
    match started {
        [] => None,
        [number] => Some(match issue_title(issues, *number) {
            Some(title) => format!("Loop started working on #{number}: {title}"),
            None => format!("Loop started working on #{number}."),
        }),
        many => {
            let list = many
                .iter()
                .map(|n| format!("#{n}"))
                .collect::<Vec<_>>()
                .join(", ");
            Some(format!("Loop started working on {list}."))
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
    fn set_issues_keeps_selection_on_the_same_issue() {
        let mut app = app_with(5); // numbers 0..=4
        app.next(); // highlight number 1
        assert_eq!(app.selected().map(|i| i.number), Some(1));

        // A refresh that drops number 0 shifts indices but must keep #1 selected.
        let json = r#"[{"number":1,"title":"t1"},{"number":2,"title":"t2"}]"#;
        app.set_issues(parse_issues(json).unwrap());

        assert_eq!(app.selected().map(|i| i.number), Some(1));
        assert_eq!(app.state.selected(), Some(0)); // #1 is now the first row
    }

    #[test]
    fn in_progress_numbers_lists_working_issues_in_order() {
        let json = r#"[
            {"number":10,"title":"a","labels":[{"name":"in-progress"}]},
            {"number":11,"title":"b","labels":[{"name":"ready"}]},
            {"number":12,"title":"c","labels":[{"name":"in-progress"}]}
        ]"#;
        let app = App::new(parse_issues(json).unwrap());
        assert_eq!(app.in_progress_numbers(), vec![10, 12]);
    }

    #[test]
    fn newly_started_returns_only_the_fresh_numbers() {
        assert_eq!(newly_started(&[10, 12], &[]), vec![10, 12]);
        assert_eq!(newly_started(&[10, 12], &[10]), vec![12]);
        assert!(newly_started(&[10], &[10, 12]).is_empty());
        assert!(newly_started(&[], &[10]).is_empty());
    }

    #[test]
    fn started_message_wording_by_count() {
        let json = r#"[{"number":10,"title":"fix the parser","labels":[]}]"#;
        let issues = parse_issues(json).unwrap();

        assert!(started_message(&[], &issues).is_none());
        assert_eq!(
            started_message(&[10], &issues).as_deref(),
            Some("Loop started working on #10: fix the parser")
        );
        // A number with no matching issue falls back to just the number.
        assert_eq!(
            started_message(&[99], &issues).as_deref(),
            Some("Loop started working on #99.")
        );
        assert_eq!(
            started_message(&[10, 12], &issues).as_deref(),
            Some("Loop started working on #10, #12.")
        );
    }

    #[test]
    fn take_started_feedback_announces_each_start_once() {
        let json = r#"[
            {"number":10,"title":"a","labels":[{"name":"in-progress"}]},
            {"number":11,"title":"b","labels":[{"name":"ready"}]}
        ]"#;
        let mut app = App::new(parse_issues(json).unwrap());

        // First check: #10 is a fresh start.
        assert_eq!(
            app.take_started_feedback().as_deref(),
            Some("Loop started working on #10: a")
        );
        // Second check with no change: nothing new to announce.
        assert!(app.take_started_feedback().is_none());
    }

    #[test]
    fn take_started_feedback_skips_baselined_in_progress() {
        // An issue already in-progress when the baseline is seeded (e.g. the
        // moment the loop starts) is not mistaken for fresh work (#119).
        let json = r#"[{"number":10,"title":"a","labels":[{"name":"in-progress"}]}]"#;
        let mut app = App::new(parse_issues(json).unwrap());

        app.seed_in_progress_baseline();
        assert!(app.take_started_feedback().is_none());
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
    fn request_close_is_safe_when_nothing_selected() {
        let mut app = app_with(0);
        app.request_close();
        assert_eq!(app.close_confirm(), None);
    }

    #[test]
    fn request_close_opens_a_confirmation_for_the_selected_issue() {
        let mut app = app_with(3); // numbers 0..=2
        app.next(); // select #1
        app.request_close();
        assert_eq!(app.close_confirm(), Some(1));
        // The list is untouched until the operator confirms.
        assert_eq!(app.issues.len(), 3);
    }

    #[test]
    fn cancel_close_clears_the_prompt_without_touching_the_list() {
        let mut app = app_with(3);
        app.request_close();
        assert_eq!(app.close_confirm(), Some(0));
        app.cancel_close();
        assert_eq!(app.close_confirm(), None);
        assert_eq!(app.issues.len(), 3);
        assert_eq!(app.status.as_deref(), Some("Close of #0 cancelled."));
    }

    #[test]
    fn confirm_close_without_a_pending_prompt_is_a_no_op() {
        let mut app = app_with(2);
        app.confirm_close();
        // No gh call is made and the list is unchanged.
        assert_eq!(app.issues.len(), 2);
        assert!(app.status.is_none());
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

    #[test]
    fn auto_merge_defaults_off_and_toggles() {
        let mut app = app_with(0);
        assert!(!app.auto_merge());

        app.toggle_auto_merge();
        assert!(app.auto_merge());
        assert_eq!(app.status.as_deref(), Some("Auto-merge on."));

        app.toggle_auto_merge();
        assert!(!app.auto_merge());
        assert_eq!(app.status.as_deref(), Some("Auto-merge off."));
    }

    #[test]
    fn output_panel_is_hidden_by_default_and_toggles() {
        let mut app = app_with(1);
        assert!(!app.output_visible());
        app.toggle_output();
        assert!(app.output_visible());
        app.toggle_output();
        assert!(!app.output_visible());
    }

    #[test]
    fn selected_output_reads_the_latest_log() {
        let dir = std::env::temp_dir().join(format!("copilot-app-output-{}", std::process::id()));
        let logs = dir.join(".copilot-loop").join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(
            logs.join("issue-1-20260101-000000.log"),
            "\x1b[32mhello\x1b[0m from the loop\n",
        )
        .unwrap();

        let mut app = app_with(2); // issues numbered 0 and 1
        app.set_repo_root(dir.clone());
        app.last(); // select issue #1

        let (path, text) = app.selected_output(OUTPUT_TAIL_BYTES).expect("a log");
        assert!(path.ends_with("issue-1-20260101-000000.log"));
        assert_eq!(text, "hello from the loop\n");

        // An issue with no log yields nothing.
        app.first(); // issue #0
        assert!(app.selected_output(OUTPUT_TAIL_BYTES).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_create_enters_form_mode_with_empty_fields() {
        let mut app = app_with(3);
        app.status = Some("stale".to_string());
        app.open_create();
        assert!(app.is_creating());
        assert_eq!(app.form.field, CreateField::Title);
        assert!(app.form.title.is_empty());
        assert!(app.form.description.is_empty());
        assert!(app.status.is_none());
    }

    #[test]
    fn cancel_create_returns_to_the_list() {
        let mut app = app_with(3);
        app.open_create();
        app.form_input('x');
        app.cancel_create();
        assert!(!app.is_creating());
        assert!(app.form.title.is_empty());
        assert_eq!(app.status.as_deref(), Some("Issue creation cancelled."));
    }

    #[test]
    fn typing_goes_to_the_focused_field() {
        let mut app = app_with(0);
        app.open_create();
        for c in "Hi".chars() {
            app.form_input(c);
        }
        assert_eq!(app.form.title, "Hi");
        assert!(app.form.description.is_empty());

        app.form_toggle_field();
        for c in "body".chars() {
            app.form_input(c);
        }
        assert_eq!(app.form.description, "body");
        assert_eq!(app.form.title, "Hi");
    }

    #[test]
    fn backspace_deletes_from_the_focused_field() {
        let mut app = app_with(0);
        app.open_create();
        app.form_input('a');
        app.form_input('b');
        app.form_backspace();
        assert_eq!(app.form.title, "a");
        app.form_backspace();
        app.form_backspace(); // safe past empty
        assert!(app.form.title.is_empty());
    }

    #[test]
    fn enter_advances_from_title_then_inserts_newlines_in_body() {
        let mut app = app_with(0);
        app.open_create();
        app.form_input('T');
        app.form_newline(); // title -> description
        assert_eq!(app.form.field, CreateField::Description);
        app.form_input('a');
        app.form_newline(); // newline within description
        app.form_input('b');
        assert_eq!(app.form.description, "a\nb");
        assert_eq!(app.form.title, "T");
    }

    #[test]
    fn submit_with_blank_title_keeps_form_open_and_warns() {
        // Whitespace-only title: submit bails before any `gh` call.
        let mut app = app_with(0);
        app.open_create();
        app.form_toggle_field();
        app.form_input('b');
        app.submit_create();
        assert!(app.is_creating());
        assert_eq!(app.form.field, CreateField::Title);
        assert_eq!(
            app.status.as_deref(),
            Some("Title is required to create an issue.")
        );
    }
}
