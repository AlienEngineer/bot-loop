//! copilot-loop-tui — a ratatui terminal UI that lists GitHub issues.
//!
//! First slice of the ratatui rewrite (#51): fetch the repository's open issues
//! with the `gh` CLI and show them in a scrollable, vim-navigable list.

mod app;
mod cost;
mod github;
mod logs;
mod models;
mod reporter;
mod runner;
mod settings;
mod ui;
mod worker;

use std::time::{Duration, Instant};

use anyhow::Result;
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use app::{App, DEFAULT_LIMIT};

/// How often to silently re-fetch issues while work is in flight, so the list's
/// in-progress markers track what the loop is doing — a local worker or an
/// external loop being watched — without a manual refresh (#115, #157).
const LOOP_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// How long to block for input each tick while something on screen is animating
/// — a background refresh's "Refreshing…" indicator (#130), the running loop's
/// spinner (#115), or an external loop's in-progress work (#157) — kept short so
/// the spinner turns smoothly.
const ANIMATION_TICK: Duration = Duration::from_millis(80);

/// How long to block for input each tick when the screen is static, kept long to
/// stay near-idle.
const IDLE_TICK: Duration = Duration::from_millis(250);

fn main() -> Result<()> {
    // Handle -V/--version before taking over the terminal so `bot-loop --version`
    // reports the build's version (bumped by the release workflow) and exits
    // without entering the UI.
    if wants_version(std::env::args().skip(1)) {
        println!("bot-loop {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    let mut app = App::new(Vec::new());

    // Restore the model, auto-merge, quality-assurance, and close-summary choices
    // the user made last run, and persist any further changes from here on (#195).
    app.load_persisted_settings();

    match github::fetch_issues(DEFAULT_LIMIT) {
        Ok(issues) => {
            if issues.is_empty() {
                app.set_status("No open issues found.");
            }
            app.set_issues(issues);
        }
        Err(err) => app.set_status(format!("Error: {err}")),
    }

    // Run the `gh` issue/PR queries on a worker thread so the periodic
    // auto-refresh never blocks the UI loop (#144).
    app.set_fetcher(worker::IssueFetcher::spawn(DEFAULT_LIMIT));

    // Write close summaries on a worker thread so the model call never freezes
    // the UI (#161).
    app.set_reporter(reporter::CloseReporter::spawn());

    let mut terminal = ratatui::init();
    let result = run(&mut terminal, &mut app);
    ratatui::restore();
    result
}

/// Whether the CLI args request the version (`-V`/`--version`). Checked before
/// the UI starts so `bot-loop --version` prints and exits. Pure for testing.
fn wants_version<I: IntoIterator<Item = String>>(args: I) -> bool {
    args.into_iter().any(|a| a == "-V" || a == "--version")
}

/// The main draw/input loop. Polls for key events and redraws each tick, and
/// silently refreshes the issue list on a timer while work is in flight — a
/// local worker or an external loop being watched — so its progress (which issue
/// is in-progress) stays visible (#115, #157), then once more the tick work
/// finishes so the final state (closed issues, dropped in-progress labels) shows
/// without a manual refresh (#121).
fn run(terminal: &mut DefaultTerminal, app: &mut App) -> Result<()> {
    let mut last_refresh = Instant::now();
    let mut work_was_active = false;
    while !app.should_quit {
        // Fold in any issue/PR data the worker thread finished fetching, so the
        // list tracks the loop without the UI thread ever blocking on `gh`.
        app.poll_fetch_results();

        // Fold in any close summaries the reporter thread finished, so a posted
        // summary (or a failure) surfaces without blocking on the model (#161).
        app.poll_report_results();

        // Keep the bots popup's worker statuses live while it is open (#82).
        if app.bots_open() {
            app.refresh_bots();
        }

        terminal.draw(|frame| ui::render(frame, app))?;

        // Poll briefly while anything animates — a background refresh's
        // "Refreshing…" indicator (#130), a close summary in flight (#161), the
        // running loop's spinner (#115), or any in-progress issue/PR an external
        // loop is working (#157) — so the spinner turns smoothly; otherwise wait
        // longer to stay near-idle.
        let poll_timeout = if app.is_refreshing()
            || app.is_reporting()
            || app.loop_running()
            || app.has_active_work()
        {
            ANIMATION_TICK
        } else {
            IDLE_TICK
        };

        if event::poll(poll_timeout)?
            && let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            handle_key(app, key);
        }

        // Silently re-fetch on a timer while work is in flight — local workers
        // the TUI started or an external loop's in-progress issues/PRs — so the
        // list and its markers track it, and once more the tick work finishes so
        // the final state shows without a manual refresh (#115, #121, #157).
        let work_active = app.loop_running() || app.has_active_work();
        let interval_elapsed = last_refresh.elapsed() >= LOOP_REFRESH_INTERVAL;
        if wants_loop_refresh(work_was_active, work_active, interval_elapsed) {
            app.auto_refresh();
            last_refresh = Instant::now();
        }
        work_was_active = work_active;
    }
    Ok(())
}

/// Whether to silently re-fetch the issue list this tick: periodically while
/// work is active — a local worker or an external loop's in-progress issues/PRs
/// — so its markers track it (#115, #157), and once the tick work finishes so
/// the final state shows without a manual refresh (#121). The finishing refresh
/// fires even before the interval elapses. Pure for testing.
fn wants_loop_refresh(was_running: bool, running: bool, interval_elapsed: bool) -> bool {
    (running && interval_elapsed) || (was_running && !running)
}

/// Map a key press to an action. Vim-style navigation (#51); issue actions are
/// gated behind the `space` leader key so the list stays uncluttered and keys
/// can be reused inside the menu (#129).
fn handle_key(app: &mut App, key: KeyEvent) {
    // Ctrl-c always quits.
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
        app.should_quit = true;
        return;
    }

    // The quit confirmation captures keys while it is open (#167).
    if app.quit_confirm() {
        handle_quit_confirm_key(app, key);
        return;
    }

    // The model picker popup captures keys while it is open.
    if app.model_picker_open() {
        handle_model_picker_key(app, key);
        return;
    }

    // The close-issue confirmation captures keys while it is open (#118).
    if app.close_confirm().is_some() {
        handle_close_confirm_key(app, key);
        return;
    }

    // The mark-ready confirmation captures keys while it is open (#173).
    if app.ready_confirm().is_some() {
        handle_ready_confirm_key(app, key);
        return;
    }

    // The PR-output popup captures keys while it is open (#143).
    if app.pr_output_open() {
        handle_pr_output_key(app, key);
        return;
    }

    // The closed-issues (spend) popup captures keys while it is open (#145).
    if app.closed_open() {
        handle_closed_key(app, key);
        return;
    }

    // The cost dashboard popup captures keys while it is open (#163).
    if app.cost_open() {
        handle_cost_key(app, key);
        return;
    }

    // The issue-details popup captures keys while it is open (#152).
    if app.details_open() {
        handle_details_key(app, key);
        return;
    }

    // The bots popup captures keys while it is open (#82).
    if app.bots_open() {
        handle_bots_key(app, key);
        return;
    }

    // The reply popup captures keys while it is open so typing goes to the draft
    // rather than the list (#165).
    if app.reply_open() {
        handle_reply_key(app, key);
        return;
    }

    // The messages popup captures keys while it is open (#182).
    if app.messages_open() {
        handle_messages_key(app, key);
        return;
    }

    if app.is_creating() {
        handle_create_key(app, key);
        return;
    }

    // Issue actions live behind the `space` leader key: after it, one key runs
    // an action and closes the menu (#129).
    if app.leader_active() {
        handle_leader_key(app, key);
        return;
    }

    match key.code {
        KeyCode::Char('q') | KeyCode::Esc => app.request_quit(),
        KeyCode::Char('j') | KeyCode::Down => app.next(),
        KeyCode::Char('k') | KeyCode::Up => app.previous(),
        KeyCode::Char('g') | KeyCode::Home => app.first(),
        KeyCode::Char('G') | KeyCode::End => app.last(),
        // Refresh is global — it reloads the whole list, not the selected issue,
        // so it sits on the base keymap instead of the `space` menu (#174).
        KeyCode::Char('f') => app.refresh(),
        KeyCode::Char(' ') => app.enter_leader(),
        _ => {}
    }
}

