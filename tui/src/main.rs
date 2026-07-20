//! copilot-loop-tui — a ratatui terminal UI that lists GitHub issues.
//!
//! First slice of the ratatui rewrite (#51): fetch the repository's open issues
//! with the `gh` CLI and show them in a scrollable, vim-navigable list.

mod app;
mod github;
mod logs;
mod models;
mod runner;
mod ui;
mod worker;

use std::time::{Duration, Instant};

use anyhow::Result;
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use app::{App, DEFAULT_LIMIT};

/// How often to silently re-fetch issues while the background loop runs, so the
/// list's in-progress markers track what the loop is doing without a manual
/// refresh (#115).
const LOOP_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

/// How long to block for input each tick while something on screen is animating
/// — a background refresh's "Refreshing…" indicator (#130) or the running loop's
/// spinner (#115) — kept short so the spinner turns smoothly.
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
    match github::fetch_issues(DEFAULT_LIMIT) {
        Ok(issues) => {
            if issues.is_empty() {
                app.status = Some("No open issues found.".to_string());
            }
            app.set_issues(issues);
        }
        Err(err) => app.status = Some(format!("Error: {err}")),
    }

    // Run the `gh` issue/PR queries on a worker thread so the periodic
    // auto-refresh never blocks the UI loop (#144).
    app.set_fetcher(worker::IssueFetcher::spawn(DEFAULT_LIMIT));

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
/// silently refreshes the issue list on a timer while the loop runs so its
/// progress (which issue is in-progress) stays visible (#115), then once more
/// the tick the loop finishes so the final state (closed issues, dropped
/// in-progress labels) shows without a manual refresh (#121).
fn run(terminal: &mut DefaultTerminal, app: &mut App) -> Result<()> {
    let mut last_refresh = Instant::now();
    let mut loop_was_running = false;
    while !app.should_quit {
        // Fold in any issue/PR data the worker thread finished fetching, so the
        // list tracks the loop without the UI thread ever blocking on `gh`.
        app.poll_fetch_results();

        // Keep the bots popup's worker statuses live while it is open (#82).
        if app.bots_open() {
            app.refresh_bots();
        }

        terminal.draw(|frame| ui::render(frame, app))?;

        // Poll briefly while anything animates — a background refresh's
        // "Refreshing…" indicator (#130) or the running loop's spinner (#115) —
        // so the spinner turns smoothly; otherwise wait longer to stay near-idle.
        let poll_timeout = if app.is_refreshing() || app.loop_running() {
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

        let loop_running = app.loop_running();
        let interval_elapsed = last_refresh.elapsed() >= LOOP_REFRESH_INTERVAL;
        if wants_loop_refresh(loop_was_running, loop_running, interval_elapsed) {
            app.auto_refresh();
            last_refresh = Instant::now();
        }
        loop_was_running = loop_running;
    }
    Ok(())
}

/// Whether to silently re-fetch the issue list this tick: periodically while the
/// loop runs so its in-progress markers track it (#115), and once the tick the
/// loop finishes so the final state shows without a manual refresh (#121). The
/// finishing refresh fires even before the interval elapses. Pure for testing.
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
        KeyCode::Char('q') | KeyCode::Esc => app.should_quit = true,
        KeyCode::Char('j') | KeyCode::Down => app.next(),
        KeyCode::Char('k') | KeyCode::Up => app.previous(),
        KeyCode::Char('g') | KeyCode::Home => app.first(),
        KeyCode::Char('G') | KeyCode::End => app.last(),
        KeyCode::Char(' ') => app.enter_leader(),
        _ => {}
    }
}

/// Handle the key pressed after the `space` leader: run the matching issue
/// action and close the menu; any unbound key (e.g. `Esc`) just cancels it.
/// Reusing the leader namespace lets `r` mean *ready* while refresh moves to
/// `f` (#129).
fn handle_leader_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Char('c') => app.open_create(),
        KeyCode::Char('r') => app.toggle_ready(),
        KeyCode::Char('x') => app.request_close(),
        KeyCode::Char('d') => app.open_details(),
        KeyCode::Char('l') => app.start_worker(),
        KeyCode::Char('L') => app.stop_all_workers(),
        KeyCode::Char('b') => app.open_bots(),
        KeyCode::Char('a') => app.toggle_auto_merge(),
        KeyCode::Char('q') => app.toggle_quality_assurance(),
        KeyCode::Char('m') => app.open_model_picker(),
        KeyCode::Char('o') => app.toggle_output(),
        KeyCode::Char('p') => app.open_pr_output(),
        KeyCode::Char('t') => app.open_closed(),
        KeyCode::Char('f') => app.refresh(),
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
}
