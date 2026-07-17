//! Rendering for the issue TUI.

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, Paragraph, Wrap},
};

use crate::app::{App, CreateField, OUTPUT_TAIL_BYTES};
use crate::github::Issue;
use crate::logs;

/// Draw the whole UI: header, issue list (or placeholder), and footer.
pub fn render(frame: &mut Frame, app: &mut App) {
    let loop_running = app.loop_running();
    let [header_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    render_header(frame, header_area, app, loop_running);
    render_body(frame, body_area, app, loop_running);
    render_footer(frame, footer_area, app, loop_running);

    // The model picker floats above everything else when open.
    if app.model_picker_open() {
        render_model_picker(frame, frame.area(), app);
    }
    if app.is_creating() {
        render_create_form(frame, app);
    }
}

/// Braille spinner frames used to signal the loop is alive (#115).
const SPINNER_FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

/// The spinner frame for a given wall-clock instant (milliseconds), advancing
/// every 100ms so it visibly turns across redraws. Pure for testing.
fn spinner_frame_at(millis: u128) -> &'static str {
    SPINNER_FRAMES[((millis / 100) % SPINNER_FRAMES.len() as u128) as usize]
}

/// The current spinner frame from the system clock.
fn spinner_frame() -> &'static str {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    spinner_frame_at(millis)
}

/// A "working #96, #97" summary of the issues the loop is currently on, or
/// `None` when it holds no issue. Pure for testing (#115).
fn working_summary(working: &[u64]) -> Option<String> {
    if working.is_empty() {
        return None;
    }
    let list = working
        .iter()
        .map(|n| format!("#{n}"))
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!("working {list}"))
}

/// Build the header line spans: issue count, the viewed issue, the loop state,
/// and the model. When the loop runs a turning spinner and the issue it is
/// working (or "waiting for work") are shown so it is clear something is
/// happening and which issue it is (#115). Pure so the running branch — which
/// otherwise needs a live child process — is unit-testable.
fn header_spans(
    count: usize,
    viewing: Option<u64>,
    loop_running: bool,
    working: &[u64],
    model_label: &str,
    spinner: &str,
) -> Vec<Span<'static>> {
    let mut spans = vec![
        Span::styled(
            " GitHub Issues ",
            Style::new()
                .fg(Color::Black)
                .bg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {count} open"),
            Style::new().add_modifier(Modifier::BOLD),
        ),
    ];
    if let Some(number) = viewing {
        spans.push(Span::styled(
            format!("  ·  viewing #{number}"),
            Style::new().fg(Color::DarkGray),
        ));
    }
    if loop_running {
        spans.push(Span::styled(
            format!("  ·  {spinner} loop: running"),
            Style::new().fg(Color::Green).add_modifier(Modifier::BOLD),
        ));
        match working_summary(working) {
            Some(summary) => spans.push(Span::styled(
                format!("  ·  {summary}"),
                Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
            )),
            None => spans.push(Span::styled(
                "  ·  waiting for work",
                Style::new().fg(Color::DarkGray),
            )),
        }
    } else {
        spans.push(Span::styled(
            "  ·  loop: off",
            Style::new().fg(Color::DarkGray),
        ));
    }
    spans.push(Span::styled(
        format!("  ·  model: {model_label}"),
        Style::new().fg(Color::Magenta),
    ));
    spans
}

fn render_header(frame: &mut Frame, area: ratatui::layout::Rect, app: &App, loop_running: bool) {
    let spans = header_spans(
        app.issues.len(),
        app.selected().map(|issue| issue.number),
        loop_running,
        &app.in_progress_numbers(),
        app.current_model_label(),
        spinner_frame(),
    );
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Draw the body: the issue list, plus the output side panel when it is open
/// and an issue is selected (#107).
fn render_body(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App, loop_running: bool) {
    if app.output_visible() && app.selected().is_some() {
        let [list_area, panel_area] =
            Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
        render_list(frame, list_area, app, loop_running);
        render_output_panel(frame, panel_area, app);
    } else {
        render_list(frame, area, app, loop_running);
    }
}

fn render_list(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App, loop_running: bool) {
    // Remember how many rows the list can show so page/half-page motions
    // (Ctrl-f/Ctrl-b, Ctrl-d/Ctrl-u) know how far to jump; borders take 2 rows.
    app.set_viewport_height(area.height.saturating_sub(2) as usize);

    let block = Block::default().borders(Borders::ALL).title(" Issues ");

    if app.issues.is_empty() {
        let msg = app
            .status
            .clone()
            .unwrap_or_else(|| "No open issues.".to_string());
        let placeholder = Paragraph::new(msg)
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(placeholder, area);
        return;
    }

    let spinner = spinner_frame();
    let items: Vec<ListItem> = app
        .issues
        .iter()
        .map(|issue| issue_item(issue, loop_running, spinner))
        .collect();
    let list = List::new(items)
        .block(block)
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, area, &mut app.state);
}