/// Handle the key pressed after the `space` leader: run the matching issue
/// action and close the menu; any unbound key (e.g. `Esc`) just cancels it.
/// Refresh is not an issue action, so it lives on the base keymap (`f`) rather
/// than here (#174); `r` stays free for *ready* (#129).
fn handle_leader_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('c') => app.open_create(),
        KeyCode::Char('r') => app.toggle_ready(),
        KeyCode::Char('x') => app.request_close(),
        KeyCode::Char('d') => app.open_details(),
        KeyCode::Char('i') => app.open_reply(),
        KeyCode::Char('l') => app.start_worker(),
        KeyCode::Char('L') => app.stop_all_workers(),
        KeyCode::Char('b') => app.open_bots(),
        KeyCode::Char('M') => app.open_messages(),
        KeyCode::Char('a') => app.toggle_auto_merge(),
        KeyCode::Char('q') => app.toggle_quality_assurance(),
        KeyCode::Char('s') => app.toggle_report_on_close(),
        KeyCode::Char('m') => app.open_model_picker(),
        KeyCode::Char('o') => app.toggle_output(),
        KeyCode::Char('p') => app.open_pr_output(),
        KeyCode::Char('t') => app.open_closed(),
        KeyCode::Char('$') => app.open_cost(),
        _ => {}
    }
    app.exit_leader();
}

