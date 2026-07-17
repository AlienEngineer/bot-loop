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

    if app.is_creating() {
        handle_create_key(app, key);
        return;
    }

    handle_list_key(app, key);
}

/// Handle a key while browsing the issue list. Vim motions (#51): counts like
/// `5j`, `gg`/`G` for top/bottom (or go-to-line N with a count), and
/// Ctrl-d/u/f/b plus PageUp/PageDown for half- and full-page scrolling. Any
/// other action clears a half-typed count/`g` prefix so it can't leak on.
fn handle_list_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Char('d') if ctrl => app.half_page_down(),
        KeyCode::Char('u') if ctrl => app.half_page_up(),
        KeyCode::Char('f') if ctrl => app.page_down(),
        KeyCode::Char('b') if ctrl => app.page_up(),
        KeyCode::PageDown => app.page_down(),
        KeyCode::PageUp => app.page_up(),
        // Digits build a count; a leading `0` is unbound (matches vim), but a
        // `0` after other digits (e.g. `10`) is a trailing digit.
        KeyCode::Char(d @ '0'..='9') if !ctrl && (d != '0' || app.has_pending_count()) => {
            app.push_count_digit((d as u8 - b'0') as usize);
        }
        KeyCode::Char('j') | KeyCode::Down => app.motion_down(),
        KeyCode::Char('k') | KeyCode::Up => app.motion_up(),
        KeyCode::Char('g') => app.press_g(),
        KeyCode::Home => app.motion_top(),
        KeyCode::Char('G') | KeyCode::End => app.motion_bottom(),
        KeyCode::Char('q') | KeyCode::Esc => {
            app.reset_pending();
            app.should_quit = true;
        }
        KeyCode::Char('r') => {
            app.reset_pending();
            app.refresh();
        }
        KeyCode::Char('c') => {
            app.reset_pending();
            app.open_create();
        }
        KeyCode::Char('s') | KeyCode::Enter => {
            app.reset_pending();
            app.mark_ready();
        }
        KeyCode::Char('l') => {
            app.reset_pending();
            app.toggle_loop();
        }
        KeyCode::Char('m') => {
            app.reset_pending();
            app.open_model_picker();
        }
        KeyCode::Char('o') => {
            app.reset_pending();
            app.toggle_output();
        }
        _ => app.reset_pending(),
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
    use super::{handle_key, wants_loop_refresh};
    use crate::app::App;
    use crate::github::parse_issues;
    use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

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

    fn app_with(count: usize) -> App {
        let items: Vec<String> = (0..count)
            .map(|i| format!(r#"{{"number": {i}, "title": "t{i}"}}"#))
            .collect();
        let json = format!("[{}]", items.join(","));
        App::new(parse_issues(&json).unwrap())
    }

    fn press(app: &mut App, code: KeyCode) {
        handle_key(app, KeyEvent::new(code, KeyModifiers::NONE));
    }

    fn ctrl(app: &mut App, code: KeyCode) {
        handle_key(app, KeyEvent::new(code, KeyModifiers::CONTROL));
    }

    #[test]
    fn gg_binding_jumps_to_the_top() {
        let mut app = app_with(10);
        press(&mut app, KeyCode::Char('G'));
        assert_eq!(app.state.selected(), Some(9));
        press(&mut app, KeyCode::Char('g'));
        press(&mut app, KeyCode::Char('g'));
        assert_eq!(app.state.selected(), Some(0));
    }

    #[test]
    fn count_prefix_binding_moves_by_n() {
        let mut app = app_with(20);
        press(&mut app, KeyCode::Char('5'));
        press(&mut app, KeyCode::Char('j'));
        assert_eq!(app.state.selected(), Some(5));
    }

    #[test]
    fn count_capital_g_binding_goes_to_line() {
        let mut app = app_with(10);
        press(&mut app, KeyCode::Char('3'));
        press(&mut app, KeyCode::Char('G'));
        assert_eq!(app.state.selected(), Some(2));
    }

    #[test]
    fn ctrl_d_binding_moves_half_a_page() {
        let mut app = app_with(100);
        app.set_viewport_height(10);
        ctrl(&mut app, KeyCode::Char('d'));
        assert_eq!(app.state.selected(), Some(5));
    }

    #[test]
    fn a_non_motion_key_clears_a_half_typed_count() {
        let mut app = app_with(20);
        press(&mut app, KeyCode::Char('5'));
        press(&mut app, KeyCode::Char('o')); // toggles output, must drop the count
        press(&mut app, KeyCode::Char('j'));
        assert_eq!(app.state.selected(), Some(1));
    }
}