/// Show the tail of the running loop's log for the selected issue, following the
/// bottom like `tail -f` so the newest output is always visible.
fn render_output_panel(frame: &mut Frame, area: ratatui::layout::Rect, app: &App) {
    let number = app.selected().map(|issue| issue.number);
    let title = match number {
        Some(n) => format!(" Output · #{n} "),
        None => " Output ".to_string(),
    };
    let block = Block::default().borders(Borders::ALL).title(title);

    match app.selected_output(OUTPUT_TAIL_BYTES) {
        Some((_path, text)) => {
            // Two rows go to the borders; show the last lines that fit so the
            // freshest output stays on screen.
            let inner_height = area.height.saturating_sub(2) as usize;
            let body: Vec<Line> = logs::last_lines(&text, inner_height)
                .into_iter()
                .map(|line| Line::raw(line.to_string()))
                .collect();
            frame.render_widget(Paragraph::new(body).block(block), area);
        }
        None => {
            let msg = match number {
                Some(n) => format!("No loop output yet for #{n}."),
                None => "No issue selected.".to_string(),
            };
            frame.render_widget(
                Paragraph::new(msg)
                    .block(block)
                    .alignment(Alignment::Center)
                    .style(Style::new().fg(Color::DarkGray)),
                area,
            );
        }
    }
}

fn render_footer(frame: &mut Frame, area: ratatui::layout::Rect, app: &App, loop_running: bool) {
    let mut spans = Vec::new();
    if let Some(status) = &app.status {
        spans.push(Span::styled(
            format!(" {status} "),
            Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw("  "));
    }
    let loop_key = if loop_running {
        "l stop-loop"
    } else {
        "l start-loop"
    };
    spans.push(Span::styled(
        format!("j/k move · gg/G top/bottom · ^u/^d/^b/^f scroll · c new · s ready · {loop_key} · m models · o output · r refresh · q quit"),
        Style::new().fg(Color::DarkGray),
    ));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Draw the model picker popup: a centered, bordered list of models with the
/// current one highlighted. A [`Clear`] underneath wipes the cells so the list
/// behind it does not show through.
fn render_model_picker(frame: &mut Frame, area: Rect, app: &mut App) {
    let height = (app.models.len() as u16 + 2).min(area.height.max(3));
    let popup = centered_popup(area, 40, height);

    let items: Vec<ListItem> = app
        .models
        .iter()
        .map(|m| ListItem::new(Line::from(Span::raw(m.clone()))))
        .collect();

    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Select model ")
        .title_bottom(Line::from(" j/k move · Enter select · Esc cancel ").centered())
        .style(Style::new().bg(Color::Black));
    let list = List::new(items)
        .block(block)
        .highlight_style(
            Style::new()
                .fg(Color::Black)
                .bg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▶ ");

    frame.render_widget(Clear, popup);
    frame.render_stateful_widget(list, popup, &mut app.model_state);
}

/// A rectangle of `width` columns and `height` rows centered within `area`,
/// clamped to fit. `width` is a percentage of `area`'s width.
fn centered_popup(area: Rect, width_pct: u16, height: u16) -> Rect {
    let [row] = Layout::vertical([Constraint::Length(height.min(area.height))])
        .flex(Flex::Center)
        .areas(area);
    let [col] = Layout::horizontal([Constraint::Percentage(width_pct)])
        .flex(Flex::Center)
        .areas(row);
    col
}

/// Draw the modal new-issue form centered over the list.
fn render_create_form(frame: &mut Frame, app: &App) {
    let area = centered_rect(70, 60, frame.area());
    frame.render_widget(Clear, area);

    let outer = Block::default()
        .borders(Borders::ALL)
        .title(" New Issue ")
        .title_alignment(Alignment::Center)
        .border_style(Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    let inner = outer.inner(area);
    frame.render_widget(outer, area);

    let [title_area, desc_area, help_area] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(3),
        Constraint::Length(1),
    ])
    .areas(inner);

    let field = app.form.field;
    frame.render_widget(
        field_widget("Title", &app.form.title, field == CreateField::Title),
        title_area,
    );
    frame.render_widget(
        field_widget(
            "Description",
            &app.form.description,
            field == CreateField::Description,
        ),
        desc_area,
    );

    let help = Paragraph::new(Line::from(Span::styled(
        "Tab switch · Enter newline/next · Ctrl+S create · Esc cancel",
        Style::new().fg(Color::DarkGray),
    )))
    .alignment(Alignment::Center);
    frame.render_widget(help, help_area);
}

/// A bordered text field for the create form; the focused one is highlighted
/// and shows a trailing cursor.
fn field_widget(label: &str, value: &str, focused: bool) -> Paragraph<'static> {
    let border_style = if focused {
        Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD)
    } else {
        Style::new().fg(Color::DarkGray)
    };
    let text = if focused {
        format!("{value}▏")
    } else {
        value.to_string()
    };
    Paragraph::new(text)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(format!(" {label} "))
                .border_style(border_style),
        )
        .wrap(Wrap { trim: false })
}