/// Handle keys while the model picker popup is open: navigate, confirm, cancel.
fn handle_model_picker_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.model_next(),
        KeyCode::Char('k') | KeyCode::Up => app.model_previous(),
        KeyCode::Enter => app.confirm_model(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('m') => app.close_model_picker(),
        _ => {}
    }
}

/// Handle keys while the close-issue confirmation is open (#118). Closing is
/// destructive, so it defaults to safe: only `y` confirms; `n`, `Esc`, `q` and
/// Enter cancel, and any other key is ignored so the prompt stays put.
fn handle_close_confirm_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('y') | KeyCode::Char('Y') => app.confirm_close(),
        KeyCode::Char('n')
        | KeyCode::Char('N')
        | KeyCode::Char('q')
        | KeyCode::Esc
        | KeyCode::Enter => app.cancel_close(),
        _ => {}
    }
}

/// Handle keys while the mark-ready confirmation is open (#173). The loop is
/// already working the in-progress issue, so it defaults to safe: only `y`
/// confirms; `n`, `Esc`, `q` and Enter cancel, and any other key is ignored so
/// the prompt stays put — mirroring the close-issue confirmation.
fn handle_ready_confirm_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('y') | KeyCode::Char('Y') => app.confirm_ready(),
        KeyCode::Char('n')
        | KeyCode::Char('N')
        | KeyCode::Char('q')
        | KeyCode::Esc
        | KeyCode::Enter => app.cancel_ready(),
        _ => {}
    }
}

/// Handle keys while the quit confirmation is open (#167). Quitting exits the
/// TUI, so it defaults to safe: only `y` confirms; `n`, `Esc`, `q` and Enter
/// cancel, and any other key is ignored so the prompt stays put — mirroring the
/// close-issue confirmation so both destructive prompts behave the same.
fn handle_quit_confirm_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('y') | KeyCode::Char('Y') => app.confirm_quit(),
        KeyCode::Char('n')
        | KeyCode::Char('N')
        | KeyCode::Char('q')
        | KeyCode::Esc
        | KeyCode::Enter => app.cancel_quit(),
        _ => {}
    }
}

/// Handle keys while the PR-output popup is open: navigate the resolving PRs,
/// and close on `q`, `Esc`, or `p` (#143).
fn handle_pr_output_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.pr_output_next(),
        KeyCode::Char('k') | KeyCode::Up => app.pr_output_previous(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('p') => app.close_pr_output(),
        _ => {}
    }
}

/// Handle keys while the closed-issues (spend) popup is open: navigate the
/// closed issues, and close on `q`, `Esc`, or `t` (#145).
fn handle_closed_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.closed_next(),
        KeyCode::Char('k') | KeyCode::Up => app.closed_previous(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('t') => app.close_closed(),
        _ => {}
    }
}

/// Handle keys while the cost dashboard popup is open: it has no selection to
/// move, so only close on `q`, `Esc`, or `$` (#163).
fn handle_cost_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('$') => app.close_cost(),
        _ => {}
    }
}

/// Handle keys while the issue-details popup is open: scroll the body and
/// comment thread, jump to top/bottom, and close on `q`, `Esc`, or `d` (#152).
fn handle_details_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.details_scroll_down(),
        KeyCode::Char('k') | KeyCode::Up => app.details_scroll_up(),
        KeyCode::Char('g') | KeyCode::Home => app.details_scroll_top(),
        KeyCode::Char('G') | KeyCode::End => app.details_scroll_bottom(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('d') => app.close_details(),
        _ => {}
    }
}

