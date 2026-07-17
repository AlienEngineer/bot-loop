//! Rendering for the issue TUI.

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
};

use crate::app::App;
use crate::github::Issue;

/// Draw the whole UI: header, issue list (or placeholder), and footer.
pub fn render(frame: &mut Frame, app: &mut App) {
    let [header_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    render_header(frame, header_area, app);
    render_body(frame, body_area, app);
    render_footer(frame, footer_area, app);
}

fn render_header(frame: &mut Frame, area: ratatui::layout::Rect, app: &App) {
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

fn render_footer(frame: &mut Frame, area: ratatui::layout::Rect, app: &App) {
    let mut spans = Vec::new();
    if let Some(status) = &app.status {
        spans.push(Span::styled(
            format!(" {status} "),
            Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw("  "));
    }
    spans.push(Span::styled(
        "j/k move · g/G top/bottom · s start · r refresh · q quit",
        Style::new().fg(Color::DarkGray),
    ));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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
}