/// A rectangle centered within `area`, sized to the given width/height percent.
fn centered_rect(percent_x: u16, percent_y: u16, area: Rect) -> Rect {
    let vertical = Layout::vertical([
        Constraint::Percentage((100 - percent_y) / 2),
        Constraint::Percentage(percent_y),
        Constraint::Percentage((100 - percent_y) / 2),
    ])
    .split(area);
    Layout::horizontal([
        Constraint::Percentage((100 - percent_x) / 2),
        Constraint::Percentage(percent_x),
        Constraint::Percentage((100 - percent_x) / 2),
    ])
    .split(vertical[1])[1]
}

/// The two-column gutter shown before an issue's number: a turning spinner
/// while the loop actively works it, a static dot for an in-progress label
/// with no running loop, or blanks so every row's number stays aligned (#115).
fn progress_marker(in_progress: bool, loop_running: bool, spinner: &str) -> Span<'static> {
    if !in_progress {
        return Span::raw("  ");
    }
    if loop_running {
        Span::styled(
            format!("{spinner} "),
            Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled("● ", Style::new().fg(Color::DarkGray))
    }
}

/// Format a single issue as a list row: an in-progress marker, number, title,
/// and labels.
fn issue_item(issue: &Issue, loop_running: bool, spinner: &str) -> ListItem<'static> {
    let mut spans = vec![
        progress_marker(issue.is_in_progress(), loop_running, spinner),
        Span::styled(
            format!("#{:<5}", issue.number),
            Style::new().fg(Color::Yellow),
        ),
        Span::raw(" "),
        Span::raw(issue.title.clone()),
    ];

    let labels = issue.label_names();
    if !labels.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("[{}]", labels.join(", ")),
            Style::new().fg(Color::Cyan),
        ));
    }

    let author = issue.author_login();
    if !author.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("@{author}"),
            Style::new().fg(Color::Green),
        ));
    }

    ListItem::new(Line::from(spans))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::App;
    use crate::github::parse_issues;
    use ratatui::{Terminal, backend::TestBackend};

    fn buffer_text(terminal: &Terminal<TestBackend>) -> String {
        terminal
            .backend()
            .buffer()
            .content
            .iter()
            .map(|cell| cell.symbol())
            .collect()
    }

    #[test]
    fn renders_issue_rows() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"create a TUI","labels":[{"name":"in-progress"}],"author":{"login":"octocat"}}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("GitHub Issues"));
        assert!(text.contains("1 open"));
        assert!(text.contains("#96"));
        assert!(text.contains("create a TUI"));
        assert!(text.contains("in-progress"));
        assert!(text.contains("octocat"));
    }

    #[test]
    fn renders_placeholder_when_empty() {
        let mut app = App::new(Vec::new());
        app.status = Some("No open issues found.".to_string());
        let mut terminal = Terminal::new(TestBackend::new(60, 8)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No open issues found."));
    }

    #[test]
    fn header_shows_loop_off_by_default() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("loop: off"));
        assert!(text.contains("start-loop"));
    }

    #[test]
    fn header_shows_the_current_model_and_footer_hint() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("model: auto"));
        assert!(text.contains("m models"));
    }

    #[test]
    fn footer_advertises_the_output_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("o output"));
    }

    fn spans_text(spans: &[Span]) -> String {
        spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn spinner_frame_advances_and_wraps_with_time() {
        assert_eq!(spinner_frame_at(0), SPINNER_FRAMES[0]);
        assert_eq!(spinner_frame_at(100), SPINNER_FRAMES[1]);
        assert_eq!(spinner_frame_at(1000), SPINNER_FRAMES[0]); // wraps after the last frame
    }

    #[test]
    fn working_summary_lists_numbers_or_none() {
        assert_eq!(working_summary(&[]), None);
        assert_eq!(working_summary(&[96]).as_deref(), Some("working #96"));
        assert_eq!(
            working_summary(&[96, 97]).as_deref(),
            Some("working #96, #97")
        );
    }

    #[test]
    fn header_shows_spinner_and_working_issue_when_loop_runs() {
        let text = spans_text(&header_spans(3, Some(96), true, &[96], "auto", "⠋"));
        assert!(text.contains("⠋ loop: running"));
        assert!(text.contains("working #96"));
        assert!(text.contains("model: auto"));
    }

    #[test]
    fn header_says_waiting_when_loop_runs_without_an_issue() {
        let text = spans_text(&header_spans(3, None, true, &[], "auto", "⠋"));
        assert!(text.contains("loop: running"));
        assert!(text.contains("waiting for work"));
    }

    #[test]
    fn header_hides_loop_details_when_off() {
        let text = spans_text(&header_spans(3, Some(96), false, &[96], "auto", "⠋"));
        assert!(text.contains("loop: off"));
        assert!(!text.contains("working"));
        assert!(!text.contains("⠋"));
    }

    #[test]
    fn progress_marker_reflects_state() {
        assert_eq!(spans_text(&[progress_marker(false, true, "⠋")]), "  ");
        assert_eq!(spans_text(&[progress_marker(true, true, "⠋")]), "⠋ ");
        assert_eq!(spans_text(&[progress_marker(true, false, "⠋")]), "● ");
    }

    #[test]
    fn renders_in_progress_marker_in_the_list() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"t","labels":[{"name":"in-progress"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        // The loop is off, so an in-progress issue shows the static dot marker.
        assert!(buffer_text(&terminal).contains("●"));
    }

    #[test]
    fn renders_the_model_picker_popup_when_open() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        let first_model = app.models[0].clone();
        app.open_model_picker();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Select model"));
        assert!(text.contains(first_model.as_str()));
        assert!(text.contains("Enter select"));
    }

    #[test]
    fn renders_output_panel_tail_when_open() {
        let dir = std::env::temp_dir().join(format!("copilot-ui-output-{}", std::process::id()));
        let logs = dir.join(".copilot-loop").join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(
            logs.join("issue-96-20260101-000000.log"),
            "\x1b[32mloop is working hard\x1b[0m\n",
        )
        .unwrap();

        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        app.set_repo_root(dir.clone());
        app.toggle_output();

        let mut terminal = Terminal::new(TestBackend::new(120, 12)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Output"));
        assert!(text.contains("#96"));
        // The ANSI colour codes are stripped before display.
        assert!(text.contains("loop is working hard"));
        assert!(!text.contains("[32m"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn output_panel_shows_placeholder_without_a_log() {
        let dir = std::env::temp_dir().join(format!("copilot-ui-empty-{}", std::process::id()));
        let issues =
            parse_issues(r#"[{"number":42,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.set_repo_root(dir);
        app.toggle_output();

        let mut terminal = Terminal::new(TestBackend::new(100, 10)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No loop output yet for #42."));
    }

    #[test]
    fn renders_the_create_form_overlay() {
        let mut app = App::new(Vec::new());
        app.open_create();
        for c in "Bug".chars() {
            app.form_input(c);
        }
        let mut terminal = Terminal::new(TestBackend::new(80, 16)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("New Issue"));
        assert!(text.contains("Title"));
        assert!(text.contains("Description"));
        assert!(text.contains("Bug"));
        assert!(text.contains("Ctrl+S create"));
    }
}