/// Handle keys while the bots popup is open: navigate the workers, restart the
/// selected stopped/failed one with `r` (or Enter), restart all stopped/failed
/// with `R`, and close on `q`, `Esc`, or `b` (#82).
fn handle_bots_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.bots_next(),
        KeyCode::Char('k') | KeyCode::Up => app.bots_previous(),
        KeyCode::Char('r') | KeyCode::Enter => app.restart_selected_bot(),
        KeyCode::Char('R') => app.restart_all_stopped_bots(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('b') => app.close_bots(),
        _ => {}
    }
}

/// Handle a key while the messages popup is open: scroll the log with j/k (or
/// the arrows), jump to the newest/oldest with g/G, and close on `q`, `Esc`, or
/// `M` (#182).
fn handle_messages_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('j') | KeyCode::Down => app.messages_next(),
        KeyCode::Char('k') | KeyCode::Up => app.messages_previous(),
        KeyCode::Char('g') | KeyCode::Home => app.messages_first(),
        KeyCode::Char('G') | KeyCode::End => app.messages_last(),
        KeyCode::Char('q') | KeyCode::Esc | KeyCode::Char('M') => app.close_messages(),
        _ => {}
    }
}

/// Handle a key while the reply popup is open: type the reply, scroll the
/// question pane with the arrow keys (typing consumes the printable keys, so
/// arrows do the scrolling), Ctrl+S to send, Esc to cancel (#165).
fn handle_reply_key(app: &mut App, key: KeyEvent) {
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('s') {
        app.submit_reply();
        return;
    }

    match key.code {
        KeyCode::Esc => app.close_reply(),
        KeyCode::Up => app.reply_scroll_up(),
        KeyCode::Down => app.reply_scroll_down(),
        KeyCode::Backspace => app.reply_backspace(),
        KeyCode::Enter => app.reply_newline(),
        // Ignore control/alt combos so shortcuts don't leak into the text.
        KeyCode::Char(c)
            if !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
        {
            app.reply_input(c)
        }
        _ => {}
    }
}

