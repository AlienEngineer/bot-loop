//! Rendering for the issue TUI.

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, List, ListItem, Paragraph, Wrap},
};

use crate::app::{App, CreateField};
use crate::github::Issue;

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
    render_body(frame, body_area, app);
    render_footer(frame, footer_area, app, loop_running);

    if app.is_creating() {
        render_create_form(frame, app);
    }
}

fn render_header(frame: &mut Frame, area: ratatui::layout::Rect, app: &App, loop_running: bool) {
    let count = app.issues.len();
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
    if let Some(issue) = app.selected() {
        spans.push(Span::styled(
            format!("  ·  viewing #{}", issue.number),
            Style::new().fg(Color::DarkGray),
        ));
    }
    let (loop_text, loop_color) = if loop_running {
        ("  ·  loop: running", Color::Green)
    } else {
        ("  ·  loop: off", Color::DarkGray)
    };
    spans.push(Span::styled(loop_text, Style::new().fg(loop_color)));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_body(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App) {
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

    let items: Vec<ListItem> = app.issues.iter().map(issue_item).collect();
    let list = List::new(items)
        .block(block)
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, area, &mut app.state);
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
        format!("j/k move · g/G top/bottom · c new · s ready · {loop_key} · r refresh · q quit"),
        Style::new().fg(Color::DarkGray),
    ));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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

/// Format a single issue as a list row: number, title, and labels.
fn issue_item(issue: &Issue) -> ListItem<'static> {
    let mut spans = vec![
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
