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

use std::time::{Duration, Instant};

use anyhow::Result;
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use app::{App, DEFAULT_LIMIT};

/// How often to silently re-fetch issues while the background loop runs, so the
/// list's in-progress markers track what the loop is doing without a manual
/// refresh (#115).
const LOOP_REFRESH_INTERVAL: Duration = Duration::from_secs(5);

fn main() -> Result<()> {
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

    let mut terminal = ratatui::init();
    let result = run(&mut terminal, &mut app);
    ratatui::restore();
    result
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
        terminal.draw(|frame| ui::render(frame, app))?;

        if event::poll(Duration::from_millis(250))?
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

/// Map a key press to an action. Vim-style navigation per #51.
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

    if app.is_creating() {
        handle_create_key(app, key);
        return;
    }

    match key.code {
        KeyCode::Char('q') | KeyCode::Esc => app.should_quit = true,
        KeyCode::Char('j') | KeyCode::Down => app.next(),
        KeyCode::Char('k') | KeyCode::Up => app.previous(),
        KeyCode::Char('g') | KeyCode::Home => app.first(),
        KeyCode::Char('G') | KeyCode::End => app.last(),
        KeyCode::Char('r') => app.refresh(),
        KeyCode::Char('c') => app.open_create(),
        KeyCode::Char('s') | KeyCode::Enter => app.mark_ready(),
        KeyCode::Char('x') => app.request_close(),
        KeyCode::Char('l') => app.toggle_loop(),
        KeyCode::Char('m') => app.open_model_picker(),
        KeyCode::Char('o') => app.toggle_output(),
        KeyCode::Char('p') => app.open_pr_output(),
        KeyCode::Char('t') => app.open_closed(),
        _ => {}
    }
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
    use super::wants_loop_refresh;

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