/// Handle a key while the new-issue form is open: type into the focused field,
/// Tab to switch fields, Ctrl+S to create, Esc to cancel.
fn handle_create_key(app: &mut App, key: KeyEvent) {
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('s') {
        app.submit_create();
        return;
    }

    match key.code {
        KeyCode::Esc => app.cancel_create(),
        KeyCode::Tab | KeyCode::BackTab => app.form_toggle_field(),
        KeyCode::Backspace => app.form_backspace(),
        KeyCode::Enter => app.form_newline(),
        // Ignore control/alt combos so shortcuts don't leak into the text.
        KeyCode::Char(c)
            if !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
        {
            app.form_input(c)
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::{handle_key, wants_loop_refresh, wants_version};
    use crate::app::App;
    use crate::github::parse_issues;
    use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    fn press(app: &mut App, code: KeyCode) {
        handle_key(app, KeyEvent::new(code, KeyModifiers::NONE));
    }

    #[test]
    fn version_flag_is_recognised() {
        assert!(wants_version(["--version".to_string()]));
        assert!(wants_version(["-V".to_string()]));
        assert!(wants_version([
            "--repo".to_string(),
            "--version".to_string()
        ]));
        assert!(!wants_version(["-x".to_string()]));
        assert!(!wants_version(Vec::<String>::new()));
    }

    #[test]
    fn space_opens_the_leader_menu() {
        let mut app = App::new(Vec::new());
        assert!(!app.leader_active());
        press(&mut app, KeyCode::Char(' '));
        assert!(app.leader_active());
    }

    #[test]
    fn leader_then_c_opens_create_and_closes_the_menu() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('c'));
        assert!(app.is_creating());
        assert!(!app.leader_active());
    }

    #[test]
    fn leader_then_b_opens_the_bots_popup_and_closes_the_menu() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('b'));
        assert!(app.bots_open());
        assert!(!app.leader_active());
        // A key inside the popup is captured by it, not the list: b closes it.
        press(&mut app, KeyCode::Char('b'));
        assert!(!app.bots_open());
    }

    #[test]
    fn leader_then_shift_m_opens_and_closes_the_messages_popup() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('M'));
        assert!(app.messages_open());
        assert!(!app.leader_active());
        // A key inside the popup is captured by it, not the list: M closes it.
        press(&mut app, KeyCode::Char('M'));
        assert!(!app.messages_open());
    }

    #[test]
    fn cost_dashboard_popup_captures_and_closes_on_dollar() {
        // Seed the popup open (avoids a live `gh` fetch), then a `$` press is
        // captured by the popup and closes it (#163).
        let mut app = App::new(Vec::new());
        app.open_cost_with(Vec::new());
        assert!(app.cost_open());
        press(&mut app, KeyCode::Char('$'));
        assert!(!app.cost_open());
    }

    #[test]
    fn actions_are_gated_behind_the_leader_key() {
        // Without pressing space first the action keys do nothing — issue
        // actions are hidden until the leader opens the menu (#129).
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char('c'));
        assert!(!app.is_creating());
        assert!(!app.leader_active());
    }

    #[test]
    fn leader_r_marks_ready_reusing_the_refresh_key() {
        // `r` means ready inside the menu (it refreshed before #129); the menu
        // closes afterwards.
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        assert!(!app.selected_is_ready());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('r'));
        assert!(app.selected_is_ready());
        assert!(!app.leader_active());
    }

    #[test]
    fn an_unbound_key_cancels_the_leader_menu() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Esc);
        assert!(!app.leader_active());
        assert!(!app.is_creating());
    }

    #[test]
    fn f_refreshes_from_the_base_keymap_without_the_leader() {
        // Refresh is global now (#174): pressing `f` on the list — no `space`
        // first — kicks off a refresh, shown by the in-flight "Refreshing…"
        // state. Attaching a fetcher takes the off-thread path so the flag flips
        // without a blocking `gh` fetch on the test thread.
        use crate::worker::IssueFetcher;
        let mut app = App::new(Vec::new());
        app.set_fetcher(IssueFetcher::spawn(1));
        assert!(!app.is_refreshing());
        press(&mut app, KeyCode::Char('f'));
        assert!(app.is_refreshing());
        assert!(!app.leader_active());
    }

    #[test]
    fn f_is_no_longer_an_issue_action_behind_the_leader() {
        // Refresh left the issue-action menu (#174): `space` then `f` no longer
        // refreshes — `f` is unbound in the leader, so it just cancels the menu.
        use crate::worker::IssueFetcher;
        let mut app = App::new(Vec::new());
        app.set_fetcher(IssueFetcher::spawn(1));
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('f'));
        assert!(!app.is_refreshing());
        assert!(!app.leader_active());
    }

    #[test]
    fn leader_s_toggles_the_close_summary_and_closes_the_menu() {
        // `s` flips the report-on-close setting (on by default) and closes the
        // leader menu, like the other one-shot actions (#161).
        let mut app = App::new(Vec::new());
        assert!(app.report_on_close());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('s'));
        assert!(!app.report_on_close());
        assert!(!app.leader_active());
    }

    #[test]
    fn navigation_works_without_the_leader_key() {
        let issues = parse_issues(
            r#"[{"number":1,"title":"a"},{"number":2,"title":"b"},{"number":3,"title":"c"}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        assert_eq!(app.state.selected(), Some(0));
        press(&mut app, KeyCode::Char('j'));
        assert_eq!(app.state.selected(), Some(1));
        assert!(!app.leader_active());
    }

    #[test]
    fn refreshes_periodically_while_running() {
        assert!(wants_loop_refresh(true, true, true));
    }

    #[test]
    fn waits_for_the_interval_while_running() {
        assert!(!wants_loop_refresh(true, true, false));
    }

    #[test]
    fn refreshes_the_tick_the_loop_finishes() {
        // The finishing refresh fires even before the interval elapses (#121).
        assert!(wants_loop_refresh(true, false, false));
        assert!(wants_loop_refresh(true, false, true));
    }

    #[test]
    fn does_not_refresh_again_after_the_loop_has_stopped() {
        assert!(!wants_loop_refresh(false, false, false));
        assert!(!wants_loop_refresh(false, false, true));
    }

    #[test]
    fn refreshes_when_the_loop_just_started_and_the_interval_elapsed() {
        assert!(wants_loop_refresh(false, true, true));
    }

    #[test]
    fn leader_then_i_without_a_question_is_gated() {
        // `space i` opens the reply popup, but only for a needs-info issue; a
        // plain issue is refused (no `gh` call) and the menu still closes (#165).
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('i'));
        assert!(!app.reply_open());
        assert!(!app.leader_active());
    }

    #[test]
    fn reply_popup_captures_typing_and_esc_closes_it() {
        // With the popup open, printable keys type into the draft rather than
        // navigating the list, and Esc closes it (#165).
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[{"name":"needs-info"}]}]"#)
                .unwrap();
        let mut app = App::new(issues);
        let issue = app.selected().cloned().unwrap();
        app.open_reply_with(issue);
        press(&mut app, KeyCode::Char('h'));
        press(&mut app, KeyCode::Char('i'));
        assert_eq!(app.reply_text(), "hi");
        press(&mut app, KeyCode::Esc);
        assert!(!app.reply_open());
    }

    #[test]
    fn q_asks_for_confirmation_instead_of_quitting_immediately() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char('q'));
        assert!(app.quit_confirm());
        assert!(!app.should_quit);
    }

    #[test]
    fn esc_asks_for_confirmation_instead_of_quitting_immediately() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Esc);
        assert!(app.quit_confirm());
        assert!(!app.should_quit);
    }

    #[test]
    fn y_confirms_the_quit_prompt() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char('q'));
        press(&mut app, KeyCode::Char('y'));
        assert!(!app.quit_confirm());
        assert!(app.should_quit);
    }

    #[test]
    fn n_esc_and_q_cancel_the_quit_prompt() {
        for cancel in [KeyCode::Char('n'), KeyCode::Esc, KeyCode::Char('q')] {
            let mut app = App::new(Vec::new());
            press(&mut app, KeyCode::Char('q'));
            press(&mut app, cancel);
            assert!(!app.quit_confirm(), "prompt should close on {cancel:?}");
            assert!(!app.should_quit, "should not quit on {cancel:?}");
        }
    }

    #[test]
    fn an_unbound_key_keeps_the_quit_prompt_open() {
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char('q'));
        press(&mut app, KeyCode::Char('j'));
        assert!(app.quit_confirm());
        assert!(!app.should_quit);
    }

    #[test]
    fn ctrl_c_quits_without_a_confirmation() {
        let mut app = App::new(Vec::new());
        handle_key(
            &mut app,
            KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL),
        );
        assert!(!app.quit_confirm());
        assert!(app.should_quit);
    }

    #[test]
    fn q_inside_another_popup_does_not_open_the_quit_prompt() {
        // With a popup open, `q` is captured by it (closes the bots popup) and
        // never reaches the quit path (#167).
        let mut app = App::new(Vec::new());
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('b'));
        assert!(app.bots_open());
        press(&mut app, KeyCode::Char('q'));
        assert!(!app.bots_open());
        assert!(!app.quit_confirm());
        assert!(!app.should_quit);
    }

    #[test]
    fn marking_an_in_progress_issue_ready_opens_a_confirmation() {
        // `space r` on an issue the loop is already working asks first (#173).
        let issues = parse_issues(
            r#"[{"number":96,"title":"t","labels":[{"name":"in-progress"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('r'));
        assert_eq!(app.ready_confirm(), Some(96));
    }

    #[test]
    fn n_esc_and_q_cancel_the_ready_prompt() {
        for cancel in [KeyCode::Char('n'), KeyCode::Esc, KeyCode::Char('q')] {
            let issues = parse_issues(
                r#"[{"number":96,"title":"t","labels":[{"name":"in-progress"}],"author":null}]"#,
            )
            .unwrap();
            let mut app = App::new(issues);
            press(&mut app, KeyCode::Char(' '));
            press(&mut app, KeyCode::Char('r'));
            assert_eq!(app.ready_confirm(), Some(96));
            press(&mut app, cancel);
            assert_eq!(
                app.ready_confirm(),
                None,
                "prompt should close on {cancel:?}"
            );
        }
    }

    #[test]
    fn an_unbound_key_keeps_the_ready_prompt_open() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"t","labels":[{"name":"in-progress"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        press(&mut app, KeyCode::Char(' '));
        press(&mut app, KeyCode::Char('r'));
        press(&mut app, KeyCode::Char('k'));
        assert_eq!(app.ready_confirm(), Some(96));
    }
}
