//! Application state and list navigation for the issue TUI.

use std::path::PathBuf;

use ratatui::widgets::ListState;

use crate::cost::{self, MonthlyCost, YearMonth};
use crate::github::{self, Issue, Label, PullRequest};
use crate::logs;
use crate::models;
use crate::reporter::{CloseReporter, ReportOutcome, ReportRequest, ReportStatus};
use crate::runner::{self, LoopRunner, WorkerStatus, WorkerView};
use crate::worker::{FetchOutcome, IssueFetcher};

/// Default number of issues to request from `gh`.
pub const DEFAULT_LIMIT: u32 = 200;

/// How much of a loop log to read for the output panel (its tail).
pub const OUTPUT_TAIL_BYTES: u64 = 64 * 1024;

/// Environment variable seeding whether closing an issue posts a summary comment
/// (#161). Default on; `off`/`0`/`false`/`no` (case-insensitive) start it off.
pub const SUMMARY_ON_CLOSE_ENV: &str = "SUMMARY_ON_CLOSE";

/// The initial "report on close" state from a raw `SUMMARY_ON_CLOSE` value: on by
/// default, off only when explicitly disabled. Pure for testing.
pub fn default_report_on_close(raw: Option<String>) -> bool {
    match raw {
        Some(value) => !matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "off" | "0" | "false" | "no"
        ),
        None => true,
    }
}

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
    /// Whether a quit confirmation is open, so a stray `q`/`Esc` asks before it
    /// exits the TUI (#167).
    quit_confirm: bool,
    /// In-progress issue numbers seen at the last refresh, so `auto_refresh`
    /// can announce when the loop *starts* a new issue (#119).
    known_in_progress: Vec<u64>,
    /// Whether the next loop start enables GitHub auto-merge on each PR (#135).
    auto_merge: bool,
    /// Whether the next loop start keeps quality-assurance tests on (default) or
    /// disables them with `--no-quality-assurance` to save cost (#162).
    quality_assurance: bool,
    /// Monotonic id for the next worker, so each gets its own capture log
    /// (`loop-<id>.log`) even as workers come and go (#134).
    next_worker_id: usize,
    /// Open pull requests the loop is currently working (carry the in-progress
    /// label). PRs are absent from `gh issue list`, so these are tracked
    /// separately so the TUI can show PR work is happening (#133).
    in_progress_prs: Vec<PullRequest>,
    /// In-progress PR numbers seen at the last refresh, mirroring
    /// `known_in_progress` so a newly started PR is announced once (#133).
    known_in_progress_prs: Vec<u64>,
    /// Whether the PR-output popup is open (#143).
    pr_output_open: bool,
    /// Selection within the PR-output popup's PR list (#143).
    pub pr_output_state: ListState,
    /// Whether the closed-issues (spend) popup is open (#145).
    closed_open: bool,
    /// The closed issues shown in that popup, fetched with their comments so
    /// each row's AI Credits spend can be totalled (#145).
    closed_issues: Vec<Issue>,
    /// Selection within the closed-issues popup (#145).
    pub closed_state: ListState,
    /// Whether the issue-details popup is open (#152).
    details_open: bool,
    /// The issue shown in the details popup, fetched with its body and comments
    /// so the whole issue is readable in the TUI (#152). `None` until opened.
    details: Option<Issue>,
    /// Vertical scroll offset (in rendered lines) of the details popup, so long
    /// issues and comment threads can be read top to bottom (#152).
    details_scroll: u16,
    /// Whether the `space` leader-key action menu is open, i.e. the next key in
    /// the list selects an issue action rather than navigating (#129).
    leader: bool,
    /// Background fetcher that runs the `gh` issue/PR queries off the UI thread
    /// so the periodic auto-refresh never freezes input or redraws (#144).
    /// `None` when no worker is attached (unit tests, or before wiring).
    fetcher: Option<IssueFetcher>,
    /// Whether a background fetch is in flight, so the footer can animate a
    /// "Refreshing…" indicator until the result lands (#130).
    refreshing: bool,
    /// Whether the in-flight fetch was triggered by a manual `r` refresh, so its
    /// completion is reported on the status line (empty list, or an error) the
    /// way the old blocking `refresh` did — auto-refreshes stay silent (#130).
    manual_refresh_pending: bool,
    /// Whether the bots popup is open (#82).
    bots_open: bool,
    /// Selection within the bots popup's worker list (#82).
    pub bots_state: ListState,
    /// The workers shown in the bots popup, refreshed from the runner so their
    /// live status (running/stopped/failed) tracks each background loop (#82).
    bots: Vec<WorkerView>,
    /// Whether closing an issue posts an auto-generated summary comment on it
    /// (#161). Default on; toggled with `space s`, seeded from `SUMMARY_ON_CLOSE`.
    report_on_close: bool,
    /// The light model that writes the close summary, or `None` for auto (#161).
    /// Kept separate from the coding model so the summary stays cheap.
    summary_model: Option<String>,
    /// Background reporter that writes the close summary off the UI thread so the
    /// model call never freezes input or redraws (#161). `None` in unit tests.
    reporter: Option<CloseReporter>,
    /// How many close summaries are in flight, so the footer can show a
    /// "Summarizing…" indicator until they land (#161).
    reporting: usize,
    /// Whether the cost dashboard popup is open (#163).
    cost_open: bool,
    /// Issues (open and closed) fetched with their comments so the dashboard can
    /// total and graph the loop's spend by day. Loaded when the popup opens (#163).
    cost_issues: Vec<Issue>,
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
            quit_confirm: false,
            known_in_progress: Vec::new(),
            auto_merge: false,
            quality_assurance: true,
            next_worker_id: 1,
            in_progress_prs: Vec::new(),
            known_in_progress_prs: Vec::new(),
            pr_output_open: false,
            pr_output_state: ListState::default(),
            closed_open: false,
            closed_issues: Vec::new(),
            closed_state: ListState::default(),
            details_open: false,
            details: None,
            details_scroll: 0,
            leader: false,
            fetcher: None,
            refreshing: false,
            manual_refresh_pending: false,
            bots_open: false,
            bots_state: ListState::default(),
            bots: Vec::new(),
            report_on_close: default_report_on_close(std::env::var(SUMMARY_ON_CLOSE_ENV).ok()),
            summary_model: models::summary_model(),
            reporter: None,
            reporting: 0,
            cost_open: false,
            cost_issues: Vec::new(),
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

    /// Re-fetch issues from GitHub in response to a manual `r` press.
    ///
    /// When a worker is attached the fetch runs off the UI thread so the footer
    /// can animate a "Refreshing…" indicator instead of freezing during the `gh`
    /// call (#130); [`poll_fetch_results`] applies the result on a later tick and
    /// reports it like a manual refresh (an empty list, or an error). Without a
    /// worker (unit tests, pre-wiring) it falls back to a blocking fetch.
    pub fn refresh(&mut self) {
        match self.fetcher.as_ref() {
            Some(fetcher) => {
                fetcher.request();
                self.manual_refresh_pending = true;
                self.refreshing = true;
            }
            None => self.refresh_blocking(),
        }
    }

    /// Blocking manual re-fetch: fetch on the UI thread and fold the result in,
    /// updating the status line on an empty list or an error. Used as the
    /// no-worker fallback for [`refresh`] and by the create flow, which needs the
    /// new row present before it can select it.
    fn refresh_blocking(&mut self) {
        self.refresh_in_progress_prs();
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

    /// Best-effort refresh of the in-progress PR list (#133).
    ///
    /// Swallows errors so a `gh pr list` hiccup never clobbers the issue view or
    /// its status line — the PR indicator simply keeps its last value until the
    /// next tick. Leaves the list unchanged on failure rather than blanking it.
    fn refresh_in_progress_prs(&mut self) {
        if let Ok(prs) = github::fetch_in_progress_prs() {
            let previous = self.selected_pr_number();
            self.in_progress_prs = prs;
            self.reselect_pr_output(previous);
        }
    }

    /// Attach the background issue fetcher so refreshes run off the UI thread
    /// (#144). Wired once at startup; unit tests leave it unset and drive the
    /// apply path directly.
    pub fn set_fetcher(&mut self, fetcher: IssueFetcher) {
        self.fetcher = Some(fetcher);
    }

    /// Request a silent, off-thread re-fetch of issues so the list (and its
    /// in-progress labels) tracks the running loop without a manual refresh
    /// (#115), announcing when the loop *starts* on a new issue (#119).
    ///
    /// The blocking `gh` calls run on the worker thread, so this returns
    /// immediately and the UI keeps redrawing and handling input while the
    /// fetch is in flight (#144), animating a footer "Refreshing…" indicator
    /// (#130). Results land via [`poll_fetch_results`]. When no worker is
    /// attached it falls back to a synchronous fetch so behaviour is preserved.
    ///
    /// Unlike [`refresh`], applying the result leaves the status line untouched
    /// on a plain refresh and swallows errors: it runs on a timer while the loop
    /// works, so a transient `gh` hiccup must not clobber the current status or
    /// spam the footer — a manual `r` still surfaces failures. The one time it
    /// does set the status is the discrete "loop started #N" event (#119).
    pub fn auto_refresh(&mut self) {
        match self.fetcher.as_ref() {
            Some(fetcher) => {
                fetcher.request();
                self.refreshing = true;
            }
            None => self.auto_refresh_blocking(),
        }
    }

    /// Synchronous fallback for [`auto_refresh`] when no worker is attached.
    /// Mirrors the pre-#144 inline behaviour: fetch on the UI thread and fold
    /// the result in.
    fn auto_refresh_blocking(&mut self) {
        self.refresh_in_progress_prs();
        if let Ok(issues) = github::fetch_issues(self.limit) {
            self.set_issues(issues);
            if let Some(message) = self.take_started_feedback() {
                self.status = Some(message);
            }
        }
    }

    /// Fold any completed background fetches into the app state. Called each UI
    /// tick so the list and in-progress markers track the loop without the UI
    /// thread ever blocking on `gh` (#144). Draining at least one outcome clears
    /// the in-flight flag so the footer's "Refreshing…" indicator stops (#130).
    pub fn poll_fetch_results(&mut self) {
        let Some(outcomes) = self.fetcher.as_ref().map(IssueFetcher::drain) else {
            return;
        };
        if !outcomes.is_empty() {
            self.refreshing = false;
        }
        for outcome in outcomes {
            self.apply_fetch_outcome(outcome);
        }
    }

    /// Whether a background refresh is currently in flight, so the UI can animate
    /// its "Refreshing…" indicator (#130).
    pub fn is_refreshing(&self) -> bool {
        self.refreshing
    }

    /// Apply one completed background fetch. A manual refresh (the user pressed
    /// `r`) reports an empty list and surfaces errors on the status line, the way
    /// the old blocking `refresh` did (#130); an auto-refresh stays silent except
    /// for the "loop started #N" announcement (#119). Auto-refresh errors are
    /// swallowed so a transient `gh` hiccup never clobbers the status line (#144).
    fn apply_fetch_outcome(&mut self, outcome: FetchOutcome) {
        let manual = std::mem::take(&mut self.manual_refresh_pending);
        if let Ok(prs) = outcome.prs {
            self.in_progress_prs = prs;
        }
        match outcome.issues {
            Ok(issues) => {
                if manual {
                    self.status = if issues.is_empty() {
                        Some("No open issues found.".to_string())
                    } else {
                        None
                    };
                    self.set_issues(issues);
                } else {
                    self.set_issues(issues);
                    if let Some(message) = self.take_started_feedback() {
                        self.status = Some(message);
                    }
                }
            }
            Err(err) => {
                if manual {
                    self.status = Some(format!("Error: {err}"));
                }
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

        let current_prs = self.in_progress_pr_numbers();
        let started_prs = newly_started(&current_prs, &self.known_in_progress_prs);
        self.known_in_progress_prs = current_prs;

        let issue_msg = started_message(&started, &self.issues);
        let pr_msg = pr_started_message(&started_prs, &self.in_progress_prs);
        combine_feedback(issue_msg, pr_msg)
    }

    /// Baseline the in-progress set to what is already labelled, so a later
    /// [`auto_refresh`] only announces issues (and PRs) the loop *newly* starts.
    /// Called when the loop starts so pre-existing in-progress labels are not
    /// mistaken for fresh work (#119, #133).
    fn seed_in_progress_baseline(&mut self) {
        self.known_in_progress = self.in_progress_numbers();
        self.known_in_progress_prs = self.in_progress_pr_numbers();
    }

    /// The currently selected issue, if any.
    pub fn selected(&self) -> Option<&Issue> {
        self.state.selected().and_then(|i| self.issues.get(i))
    }

    /// Toggle the trigger label on the selected issue.
    ///
    /// Adds the label via `gh` when the issue lacks it so the loop picks it up,
    /// or removes it when present so a mistakenly-queued issue can be pulled
    /// back out (#146). Either way the change is reflected locally so the row
    /// updates without a refetch, and progress is reported on the status line.
    pub fn toggle_ready(&mut self) {
        let Some(index) = self.state.selected() else {
            return;
        };
        let Some(issue) = self.issues.get(index) else {
            return;
        };

        let number = issue.number;
        let label = github::ready_label();

        if issue.has_label(&label) {
            match github::remove_label(number, &label) {
                Ok(()) => {
                    self.issues[index].labels.retain(|l| l.name != label);
                    self.status = Some(format!("#{number} unmarked '{label}'."));
                }
                Err(err) => self.status = Some(format!("Error: {err}")),
            }
        } else {
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
    }

    /// Whether the selected issue already carries the trigger label, so the
    /// footer can offer `s unready` instead of `s ready` (#146).
    pub fn selected_is_ready(&self) -> bool {
        let label = github::ready_label();
        self.selected().is_some_and(|issue| issue.has_label(&label))
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

        // Capture the title before the issue leaves the list so the summary
        // prompt can name it (#161).
        let title = self
            .issues
            .iter()
            .find(|i| i.number == number)
            .map(|i| i.title.clone())
            .unwrap_or_default();

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
                self.report_close(number, &title);
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// Whether a quit confirmation is open (#167).
    pub fn quit_confirm(&self) -> bool {
        self.quit_confirm
    }

    /// Ask to quit: opens a confirmation prompt so a stray `q`/`Esc` does not
    /// exit the TUI by accident (#167). Nothing exits until [`confirm_quit`].
    pub fn request_quit(&mut self) {
        self.quit_confirm = true;
    }

    /// Dismiss the quit confirmation without exiting.
    pub fn cancel_quit(&mut self) {
        self.quit_confirm = false;
    }

    /// Confirm the pending quit: signals the main loop to exit (#167).
    pub fn confirm_quit(&mut self) {
        self.quit_confirm = false;
        self.should_quit = true;
    }

    /// Kick off the background close summary for a just-closed issue, when the
    /// feature is on (#161).
    ///
    /// Reads the issue's session-log tail on the UI thread (cheap file IO) and,
    /// when there is context to summarize, hands it to the reporter thread so the
    /// model call and `gh issue comment` never freeze the UI. A no-op when the
    /// feature is off, no reporter is attached (unit tests), or the issue has no
    /// loop log to summarize.
    fn report_close(&mut self, number: u64, title: &str) {
        if !self.report_on_close {
            return;
        }
        let Some(reporter) = self.reporter.as_ref() else {
            return;
        };

        let context = self.session_context(number);
        if context.trim().is_empty() {
            self.status = Some(format!(
                "Closed issue #{number}. No session log to summarize."
            ));
            return;
        }

        reporter.request(ReportRequest {
            number,
            title: title.to_string(),
            model: self.summary_model.clone(),
            context,
        });
        self.reporting += 1;
        self.status = Some(format!("Closed issue #{number}. Summarizing…"));
    }

    /// The sanitized tail of the newest loop log for `number`, capped for the
    /// summary prompt, or an empty string when the issue has no log (#161).
    fn session_context(&self, number: u64) -> String {
        let Some(path) = logs::latest_issue_log(&logs::logs_dir(&self.repo_root), number) else {
            return String::new();
        };
        match logs::read_log_tail(&path, github::SUMMARY_CONTEXT_BYTES) {
            Ok(raw) => logs::sanitize(&raw),
            Err(_) => String::new(),
        }
    }

    /// Whether closing an issue posts an auto-generated summary comment (#161).
    pub fn report_on_close(&self) -> bool {
        self.report_on_close
    }

    /// Toggle whether closing an issue posts a summary comment (#161).
    pub fn toggle_report_on_close(&mut self) {
        self.report_on_close = !self.report_on_close;
        let state = if self.report_on_close { "on" } else { "off" };
        self.status = Some(format!("Close summary {state}."));
    }

    /// Attach the background close reporter so summaries run off the UI thread
    /// (#161). Wired once at startup; unit tests leave it unset.
    pub fn set_reporter(&mut self, reporter: CloseReporter) {
        self.reporter = Some(reporter);
    }

    /// Whether a close summary is currently being written, so the footer can
    /// animate a "Summarizing…" indicator until it lands (#161).
    pub fn is_reporting(&self) -> bool {
        self.reporting > 0
    }

    /// Fold any completed close summaries into the status line. Called each UI
    /// tick so a posted summary (or a failure) is reported without the UI thread
    /// ever blocking on the model call (#161).
    pub fn poll_report_results(&mut self) {
        let Some(outcomes) = self.reporter.as_ref().map(CloseReporter::drain) else {
            return;
        };
        for outcome in outcomes {
            self.reporting = self.reporting.saturating_sub(1);
            self.status = Some(report_status_message(&outcome));
        }
    }

    /// Start another background worker that works through the ready issues.
    ///
    /// Each call launches a new detached `copilot-loop.sh`. Because the loop
    /// claims issues under a GitHub lock (and isolates each in its own git
    /// worktree), several workers run safely on *different* issues (#134). A
    /// worker keeps running after the TUI quits, matching the bash TUI.
    pub fn start_worker(&mut self) {
        let repo = self.repo_root.clone();
        let Some(script) = runner::resolve_loop_script(&repo) else {
            self.status = Some(format!(
                "Cannot find {} — set {} to its path.",
                runner::LOOP_SCRIPT_NAME,
                runner::LOOP_SCRIPT_ENV
            ));
            return;
        };

        // Baseline the in-progress set only when the first worker starts, so any
        // already-labelled in-progress issue predates the workers (#119).
        let was_idle = !self.runner.is_running();
        let log = runner::log_path(&repo, self.next_worker_id);
        let model = self.selected_model().map(str::to_owned);
        match self.runner.start(
            self.next_worker_id,
            &script,
            &repo,
            &log,
            model.as_deref(),
            self.auto_merge,
            self.quality_assurance,
        ) {
            Ok(pid) => {
                self.next_worker_id += 1;
                if was_idle {
                    self.seed_in_progress_baseline();
                }
                let count = self.runner.running_count();
                self.status = Some(format!(
                    "Worker started (pid {pid}, model {}, auto-merge {}, QA {}). {count} running. Log: {}",
                    self.current_model_label(),
                    if self.auto_merge { "on" } else { "off" },
                    if self.quality_assurance { "on" } else { "off" },
                    log.display()
                ));
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// Stop every running background worker (#134). Reports how many were stopped,
    /// or that none were running.
    pub fn stop_all_workers(&mut self) {
        let count = self.runner.running_count();
        if count == 0 {
            self.status = Some("No workers running.".to_string());
            return;
        }
        self.runner.stop_all();
        self.status = Some(format!(
            "Stopped {count} worker{}.",
            if count == 1 { "" } else { "s" }
        ));
    }

    /// How many background workers are currently running (#134).
    pub fn workers_running(&mut self) -> usize {
        self.runner.running_count()
    }

    /// Whether any background worker is currently running.
    pub fn loop_running(&mut self) -> bool {
        self.runner.is_running()
    }

    /// Refresh the cached worker snapshots from the runner so the bots popup and
    /// its actions see each worker's live status (running/stopped/failed) (#82).
    /// Called each tick the popup is open and whenever a bot action runs.
    pub fn refresh_bots(&mut self) {
        self.bots = self.runner.views();
    }

    /// Whether the bots popup is open (#82).
    pub fn bots_open(&self) -> bool {
        self.bots_open
    }

    /// The workers shown in the bots popup, in start order (#82). Read by the
    /// renderer; kept fresh by [`App::refresh_bots`].
    pub fn bots(&self) -> &[WorkerView] {
        &self.bots
    }

    /// Open the bots popup, refreshing the worker list and selecting the first
    /// one (or nothing when none have been started) (#82).
    pub fn open_bots(&mut self) {
        self.refresh_bots();
        self.bots_state
            .select(if self.bots.is_empty() { None } else { Some(0) });
        self.bots_open = true;
    }

    /// Close the bots popup (#82).
    pub fn close_bots(&mut self) {
        self.bots_open = false;
    }

    /// Move the bots highlight down by one, clamped to the last worker (#82).
    pub fn bots_next(&mut self) {
        if self.bots.is_empty() {
            return;
        }
        let last = self.bots.len() - 1;
        let next = self.bots_state.selected().map_or(0, |i| (i + 1).min(last));
        self.bots_state.select(Some(next));
    }

    /// Move the bots highlight up by one, clamped to the first worker (#82).
    pub fn bots_previous(&mut self) {
        if self.bots.is_empty() {
            return;
        }
        let prev = self
            .bots_state
            .selected()
            .map_or(0, |i| i.saturating_sub(1));
        self.bots_state.select(Some(prev));
    }

    /// Keep the bots selection in range after the list changes (#82).
    fn clamp_bots_selection(&mut self) {
        if self.bots.is_empty() {
            self.bots_state.select(None);
        } else {
            let max = self.bots.len() - 1;
            let index = self.bots_state.selected().unwrap_or(0).min(max);
            self.bots_state.select(Some(index));
        }
    }

    /// Restart the selected stopped or failed bot in place, re-spawning it with
    /// the same options it was launched with (repo dir, forwarded loop flags) and
    /// archiving its previous log (#82).
    ///
    /// A no-op with a status note when nothing is selected or the bot is still
    /// running, so a running worker is never disturbed.
    pub fn restart_selected_bot(&mut self) {
        let Some(view) = self
            .bots_state
            .selected()
            .and_then(|i| self.bots.get(i))
            .cloned()
        else {
            self.status = Some("No bot selected.".to_string());
            return;
        };

        if view.status == WorkerStatus::Running {
            self.status = Some(format!("Bot #{} is already running.", view.id));
            return;
        }

        let was_idle = !self.runner.is_running();
        match self.runner.restart(view.id) {
            Ok(pid) => {
                if was_idle {
                    self.seed_in_progress_baseline();
                }
                self.status = Some(format!(
                    "Restarted bot #{} (pid {pid}). Log: {}",
                    view.id,
                    view.log.display()
                ));
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
        self.refresh_bots();
        self.clamp_bots_selection();
    }

    /// Restart every stopped or failed bot in place, re-spawning each with the
    /// options it was launched with (#82). Reports how many restarted, or that
    /// there were none. Running bots are left untouched.
    pub fn restart_all_stopped_bots(&mut self) {
        let ids: Vec<usize> = self
            .bots
            .iter()
            .filter(|view| view.status.is_restartable())
            .map(|view| view.id)
            .collect();

        if ids.is_empty() {
            self.status = Some("No stopped or failed bots to restart.".to_string());
            return;
        }

        let was_idle = !self.runner.is_running();
        let mut restarted = 0usize;
        let mut failed = 0usize;
        for id in ids {
            match self.runner.restart(id) {
                Ok(_) => restarted += 1,
                Err(_) => failed += 1,
            }
        }
        if restarted > 0 && was_idle {
            self.seed_in_progress_baseline();
        }

        let plural = if restarted == 1 { "" } else { "s" };
        self.status = Some(if failed == 0 {
            format!("Restarted {restarted} bot{plural}.")
        } else {
            format!("Restarted {restarted} bot{plural}, {failed} failed.")
        });
        self.refresh_bots();
        self.clamp_bots_selection();
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

    /// Numbers of the pull requests the loop is currently working (carry the
    /// in-progress label), in list order (#133).
    pub fn in_progress_pr_numbers(&self) -> Vec<u64> {
        self.in_progress_prs.iter().map(|pr| pr.number).collect()
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

    /// Whether the loop will be started with quality-assurance tests on (#162).
    pub fn quality_assurance(&self) -> bool {
        self.quality_assurance
    }

    /// Toggle whether the loop asks Copilot to add quality-assurance tests (#162).
    ///
    /// On by default; turning it off forwards `--no-quality-assurance` to save
    /// cost. Like auto-merge, it is read when the loop is *started*, so a running
    /// loop keeps its behaviour and the status line says so.
    pub fn toggle_quality_assurance(&mut self) {
        self.quality_assurance = !self.quality_assurance;
        let state = if self.quality_assurance { "on" } else { "off" };
        self.status = Some(if self.runner.is_running() {
            format!("Quality assurance {state} (applies when the loop restarts).")
        } else {
            format!("Quality assurance {state}.")
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
            format!("Model set to {label} (applies to workers started next).")
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

    /// Whether the `space` leader-key action menu is open (#129).
    pub fn leader_active(&self) -> bool {
        self.leader
    }

    /// Open the leader-key action menu so the next key selects an issue action
    /// instead of navigating the list (#129).
    pub fn enter_leader(&mut self) {
        self.leader = true;
    }

    /// Close the leader-key action menu without running an action (#129).
    pub fn exit_leader(&mut self) {
        self.leader = false;
    }

    /// The selected issue's latest loop log path and its sanitized tail, or
    /// `None` when nothing is selected or the loop has produced no log yet.
    pub fn selected_output(&self, max_bytes: u64) -> Option<(PathBuf, String)> {
        let number = self.selected()?.number;
        let path = logs::latest_issue_log(&logs::logs_dir(&self.repo_root), number)?;
        let raw = logs::read_log_tail(&path, max_bytes).ok()?;
        Some((path, logs::sanitize(&raw)))
    }

    /// The pull requests the loop is currently resolving, in list order (#143).
    pub fn in_progress_prs(&self) -> &[PullRequest] {
        &self.in_progress_prs
    }

    /// Whether the PR-output popup is open (#143).
    pub fn pr_output_open(&self) -> bool {
        self.pr_output_open
    }

    /// Open the PR-output popup, keeping a valid selection when PRs exist (#143).
    ///
    /// The popup shows the transcript of whatever PR the loop is resolving; the
    /// in-progress PR list is kept current by the periodic refresh (and `r`), so
    /// opening the popup just surfaces it rather than making its own `gh` call.
    pub fn open_pr_output(&mut self) {
        let previous = self.selected_pr_number();
        self.reselect_pr_output(previous);
        self.pr_output_open = true;
    }

    /// Close the PR-output popup.
    pub fn close_pr_output(&mut self) {
        self.pr_output_open = false;
    }

    /// Move the PR-output highlight down by one, clamped to the last PR (#143).
    pub fn pr_output_next(&mut self) {
        if self.in_progress_prs.is_empty() {
            return;
        }
        let last = self.in_progress_prs.len() - 1;
        let next = self
            .pr_output_state
            .selected()
            .map_or(0, |i| (i + 1).min(last));
        self.pr_output_state.select(Some(next));
    }

    /// Move the PR-output highlight up by one, clamped to the first PR (#143).
    pub fn pr_output_previous(&mut self) {
        if self.in_progress_prs.is_empty() {
            return;
        }
        let prev = self
            .pr_output_state
            .selected()
            .map_or(0, |i| i.saturating_sub(1));
        self.pr_output_state.select(Some(prev));
    }

    /// The number of the PR selected in the PR-output popup, if any (#143).
    fn selected_pr_number(&self) -> Option<u64> {
        self.pr_output_state
            .selected()
            .and_then(|i| self.in_progress_prs.get(i))
            .map(|pr| pr.number)
    }

    /// Point the PR-output selection at `previous` again after the list changed,
    /// falling back to the clamped prior index, or clearing it when no PR is left
    /// (#143). Keeps the highlight on the same PR as the list refreshes.
    fn reselect_pr_output(&mut self, previous: Option<u64>) {
        if self.in_progress_prs.is_empty() {
            self.pr_output_state.select(None);
            return;
        }
        let max = self.in_progress_prs.len() - 1;
        let index = previous
            .and_then(|n| self.in_progress_prs.iter().position(|pr| pr.number == n))
            .unwrap_or_else(|| self.pr_output_state.selected().unwrap_or(0).min(max));
        self.pr_output_state.select(Some(index));
    }

    /// The selected in-progress PR's number and its sanitized log tail, or `None`
    /// when no PR is selected or the loop has produced no log for it yet (#143).
    pub fn selected_pr_output(&self, max_bytes: u64) -> Option<(u64, String)> {
        let number = self.selected_pr_number()?;
        let path = logs::latest_issue_log(&logs::logs_dir(&self.repo_root), number)?;
        let raw = logs::read_log_tail(&path, max_bytes).ok()?;
        Some((number, logs::sanitize(&raw)))
    }

    /// Whether the closed-issues (spend) popup is open (#145).
    pub fn closed_open(&self) -> bool {
        self.closed_open
    }

    /// The closed issues shown in the popup, in list order (#145).
    pub fn closed_issues(&self) -> &[Issue] {
        &self.closed_issues
    }

    /// Total AI Credits spent across every closed issue currently shown, or
    /// `None` when none of them carries a usage comment to total (#145).
    pub fn closed_total_credits(&self) -> Option<f64> {
        let mut total = 0.0;
        let mut found = false;
        for issue in &self.closed_issues {
            if let Some(credits) = issue.credits_spent() {
                total += credits;
                found = true;
            }
        }
        found.then_some(total)
    }

    /// Point the popup at the first closed issue (or nothing when empty) and mark
    /// it open. Shared by [`open_closed`] and the test seam so both present the
    /// list the same way (#145).
    fn present_closed(&mut self) {
        self.closed_state.select(if self.closed_issues.is_empty() {
            None
        } else {
            Some(0)
        });
        self.closed_open = true;
    }

    /// Open the closed-issues popup, fetching the closed issues (with their
    /// comments) so each row's spend can be totalled (#145).
    ///
    /// The fetch is synchronous, matching the other `gh`-backed actions. On
    /// failure the popup still opens with an empty list and the error on the
    /// status line, rather than leaving the key feeling dead.
    pub fn open_closed(&mut self) {
        match github::fetch_closed_issues(self.limit) {
            Ok(issues) => {
                self.closed_issues = issues;
                self.status = if self.closed_issues.is_empty() {
                    Some("No closed issues found.".to_string())
                } else {
                    None
                };
            }
            Err(err) => {
                self.closed_issues = Vec::new();
                self.status = Some(format!("Error: {err}"));
            }
        }
        self.present_closed();
    }

    /// Close the closed-issues popup.
    pub fn close_closed(&mut self) {
        self.closed_open = false;
    }

    /// Move the closed-issues highlight down by one, clamped to the last (#145).
    pub fn closed_next(&mut self) {
        if self.closed_issues.is_empty() {
            return;
        }
        let last = self.closed_issues.len() - 1;
        let next = self
            .closed_state
            .selected()
            .map_or(0, |i| (i + 1).min(last));
        self.closed_state.select(Some(next));
    }

    /// Move the closed-issues highlight up by one, clamped to the first (#145).
    pub fn closed_previous(&mut self) {
        if self.closed_issues.is_empty() {
            return;
        }
        let prev = self
            .closed_state
            .selected()
            .map_or(0, |i| i.saturating_sub(1));
        self.closed_state.select(Some(prev));
    }

    /// Whether the cost dashboard popup is open (#163).
    pub fn cost_open(&self) -> bool {
        self.cost_open
    }

    /// Open the cost dashboard, fetching every issue (open and closed) with its
    /// comments so the loop's spend can be totalled and graphed by day (#163).
    ///
    /// The fetch is synchronous, matching the other `gh`-backed popups. On
    /// failure the dashboard still opens (showing an empty month) with the error
    /// on the status line, so the key never feels dead.
    pub fn open_cost(&mut self) {
        match github::fetch_cost_issues(self.limit) {
            Ok(issues) => {
                self.cost_issues = issues;
                self.status = None;
            }
            Err(err) => {
                self.cost_issues = Vec::new();
                self.status = Some(format!("Error: {err}"));
            }
        }
        self.cost_open = true;
    }

    /// Close the cost dashboard popup (#163).
    pub fn close_cost(&mut self) {
        self.cost_open = false;
    }

    /// The current month's spend, aggregated from the loaded issues (#163). Reads
    /// the clock for "this month"; see [`App::monthly_cost_for`] to pin the month.
    pub fn monthly_cost(&self) -> MonthlyCost {
        self.monthly_cost_for(cost::current_month())
    }

    /// The spend for a specific month, aggregated from the loaded issues (#163).
    /// Split out so tests can pin the month regardless of the wall clock.
    pub fn monthly_cost_for(&self, month: YearMonth) -> MonthlyCost {
        cost::monthly_cost(self.cost_issues.iter(), month)
    }

    /// Whether the issue-details popup is open (#152).
    pub fn details_open(&self) -> bool {
        self.details_open
    }

    /// The issue whose details are being shown, if any (#152).
    pub fn details(&self) -> Option<&Issue> {
        self.details.as_ref()
    }

    /// The details popup's current scroll offset, in rendered lines (#152).
    pub fn details_scroll(&self) -> u16 {
        self.details_scroll
    }

    /// Present a fetched issue in the details popup: store it, reset the scroll
    /// to the top, and mark the popup open. Shared by [`open_details`] and the
    /// test seam so both present the issue the same way (#152).
    fn present_details(&mut self, issue: Issue) {
        self.details = Some(issue);
        self.details_scroll = 0;
        self.details_open = true;
    }

    /// Open the details popup for the selected issue, fetching its body and
    /// comments so the whole issue is readable in the TUI (#152).
    ///
    /// The fetch is synchronous, matching the other `gh`-backed actions (e.g.
    /// [`open_closed`]). On failure the popup is left closed and the error is put
    /// on the status line rather than opening an empty popup. A no-op when no
    /// issue is selected.
    pub fn open_details(&mut self) {
        let Some(number) = self.selected().map(|issue| issue.number) else {
            return;
        };
        match github::fetch_issue_details(number) {
            Ok(issue) => {
                self.status = None;
                self.present_details(issue);
            }
            Err(err) => self.status = Some(format!("Error: {err}")),
        }
    }

    /// Close the details popup, dropping the fetched issue (#152).
    pub fn close_details(&mut self) {
        self.details_open = false;
        self.details = None;
        self.details_scroll = 0;
    }

    /// Scroll the details popup down by one line. The offset is clamped against
    /// the content on render, so this only ever grows it (#152).
    pub fn details_scroll_down(&mut self) {
        self.details_scroll = self.details_scroll.saturating_add(1);
    }

    /// Scroll the details popup up by one line, stopping at the top (#152).
    pub fn details_scroll_up(&mut self) {
        self.details_scroll = self.details_scroll.saturating_sub(1);
    }

    /// Jump the details popup to the top (#152).
    pub fn details_scroll_top(&mut self) {
        self.details_scroll = 0;
    }

    /// Jump the details popup to the bottom. The offset is clamped to the last
    /// page on render, so a max value lands on the final lines (#152).
    pub fn details_scroll_bottom(&mut self) {
        self.details_scroll = u16::MAX;
    }

    /// Clamp the details scroll offset to `max`, called from render once the
    /// content's wrapped height and the viewport are known so the popup can
    /// never scroll past its last line (#152).
    pub fn clamp_details_scroll(&mut self, max: u16) {
        if self.details_scroll > max {
            self.details_scroll = max;
        }
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
    /// Requires a non-empty title. On success the list is refetched with a
    /// blocking fetch — so the new row exists before we select it — and the form
    /// closes; on failure the form stays open with the error on the status line.
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
                self.refresh_blocking();
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

    /// Seed the in-progress PR list directly (tests only), standing in for a
    /// `gh pr list` fetch. Reselects the PR-output highlight like a real refresh.
    #[cfg(test)]
    pub fn set_in_progress_prs(&mut self, prs: Vec<PullRequest>) {
        let previous = self.selected_pr_number();
        self.in_progress_prs = prs;
        self.reselect_pr_output(previous);
    }

    /// Mark the next applied fetch as a manual refresh (tests only), standing in
    /// for [`refresh`] having requested the worker, so the manual reporting path
    /// in [`apply_fetch_outcome`] can be exercised without a live fetch (#130).
    #[cfg(test)]
    pub fn begin_manual_refresh(&mut self) {
        self.manual_refresh_pending = true;
        self.refreshing = true;
    }

    /// Force the "refreshing" flag (tests only) so the footer's animated
    /// indicator can be rendered without wiring a worker or calling `gh` (#130).
    #[cfg(test)]
    pub fn set_refreshing(&mut self, refreshing: bool) {
        self.refreshing = refreshing;
    }

    /// Force the "reporting" count (tests only) so the footer's animated
    /// "Summarizing…" indicator can be rendered without wiring a reporter or
    /// calling the model (#161).
    #[cfg(test)]
    pub fn set_reporting(&mut self, reporting: bool) {
        self.reporting = usize::from(reporting);
    }

    /// Seed the closed-issues popup and open it (tests only), standing in for the
    /// `gh issue list --state closed` fetch in [`open_closed`] (#145).
    #[cfg(test)]
    pub fn open_closed_with(&mut self, issues: Vec<Issue>) {
        self.closed_issues = issues;
        self.present_closed();
    }

    /// Seed the cost dashboard with issues and open it (tests only), standing in
    /// for the `gh` fetch in [`open_cost`] so the aggregation and rendering are
    /// testable without a live fetch (#163).
    #[cfg(test)]
    pub fn open_cost_with(&mut self, issues: Vec<Issue>) {
        self.cost_issues = issues;
        self.cost_open = true;
    }

    /// Seed the details popup with an issue and open it (tests only), standing in
    /// for the `gh issue view` fetch in [`open_details`] (#152).
    #[cfg(test)]
    pub fn open_details_with(&mut self, issue: Issue) {
        self.present_details(issue);
    }

    /// Seed the bots popup with worker views and open it (tests only), standing
    /// in for the runner snapshot in [`open_bots`] so the popup's navigation and
    /// early-return branches are testable without spawning processes (#82).
    #[cfg(test)]
    pub fn open_bots_with(&mut self, bots: Vec<WorkerView>) {
        self.bots = bots;
        self.bots_state
            .select(if self.bots.is_empty() { None } else { Some(0) });
        self.bots_open = true;
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

/// The title of the pull request with `number`, if present. Pure for testing.
fn pr_title(prs: &[PullRequest], number: u64) -> Option<&str> {
    prs.iter()
        .find(|pr| pr.number == number)
        .map(|pr| pr.title.as_str())
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

/// Build the "loop started resolving" feedback line for the PRs that just
/// entered the in-progress state, or `None` when none did. Mirrors
/// [`started_message`] for pull requests: a single PR shows its title, several
/// are listed by number. Pure for testing (#133).
fn pr_started_message(started: &[u64], prs: &[PullRequest]) -> Option<String> {
    match started {
        [] => None,
        [number] => Some(match pr_title(prs, *number) {
            Some(title) => format!("Loop started resolving PR #{number}: {title}"),
            None => format!("Loop started resolving PR #{number}."),
        }),
        many => {
            let list = many
                .iter()
                .map(|n| format!("#{n}"))
                .collect::<Vec<_>>()
                .join(", ");
            Some(format!("Loop started resolving PRs {list}."))
        }
    }
}

/// Join the issue and PR "started" lines into one status message, or `None`
/// when both are empty. Keeps each announcement on the same status line so a
/// tick that starts both an issue and a PR reports both. Pure for testing.
fn combine_feedback(issue_msg: Option<String>, pr_msg: Option<String>) -> Option<String> {
    match (issue_msg, pr_msg) {
        (Some(a), Some(b)) => Some(format!("{a} · {b}")),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

/// The status line for a completed close summary (#161): confirmed when posted,
/// noted when there was nothing to summarize, or the error when it failed. Pure
/// for testing.
fn report_status_message(outcome: &ReportOutcome) -> String {
    let number = outcome.number;
    match &outcome.result {
        Ok(ReportStatus::Posted) => format!("Posted a summary on #{number}."),
        Ok(ReportStatus::NoContext) => {
            format!("No session log for #{number}; summary skipped.")
        }
        Err(err) => format!("Summary for #{number} failed: {err}"),
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
    fn pr_started_message_wording_by_count() {
        let prs =
            github::parse_pull_requests(r#"[{"number":12,"title":"resolve conflicts"}]"#).unwrap();

        assert!(pr_started_message(&[], &prs).is_none());
        assert_eq!(
            pr_started_message(&[12], &prs).as_deref(),
            Some("Loop started resolving PR #12: resolve conflicts")
        );
        // A number with no matching PR falls back to just the number.
        assert_eq!(
            pr_started_message(&[99], &prs).as_deref(),
            Some("Loop started resolving PR #99.")
        );
        assert_eq!(
            pr_started_message(&[12, 15], &prs).as_deref(),
            Some("Loop started resolving PRs #12, #15.")
        );
    }

    #[test]
    fn combine_feedback_joins_or_passes_through() {
        assert_eq!(combine_feedback(None, None), None);
        assert_eq!(
            combine_feedback(Some("a".into()), None).as_deref(),
            Some("a")
        );
        assert_eq!(
            combine_feedback(None, Some("b".into())).as_deref(),
            Some("b")
        );
        assert_eq!(
            combine_feedback(Some("a".into()), Some("b".into())).as_deref(),
            Some("a · b")
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
    fn in_progress_pr_numbers_lists_the_worked_prs() {
        let mut app = App::new(Vec::new());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"},{"number":15,"title":"b"}]"#)
                .unwrap(),
        );
        assert_eq!(app.in_progress_pr_numbers(), vec![12, 15]);
    }

    #[test]
    fn take_started_feedback_announces_pr_starts() {
        // A PR the loop begins resolving is announced once, mirroring issues
        // (#133). PRs are seeded via the test setter standing in for `gh`.
        let mut app = App::new(Vec::new());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"resolve conflicts"}]"#).unwrap(),
        );

        assert_eq!(
            app.take_started_feedback().as_deref(),
            Some("Loop started resolving PR #12: resolve conflicts")
        );
        // No change on the next check: the start is not re-announced.
        assert!(app.take_started_feedback().is_none());
    }

    #[test]
    fn take_started_feedback_reports_issue_and_pr_together() {
        // A tick that starts both an issue and a PR reports both on one line.
        let json = r#"[{"number":10,"title":"a","labels":[{"name":"in-progress"}]}]"#;
        let mut app = App::new(parse_issues(json).unwrap());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"b"}]"#).unwrap(),
        );

        let feedback = app
            .take_started_feedback()
            .expect("both should be announced");
        assert!(feedback.contains("Loop started working on #10"));
        assert!(feedback.contains("Loop started resolving PR #12"));
    }

    #[test]
    fn apply_fetch_outcome_folds_in_issues_and_prs_and_announces() {
        // A completed background fetch (#144) updates the list and PR set, and
        // announces the freshly started issue and PR just like the old inline
        // auto_refresh did — without touching `gh`.
        let mut app = App::new(Vec::new());
        let outcome = FetchOutcome {
            issues: Ok(parse_issues(
                r#"[{"number":10,"title":"a","labels":[{"name":"in-progress"}]}]"#,
            )
            .unwrap()),
            prs: Ok(github::parse_pull_requests(r#"[{"number":12,"title":"b"}]"#).unwrap()),
        };

        app.apply_fetch_outcome(outcome);

        assert_eq!(app.issues.len(), 1);
        assert_eq!(app.in_progress_pr_numbers(), vec![12]);
        let status = app.status.as_deref().expect("a start is announced");
        assert!(status.contains("Loop started working on #10"));
        assert!(status.contains("Loop started resolving PR #12"));
    }

    #[test]
    fn apply_fetch_outcome_swallows_errors_and_keeps_state() {
        // A transient `gh` failure must not clobber the list or the status line
        // (#144): both results erroring leaves everything as it was.
        let json = r#"[{"number":7,"title":"keep"}]"#;
        let mut app = App::new(parse_issues(json).unwrap());
        let outcome = FetchOutcome {
            issues: Err(anyhow::anyhow!("gh issue list failed")),
            prs: Err(anyhow::anyhow!("gh pr list failed")),
        };

        app.apply_fetch_outcome(outcome);

        assert_eq!(app.issues.len(), 1);
        assert_eq!(app.issues[0].number, 7);
        assert!(app.status.is_none());
        assert!(app.in_progress_pr_numbers().is_empty());
    }

    #[test]
    fn poll_fetch_results_is_a_noop_without_a_fetcher() {
        // Unit-test apps attach no worker, so draining is a harmless no-op.
        let mut app = app_with(2);
        app.poll_fetch_results();
        assert_eq!(app.issues.len(), 2);
        assert!(app.status.is_none());
    }

    #[test]
    fn is_refreshing_tracks_the_in_flight_flag() {
        let mut app = app_with(1);
        assert!(!app.is_refreshing());
        app.set_refreshing(true);
        assert!(app.is_refreshing());
        app.set_refreshing(false);
        assert!(!app.is_refreshing());
    }

    #[test]
    fn manual_refresh_outcome_reports_an_empty_list() {
        let mut app = app_with(3);
        app.begin_manual_refresh();
        app.apply_fetch_outcome(FetchOutcome {
            issues: Ok(Vec::new()),
            prs: Ok(Vec::new()),
        });
        assert!(app.issues.is_empty());
        assert_eq!(app.status.as_deref(), Some("No open issues found."));
    }

    #[test]
    fn manual_refresh_outcome_clears_status_on_a_non_empty_list() {
        let mut app = app_with(1);
        app.status = Some("stale".to_string());
        app.begin_manual_refresh();
        app.apply_fetch_outcome(FetchOutcome {
            issues: Ok(parse_issues(r#"[{"number":9,"title":"new"}]"#).unwrap()),
            prs: Ok(Vec::new()),
        });
        assert_eq!(app.issues.len(), 1);
        assert_eq!(app.issues[0].number, 9);
        assert!(app.status.is_none());
    }

    #[test]
    fn manual_refresh_outcome_surfaces_errors() {
        let mut app = app_with(2);
        app.begin_manual_refresh();
        app.apply_fetch_outcome(FetchOutcome {
            issues: Err(anyhow::anyhow!("gh exploded")),
            prs: Ok(Vec::new()),
        });
        assert_eq!(app.status.as_deref(), Some("Error: gh exploded"));
        // The prior list survives a failed refresh.
        assert_eq!(app.issues.len(), 2);
    }

    #[test]
    fn a_manual_refresh_outcome_is_reported_once() {
        // The manual flag is consumed by the first applied outcome, so a later
        // silent auto-refresh does not re-report an empty list (#130).
        let mut app = app_with(1);
        app.begin_manual_refresh();
        app.apply_fetch_outcome(FetchOutcome {
            issues: Ok(Vec::new()),
            prs: Ok(Vec::new()),
        });
        assert_eq!(app.status.as_deref(), Some("No open issues found."));

        app.status = None;
        app.apply_fetch_outcome(FetchOutcome {
            issues: Ok(Vec::new()),
            prs: Ok(Vec::new()),
        });
        assert!(app.status.is_none());
    }

    #[test]
    fn toggle_ready_is_safe_when_nothing_selected() {
        let mut app = app_with(0);
        app.toggle_ready();
        assert!(app.status.is_none());
    }

    #[test]
    fn selected_is_ready_reflects_the_trigger_label() {
        let label = github::ready_label();

        // Nothing selected: not ready.
        assert!(!app_with(0).selected_is_ready());

        // An unlabelled issue: not ready.
        assert!(!app_with(1).selected_is_ready());

        // An issue already carrying the trigger label: ready, so the footer
        // offers `s unready` and `toggle_ready` would remove it (#146).
        let json = format!(r#"[{{"number":7,"title":"t","labels":[{{"name":"{label}"}}]}}]"#);
        let app = App::new(parse_issues(&json).unwrap());
        assert!(app.selected_is_ready());
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
    fn request_quit_opens_the_confirmation_without_quitting() {
        let mut app = app_with(0);
        assert!(!app.quit_confirm());
        app.request_quit();
        assert!(app.quit_confirm());
        // Nothing exits until the operator confirms (#167).
        assert!(!app.should_quit);
    }

    #[test]
    fn cancel_quit_closes_the_confirmation_and_stays_running() {
        let mut app = app_with(0);
        app.request_quit();
        app.cancel_quit();
        assert!(!app.quit_confirm());
        assert!(!app.should_quit);
    }

    #[test]
    fn confirm_quit_closes_the_prompt_and_signals_the_loop_to_exit() {
        let mut app = app_with(0);
        app.request_quit();
        app.confirm_quit();
        assert!(!app.quit_confirm());
        assert!(app.should_quit);
    }

    #[test]
    fn report_on_close_is_on_by_default() {
        // With SUMMARY_ON_CLOSE unset the summary is on, and nothing is in flight.
        let app = app_with(0);
        assert!(app.report_on_close());
        assert!(!app.is_reporting());
    }

    #[test]
    fn default_report_on_close_respects_disable_words() {
        assert!(default_report_on_close(None));
        assert!(default_report_on_close(Some("on".to_string())));
        assert!(default_report_on_close(Some("anything".to_string())));
        for off in ["off", "0", "false", "no", "OFF", " No "] {
            assert!(
                !default_report_on_close(Some(off.to_string())),
                "raw = {off}"
            );
        }
    }

    #[test]
    fn toggle_report_on_close_flips_and_reports() {
        let mut app = app_with(1);
        assert!(app.report_on_close());
        app.toggle_report_on_close();
        assert!(!app.report_on_close());
        assert_eq!(app.status.as_deref(), Some("Close summary off."));
        app.toggle_report_on_close();
        assert!(app.report_on_close());
        assert_eq!(app.status.as_deref(), Some("Close summary on."));
    }

    #[test]
    fn report_status_message_reads_each_outcome() {
        let posted = report_status_message(&ReportOutcome {
            number: 7,
            result: Ok(ReportStatus::Posted),
        });
        assert_eq!(posted, "Posted a summary on #7.");

        let none = report_status_message(&ReportOutcome {
            number: 8,
            result: Ok(ReportStatus::NoContext),
        });
        assert!(none.contains("#8"));
        assert!(none.contains("skipped"));

        let failed = report_status_message(&ReportOutcome {
            number: 9,
            result: Err(anyhow::anyhow!("boom")),
        });
        assert!(failed.contains("#9"));
        assert!(failed.contains("boom"));
    }

    #[test]
    fn poll_report_results_is_a_no_op_without_a_reporter() {
        // Unit tests leave the reporter unset, so polling never touches `gh` or a
        // model and simply does nothing.
        let mut app = app_with(1);
        app.poll_report_results();
        assert!(app.status.is_none());
        assert!(!app.is_reporting());
    }

    #[test]
    fn loop_is_not_running_before_it_is_started() {
        let mut app = app_with(0);
        assert!(!app.loop_running());
        assert_eq!(app.workers_running(), 0);
    }

    #[test]
    fn stop_all_workers_is_a_no_op_when_none_run() {
        let mut app = app_with(1);
        app.stop_all_workers();
        // No worker was running, so nothing is stopped and the status says so.
        assert_eq!(app.status.as_deref(), Some("No workers running."));
    }

    /// A worker view in a given state, for the bots-popup unit tests (#82).
    fn worker_view(id: usize, status: WorkerStatus) -> WorkerView {
        WorkerView {
            id,
            pid: 1000 + id as u32,
            status,
            model: None,
            log: PathBuf::from(format!("/tmp/loop-{id}.log")),
        }
    }

    #[test]
    fn open_bots_selects_the_first_worker() {
        let mut app = app_with(0);
        app.open_bots_with(vec![
            worker_view(1, WorkerStatus::Stopped),
            worker_view(2, WorkerStatus::Failed),
        ]);
        assert!(app.bots_open());
        assert_eq!(app.bots_state.selected(), Some(0));
        assert_eq!(app.bots().len(), 2);
    }

    #[test]
    fn bots_navigation_clamps_to_the_ends() {
        let mut app = app_with(0);
        app.open_bots_with(vec![
            worker_view(1, WorkerStatus::Stopped),
            worker_view(2, WorkerStatus::Stopped),
        ]);
        app.bots_previous();
        assert_eq!(app.bots_state.selected(), Some(0)); // clamps at top
        app.bots_next();
        assert_eq!(app.bots_state.selected(), Some(1));
        app.bots_next();
        assert_eq!(app.bots_state.selected(), Some(1)); // clamps at bottom
        app.close_bots();
        assert!(!app.bots_open());
    }

    #[test]
    fn restarting_a_running_bot_leaves_it_untouched() {
        let mut app = app_with(0);
        app.open_bots_with(vec![worker_view(1, WorkerStatus::Running)]);
        app.restart_selected_bot();
        assert_eq!(app.status.as_deref(), Some("Bot #1 is already running."));
    }

    #[test]
    fn restart_all_reports_when_nothing_is_stopped() {
        let mut app = app_with(0);
        app.open_bots_with(vec![worker_view(1, WorkerStatus::Running)]);
        app.restart_all_stopped_bots();
        assert_eq!(
            app.status.as_deref(),
            Some("No stopped or failed bots to restart.")
        );
    }

    #[test]
    fn restarting_with_no_selection_reports_it() {
        let mut app = app_with(0);
        app.open_bots_with(Vec::new());
        app.restart_selected_bot();
        assert_eq!(app.status.as_deref(), Some("No bot selected."));
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
    fn quality_assurance_defaults_on_and_toggles() {
        // QA runs by default (#162), so the loop gets tests unless the user turns
        // it off to save cost.
        let mut app = app_with(0);
        assert!(app.quality_assurance());

        app.toggle_quality_assurance();
        assert!(!app.quality_assurance());
        assert_eq!(app.status.as_deref(), Some("Quality assurance off."));

        app.toggle_quality_assurance();
        assert!(app.quality_assurance());
        assert_eq!(app.status.as_deref(), Some("Quality assurance on."));
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
    fn leader_menu_is_closed_by_default_and_toggles() {
        let mut app = app_with(3);
        assert!(!app.leader_active());
        app.enter_leader();
        assert!(app.leader_active());
        app.exit_leader();
        assert!(!app.leader_active());
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
    fn pr_output_popup_is_hidden_by_default_and_toggles() {
        let mut app = App::new(Vec::new());
        assert!(!app.pr_output_open());
        app.open_pr_output();
        assert!(app.pr_output_open());
        app.close_pr_output();
        assert!(!app.pr_output_open());
    }

    #[test]
    fn open_pr_output_selects_the_first_pr() {
        let mut app = App::new(Vec::new());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"},{"number":15,"title":"b"}]"#)
                .unwrap(),
        );
        app.open_pr_output();
        assert_eq!(app.pr_output_state.selected(), Some(0));
    }

    #[test]
    fn pr_output_navigation_clamps_at_both_ends() {
        let mut app = App::new(Vec::new());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"},{"number":15,"title":"b"}]"#)
                .unwrap(),
        );
        app.open_pr_output();

        app.pr_output_previous(); // already at the top
        assert_eq!(app.pr_output_state.selected(), Some(0));
        app.pr_output_next();
        assert_eq!(app.pr_output_state.selected(), Some(1));
        app.pr_output_next(); // clamp at the last PR
        assert_eq!(app.pr_output_state.selected(), Some(1));
    }

    #[test]
    fn pr_output_navigation_is_safe_without_prs() {
        let mut app = App::new(Vec::new());
        app.open_pr_output();
        app.pr_output_next();
        app.pr_output_previous();
        assert_eq!(app.pr_output_state.selected(), None);
    }

    #[test]
    fn pr_output_selection_follows_the_pr_across_a_refresh() {
        // The highlight tracks the same PR by number even when the list reorders
        // or shrinks under it, so a background refresh never jumps it (#143).
        let mut app = App::new(Vec::new());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"},{"number":15,"title":"b"}]"#)
                .unwrap(),
        );
        app.open_pr_output();
        app.pr_output_next(); // select #15 (index 1)

        // Reordered so #15 is now first: the selection follows it.
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":15,"title":"b"},{"number":12,"title":"a"}]"#)
                .unwrap(),
        );
        assert_eq!(app.pr_output_state.selected(), Some(0));

        // The selected PR finishing clears the highlight rather than dangling.
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"}]"#).unwrap(),
        );
        assert_eq!(app.pr_output_state.selected(), Some(0));
        app.set_in_progress_prs(github::parse_pull_requests(r#"[]"#).unwrap());
        assert_eq!(app.pr_output_state.selected(), None);
    }

    #[test]
    fn selected_pr_output_reads_the_pr_log() {
        let dir = std::env::temp_dir().join(format!("copilot-app-proutput-{}", std::process::id()));
        let logs = dir.join(".copilot-loop").join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(
            logs.join("pr-12-20260101-000000.log"),
            "\x1b[32mresolving\x1b[0m the conflict\n",
        )
        .unwrap();

        let mut app = App::new(Vec::new());
        app.set_repo_root(dir.clone());
        app.set_in_progress_prs(
            github::parse_pull_requests(r#"[{"number":12,"title":"a"},{"number":15,"title":"b"}]"#)
                .unwrap(),
        );
        app.open_pr_output();

        let (number, text) = app.selected_pr_output(OUTPUT_TAIL_BYTES).expect("a PR log");
        assert_eq!(number, 12);
        assert_eq!(text, "resolving the conflict\n");

        // The other PR has no log yet, so nothing is returned for it.
        app.pr_output_next();
        assert!(app.selected_pr_output(OUTPUT_TAIL_BYTES).is_none());

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

    /// A closed issue JSON with one usage comment worth `credits` AI Credits.
    fn closed_issue_json(number: u64, credits: &str) -> String {
        let body = format!("```\\nAI Credits {credits} (1s)\\n```\\n<!-- copilot-loop:usage -->");
        format!(r#"{{"number":{number},"title":"t{number}","comments":[{{"body":"{body}"}}]}}"#)
    }

    #[test]
    fn open_closed_with_selects_the_first_issue() {
        let mut app = app_with(0);
        let json = format!("[{}]", closed_issue_json(10, "100"));
        app.open_closed_with(parse_issues(&json).unwrap());
        assert!(app.closed_open());
        assert_eq!(app.closed_state.selected(), Some(0));
        assert_eq!(app.closed_issues().len(), 1);
    }

    #[test]
    fn close_closed_hides_the_popup() {
        let mut app = app_with(0);
        app.open_closed_with(parse_issues(&format!("[{}]", closed_issue_json(10, "100"))).unwrap());
        app.close_closed();
        assert!(!app.closed_open());
    }

    #[test]
    fn closed_navigation_clamps_at_both_ends() {
        let mut app = app_with(0);
        let json = format!(
            "[{},{}]",
            closed_issue_json(10, "100"),
            closed_issue_json(11, "50")
        );
        app.open_closed_with(parse_issues(&json).unwrap());

        app.closed_previous(); // already at the top
        assert_eq!(app.closed_state.selected(), Some(0));
        app.closed_next();
        assert_eq!(app.closed_state.selected(), Some(1));
        app.closed_next(); // clamp at the last issue
        assert_eq!(app.closed_state.selected(), Some(1));
    }

    #[test]
    fn closed_navigation_is_safe_when_empty() {
        let mut app = app_with(0);
        app.open_closed_with(Vec::new());
        assert_eq!(app.closed_state.selected(), None);
        app.closed_next();
        app.closed_previous();
        assert_eq!(app.closed_state.selected(), None);
    }

    #[test]
    fn closed_total_credits_sums_across_issues() {
        let mut app = app_with(0);
        let json = format!(
            "[{},{}]",
            closed_issue_json(10, "100"),
            closed_issue_json(11, "50.5")
        );
        app.open_closed_with(parse_issues(&json).unwrap());
        assert_eq!(app.closed_total_credits(), Some(150.5));
    }

    #[test]
    fn closed_total_credits_is_none_without_any_spend() {
        let mut app = app_with(0);
        let json = r#"[{"number":10,"title":"t","comments":[{"body":"just a human comment"}]}]"#;
        app.open_closed_with(parse_issues(json).unwrap());
        assert_eq!(app.closed_total_credits(), None);
    }

    /// A single-issue JSON with a body and one comment, standing in for a
    /// `gh issue view` fetch (#152).
    fn detail_issue_json(number: u64) -> String {
        format!(
            r#"{{"number":{number},"title":"t{number}","body":"the description",
                "comments":[{{"author":{{"login":"hubot"}},"body":"a comment",
                             "createdAt":"2026-07-18T06:45:11Z"}}]}}"#
        )
    }

    fn detail_issue(number: u64) -> Issue {
        crate::github::parse_issue(&detail_issue_json(number)).unwrap()
    }

    #[test]
    fn open_details_with_shows_the_issue_at_the_top() {
        let mut app = app_with(2);
        app.details_scroll = 9; // ensure the scroll is reset on open
        app.open_details_with(detail_issue(10));
        assert!(app.details_open());
        assert_eq!(app.details_scroll(), 0);
        let shown = app.details().expect("an issue is shown");
        assert_eq!(shown.number, 10);
        assert_eq!(shown.body, "the description");
        assert_eq!(shown.comments.len(), 1);
    }

    #[test]
    fn close_details_hides_the_popup_and_drops_the_issue() {
        let mut app = app_with(2);
        app.open_details_with(detail_issue(10));
        app.close_details();
        assert!(!app.details_open());
        assert!(app.details().is_none());
        assert_eq!(app.details_scroll(), 0);
    }

    #[test]
    fn details_scroll_moves_and_clamps_at_the_top() {
        let mut app = app_with(1);
        app.open_details_with(detail_issue(10));

        app.details_scroll_up(); // already at the top
        assert_eq!(app.details_scroll(), 0);
        app.details_scroll_down();
        app.details_scroll_down();
        assert_eq!(app.details_scroll(), 2);
        app.details_scroll_up();
        assert_eq!(app.details_scroll(), 1);
        app.details_scroll_top();
        assert_eq!(app.details_scroll(), 0);
    }

    #[test]
    fn clamp_details_scroll_caps_at_the_content_height() {
        let mut app = app_with(1);
        app.open_details_with(detail_issue(10));
        app.details_scroll_bottom();
        assert_eq!(app.details_scroll(), u16::MAX);
        app.clamp_details_scroll(4);
        assert_eq!(app.details_scroll(), 4);
        // A larger max leaves an already-in-range offset untouched.
        app.clamp_details_scroll(10);
        assert_eq!(app.details_scroll(), 4);
    }
}
