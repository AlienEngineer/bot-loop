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
/// progress (which issue is in-progress) stays visible (#115).
fn run(terminal: &mut DefaultTerminal, app: &mut App) -> Result<()> {
    let mut last_refresh = Instant::now();
    while !app.should_quit {
        terminal.draw(|frame| ui::render(frame, app))?;

        if event::poll(Duration::from_millis(250))?
            && let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            handle_key(app, key);
        }

        if app.loop_running() && last_refresh.elapsed() >= LOOP_REFRESH_INTERVAL {
            app.auto_refresh();
            last_refresh = Instant::now();
        }
    }
    Ok(())
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
