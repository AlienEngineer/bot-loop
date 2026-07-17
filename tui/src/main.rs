//! copilot-loop-tui — a ratatui terminal UI that lists GitHub issues.
//!
//! First slice of the ratatui rewrite (#51): fetch the repository's open issues
//! with the `gh` CLI and show them in a scrollable, vim-navigable list.

mod app;
mod github;
mod runner;
mod ui;

use std::time::Duration;

use anyhow::Result;
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

use app::{App, DEFAULT_LIMIT};

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

/// The main draw/input loop. Polls for key events and redraws each tick.
fn run(terminal: &mut DefaultTerminal, app: &mut App) -> Result<()> {
    while !app.should_quit {
        terminal.draw(|frame| ui::render(frame, app))?;

        if event::poll(Duration::from_millis(250))?
            && let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            handle_key(app, key);
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
        KeyCode::Char('l') => app.toggle_loop(),
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
        KeyCode::Char(c) => {
            // Ignore control/alt combos so shortcuts don't leak into the text.
            if !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
            {
                app.form_input(c);
            }
        }
        _ => {}
    }
}
