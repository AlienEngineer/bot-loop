//! Rendering for the issue TUI.

use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Flex, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Bar, BarChart, Block, Borders, Clear, List, ListItem, Paragraph, Wrap},
};

use crate::app::{App, CreateField, OUTPUT_TAIL_BYTES};
use crate::cost::MonthlyCost;
use crate::github::Issue;
use crate::logs;
use crate::runner::{WorkerStatus, WorkerView};

/// Draw the whole UI: header, issue list (or placeholder), and footer.
pub fn render(frame: &mut Frame, app: &mut App) {
    let workers = app.workers_running();
    let loop_running = workers > 0;
    let [header_area, body_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    render_header(frame, header_area, app, workers);
    render_body(frame, body_area, app, loop_running);
    render_footer(frame, footer_area, app);

    // The model picker floats above everything else when open.
    if app.model_picker_open() {
        render_model_picker(frame, frame.area(), app);
    }
    if app.is_creating() {
        render_create_form(frame, app);
    }
    // The close-issue confirmation floats on top of the list (#118).
    if let Some(number) = app.close_confirm() {
        render_close_confirm(frame, frame.area(), app, number);
    }
    // The PR-output popup floats on top of everything else when open (#143).
    if app.pr_output_open() {
        render_pr_output(frame, frame.area(), app);
    }
    // The closed-issues (spend) popup floats on top when open (#145).
    if app.closed_open() {
        render_closed(frame, frame.area(), app);
    }
    // The cost dashboard floats on top of everything else when open (#163).
    if app.cost_open() {
        render_cost(frame, frame.area(), app);
    }
    // The issue-details popup floats on top of everything else when open (#152).
    if app.details_open() {
        render_details(frame, frame.area(), app);
    }
    // The bots popup floats on top of everything else when open (#82).
    if app.bots_open() {
        render_bots(frame, frame.area(), app);
    }
    // The quit confirmation floats above everything else so a stray `q`/`Esc`
    // asks before it exits the TUI (#167).
    if app.quit_confirm() {
        render_quit_confirm(frame, frame.area(), app);
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

/// A "resolving PR #12" / "resolving PRs #12, #13" summary of the pull requests
/// the loop is currently working, or `None` when it holds none. PRs are absent
/// from the issue list, so this is the surface that tells the user the loop is
/// busy on a PR. Pure for testing (#133).
fn pr_summary(prs: &[u64]) -> Option<String> {
    match prs {
        [] => None,
        [one] => Some(format!("resolving PR #{one}")),
        many => {
            let list = many
                .iter()
                .map(|n| format!("#{n}"))
                .collect::<Vec<_>>()
                .join(", ");
            Some(format!("resolving PRs {list}"))
        }
    }
}

/// Build the header line spans: issue count, the viewed issue, the loop state,
/// and the model. When workers run a turning spinner, how many workers are
/// running, and the work they are doing — the issues *and* any PRs being
/// resolved, or "waiting for work" when idle — are shown so it is clear
/// something is happening and on what (#115, #133, #134). Pure so the running
/// branch — which otherwise needs live child processes — is
/// unit-testable.
// Combines the multi-worker header (#134) with the auto-merge (#135) and
// quality-assurance (#162) indicators, which together push this one span past the
// arg-count lint.
#[allow(clippy::too_many_arguments)]
fn header_spans(
    count: usize,
    viewing: Option<u64>,
    workers: usize,
    working: &[u64],
    working_prs: &[u64],
    model_label: &str,
    auto_merge: bool,
    quality_assurance: bool,
    report_on_close: bool,
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
    if workers > 0 {
        spans.push(Span::styled(
            format!("  ·  {spinner} loop: running"),
            Style::new().fg(Color::Green).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            format!(
                "  ·  {workers} worker{}",
                if workers == 1 { "" } else { "s" }
            ),
            Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        ));
        let mut idle = true;
        if let Some(summary) = working_summary(working) {
            spans.push(Span::styled(
                format!("  ·  {summary}"),
                Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
            ));
            idle = false;
        }
        if let Some(summary) = pr_summary(working_prs) {
            spans.push(Span::styled(
                format!("  ·  {spinner} {summary}"),
                Style::new().fg(Color::Blue).add_modifier(Modifier::BOLD),
            ));
            idle = false;
        }
        if idle {
            spans.push(Span::styled(
                "  ·  waiting for work",
                Style::new().fg(Color::DarkGray),
            ));
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
    spans.push(Span::styled(
        format!("  ·  auto-merge: {}", if auto_merge { "on" } else { "off" }),
        Style::new().fg(if auto_merge {
            Color::Green
        } else {
            Color::DarkGray
        }),
    ));
    spans.push(Span::styled(
        format!("  ·  qa: {}", if quality_assurance { "on" } else { "off" }),
        Style::new().fg(if quality_assurance {
            Color::Green
        } else {
            Color::DarkGray
        }),
    ));
    spans.push(Span::styled(
        format!(
            "  ·  summary: {}",
            if report_on_close { "on" } else { "off" }
        ),
        Style::new().fg(if report_on_close {
            Color::Green
        } else {
            Color::DarkGray
        }),
    ));
    spans
}

fn render_header(frame: &mut Frame, area: ratatui::layout::Rect, app: &App, workers: usize) {
    let spans = header_spans(
        app.issues.len(),
        app.selected().map(|issue| issue.number),
        workers,
        &app.in_progress_numbers(),
        &app.in_progress_pr_numbers(),
        app.current_model_label(),
        app.auto_merge(),
        app.quality_assurance(),
        app.report_on_close(),
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

/// The footer's refreshing indicator: an animated spinner and "Refreshing…"
/// while a background refresh is in flight (#130), or `None` when idle. Pure so
/// the animated branch is unit-testable without a live fetch.
fn refreshing_indicator(refreshing: bool, spinner: &str) -> Option<Span<'static>> {
    refreshing.then(|| {
        Span::styled(
            format!("{spinner} Refreshing… "),
            Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD),
        )
    })
}

/// The footer's summarizing indicator: an animated spinner and "Summarizing…"
/// while a close summary is being written (#161), or `None` when idle. Pure so
/// the animated branch is unit-testable without the model call.
fn reporting_indicator(reporting: bool, spinner: &str) -> Option<Span<'static>> {
    reporting.then(|| {
        Span::styled(
            format!("{spinner} Summarizing… "),
            Style::new().fg(Color::Magenta).add_modifier(Modifier::BOLD),
        )
    })
}

fn render_footer(frame: &mut Frame, area: ratatui::layout::Rect, app: &App) {
    let mut spans = Vec::new();
    if let Some(indicator) = refreshing_indicator(app.is_refreshing(), spinner_frame()) {
        spans.push(indicator);
        spans.push(Span::raw("  "));
    }
    if let Some(indicator) = reporting_indicator(app.is_reporting(), spinner_frame()) {
        spans.push(indicator);
        spans.push(Span::raw("  "));
    }
    if let Some(status) = &app.status {
        spans.push(Span::styled(
            format!(" {status} "),
            Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw("  "));
    }
    let ready_key = if app.selected_is_ready() {
        "r unready"
    } else {
        "r ready"
    };
    if app.leader_active() {
        // The leader menu lists the issue actions unlocked by `space` (#129),
        // including auto-merge (#135) and quality-assurance (#162).
        spans.push(Span::styled(
            " ACTIONS ",
            Style::new()
                .fg(Color::Black)
                .bg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            format!("  c new · {ready_key} · x close · d details · l add-worker · L stop-all · b bots · a auto-merge · q qa · s summary · m models · o output · p pr-output · t closed · $ cost · f refresh · esc cancel"),
            Style::new().fg(Color::DarkGray),
        ));
    } else {
        // Actions stay hidden until `space` opens the menu; only navigation and
        // the leader hint show here (#129).
        spans.push(Span::styled(
            "j/k move · g/G top/bottom · space actions · q quit",
            Style::new().fg(Color::DarkGray),
        ));
    }
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

/// Draw the close-issue confirmation popup: a centered prompt naming the issue
/// to be closed, with a [`Clear`] underneath so the list does not show through
/// (#118). The red border signals the action is destructive.
fn render_close_confirm(frame: &mut Frame, area: Rect, app: &App, number: u64) {
    let title = app
        .issues
        .iter()
        .find(|issue| issue.number == number)
        .map(|issue| issue.title.clone())
        .unwrap_or_default();

    let popup = centered_popup(area, 50, 7);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(format!(" Close issue #{number}? "))
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" y confirm · n/Esc cancel ").centered())
        .border_style(Style::new().fg(Color::Red).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    // Tell the operator whether closing will post an auto-generated summary, and
    // how to flip it, so the side effect is never a surprise (#161).
    let summary_line = if app.report_on_close() {
        Span::styled(
            "A summary will be posted (space s to toggle).",
            Style::new().fg(Color::Green),
        )
    } else {
        Span::styled(
            "No summary will be posted (space s to toggle).",
            Style::new().fg(Color::DarkGray),
        )
    };

    let body = Paragraph::new(vec![
        Line::from(Span::styled(
            title,
            Style::new().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "This closes the issue on GitHub.",
            Style::new().fg(Color::DarkGray),
        )),
        Line::from(summary_line),
    ])
    .block(block)
    .wrap(Wrap { trim: false });

    frame.render_widget(Clear, popup);
    frame.render_widget(body, popup);
}

/// Draw the quit confirmation popup: a centered prompt asking whether to exit
/// the TUI, with a [`Clear`] underneath so the list does not show through
/// (#167). The red border matches the close prompt, marking it a guarded exit.
fn render_quit_confirm(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_popup(area, 50, 7);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Quit bot-loop? ")
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" y quit · n/Esc cancel ").centered())
        .border_style(Style::new().fg(Color::Red).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    // Reassure the operator that quitting the TUI leaves the detached background
    // loops running; only mention it when a loop is actually up (#167).
    let note = if app.workers_running() > 0 {
        "Background loops keep running."
    } else {
        "This closes the terminal UI."
    };

    let body = Paragraph::new(vec![
        Line::from(""),
        Line::from(Span::styled(
            "Exit the TUI?",
            Style::new().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(note, Style::new().fg(Color::DarkGray))),
    ])
    .block(block)
    .alignment(Alignment::Center)
    .wrap(Wrap { trim: false });

    frame.render_widget(Clear, popup);
    frame.render_widget(body, popup);
}

/// Draw the PR-output popup: a centered modal listing the pull requests the loop
/// is resolving, with the selected PR's live transcript beside it, so the user
/// can watch a PR being worked even though PRs are absent from the issue list.
/// Handles several PRs at once via the navigable list (#143). A [`Clear`]
/// underneath wipes the cells so the list behind it does not show through.
fn render_pr_output(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(80, 80, area);
    frame.render_widget(Clear, popup);

    let outer = Block::default()
        .borders(Borders::ALL)
        .title(" Resolving PRs ")
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" j/k move · Esc close ").centered())
        .border_style(Style::new().fg(Color::Blue).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    // With no PR in flight there is nothing to show, so say so plainly.
    if app.in_progress_prs().is_empty() {
        let body = Paragraph::new("No PRs are being resolved.")
            .block(outer)
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(body, popup);
        return;
    }

    let inner = outer.inner(popup);
    frame.render_widget(outer, popup);

    let [list_area, log_area] =
        Layout::horizontal([Constraint::Percentage(35), Constraint::Percentage(65)]).areas(inner);

    // Collect owned data first so the immutable borrows of `app` end before the
    // list needs a mutable borrow of its selection state.
    let items: Vec<ListItem> = app
        .in_progress_prs()
        .iter()
        .map(|pr| ListItem::new(Line::from(format!("#{} {}", pr.number, pr.title))))
        .collect();
    let selected_number = app
        .pr_output_state
        .selected()
        .and_then(|i| app.in_progress_prs().get(i))
        .map(|pr| pr.number);
    let selected_output = app.selected_pr_output(OUTPUT_TAIL_BYTES);

    render_pr_output_log(frame, log_area, selected_number, selected_output);

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(" PRs "))
        .highlight_style(
            Style::new()
                .fg(Color::Black)
                .bg(Color::Blue)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, list_area, &mut app.pr_output_state);
}

/// Draw the transcript pane of the PR-output popup, following the bottom like
/// `tail -f` so the newest output stays on screen, or a placeholder when the
/// selected PR has produced no log yet (#143).
fn render_pr_output_log(
    frame: &mut Frame,
    area: Rect,
    number: Option<u64>,
    output: Option<(u64, String)>,
) {
    let title = match number {
        Some(n) => format!(" Output · PR #{n} "),
        None => " Output ".to_string(),
    };
    let block = Block::default().borders(Borders::ALL).title(title);

    match output {
        Some((_number, text)) => {
            let inner_height = area.height.saturating_sub(2) as usize;
            let body: Vec<Line> = logs::last_lines(&text, inner_height)
                .into_iter()
                .map(|line| Line::raw(line.to_string()))
                .collect();
            frame.render_widget(Paragraph::new(body).block(block), area);
        }
        None => {
            let msg = match number {
                Some(n) => format!("No output yet for PR #{n}."),
                None => "No PR selected.".to_string(),
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

/// Format an AI Credits total for display: whole numbers without a decimal
/// point, otherwise one decimal place. Pure for testing (#145).
fn format_credits(value: f64) -> String {
    if value.fract().abs() < 0.05 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    }
}

/// Build a closed-issue row for the spend popup: the AI Credits spent (or a dash
/// when none was recorded) leading the issue number, title, and labels. The cost
/// leads and is coloured so "how much did this issue cost" is the first thing the
/// eye lands on (#145).
fn closed_issue_item(issue: &Issue) -> ListItem<'static> {
    let cost = match issue.credits_spent() {
        Some(credits) => Span::styled(
            format!("{:>9} ", format!("{} cr", format_credits(credits))),
            Style::new().fg(Color::Green).add_modifier(Modifier::BOLD),
        ),
        None => Span::styled(format!("{:>9} ", "—"), Style::new().fg(Color::DarkGray)),
    };
    let mut spans = vec![
        cost,
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
    ListItem::new(Line::from(spans))
}

/// Draw the closed-issues (spend) popup: a centered, scrollable list of closed
/// issues, each showing the AI Credits the loop spent on it, with the grand
/// total in the border title so the overall cost is visible at a glance. A
/// [`Clear`] underneath wipes the cells so the list behind it does not show
/// through (#145).
fn render_closed(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(80, 80, area);
    frame.render_widget(Clear, popup);

    let total = match app.closed_total_credits() {
        Some(credits) => format!("spent {} credits", format_credits(credits)),
        None => "no recorded spend".to_string(),
    };
    let title = format!(
        " Closed Issues · {} closed · {total} ",
        app.closed_issues().len()
    );

    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" j/k move · Esc close ").centered())
        .border_style(Style::new().fg(Color::Magenta).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    if app.closed_issues().is_empty() {
        let body = Paragraph::new("No closed issues.")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(body, popup);
        return;
    }

    let items: Vec<ListItem> = app.closed_issues().iter().map(closed_issue_item).collect();
    let list = List::new(items)
        .block(block)
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, popup, &mut app.closed_state);
}

/// Bar width and gap to fit `days` bars across `width` cells: a 1-cell gap when
/// there is room, otherwise none, with the bar widened to fill. Clamped so a bar
/// is always at least one cell wide. Pure for testing (#163).
fn bar_dims(width: u16, days: u32) -> (u16, u16) {
    let days = days.max(1);
    let w = u32::from(width);
    let gap = if w >= days * 2 + (days - 1) { 1 } else { 0 };
    let bar = w.saturating_sub(gap * (days - 1)) / days;
    (bar.clamp(1, 5) as u16, gap as u16)
}

/// Build one bar per day from `values`, labelling only day 1 and every fifth day
/// so the axis stays legible across a full month, and blanking each bar's value
/// text (the KPI header and titles carry the numbers) so the graph reads as a
/// shape rather than a wall of figures (#163).
fn day_bars(values: &[u64]) -> Vec<Bar<'static>> {
    values
        .iter()
        .enumerate()
        .map(|(i, &value)| {
            let day = i as u32 + 1;
            let label = if day == 1 || day.is_multiple_of(5) {
                day.to_string()
            } else {
                String::new()
            };
            Bar::default()
                .value(value)
                .label(Line::from(label))
                .text_value(String::new())
        })
        .collect()
}

/// The dashboard's KPI header: total spent this month, how many issues were
/// worked, the average per issue, and the costliest day — the three figures the
/// issue asks for, plus the peak for context (#163).
fn cost_kpis(mc: &MonthlyCost) -> Paragraph<'static> {
    let dim = Style::new().fg(Color::DarkGray);
    let green = Style::new().fg(Color::Green).add_modifier(Modifier::BOLD);
    let yellow = Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD);

    let avg = mc
        .average_per_issue()
        .map(format_credits)
        .unwrap_or_else(|| "—".to_string());

    let line1 = Line::from(vec![
        Span::styled("This month: ", dim),
        Span::styled(format!("{} cr", format_credits(mc.total)), green),
        Span::raw("    "),
        Span::styled("Issues worked: ", dim),
        Span::styled(mc.issue_count.to_string(), yellow),
        Span::raw("    "),
        Span::styled("Avg / issue: ", dim),
        Span::styled(format!("{avg} cr"), green),
    ]);

    let peak = match mc.peak_day() {
        Some((day, cost)) => format!(
            "{} {day} ({} cr)",
            mc.month.short_name(),
            format_credits(cost)
        ),
        None => "—".to_string(),
    };
    let line2 = Line::from(vec![
        Span::styled("Peak day: ", dim),
        Span::styled(peak, Style::new().fg(Color::Cyan)),
    ]);

    Paragraph::new(vec![line1, line2])
}

/// Draw the cost dashboard (#163): a KPI header (this month's total, issues
/// worked, average per issue) above two by-day bar charts — spend per day and
/// issues worked per day — over the current month, so "how much are we spending
/// over time" is answered at a glance. A [`Clear`] underneath wipes the list
/// behind it.
fn render_cost(frame: &mut Frame, area: Rect, app: &App) {
    let popup = centered_rect(90, 85, area);
    frame.render_widget(Clear, popup);

    let mc = app.monthly_cost();
    let title = format!(
        " Cost dashboard · {} {} ",
        mc.month.short_name(),
        mc.month.year
    );
    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" Esc close ").centered())
        .border_style(Style::new().fg(Color::Green).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));
    let inner = block.inner(popup);
    frame.render_widget(block, popup);

    let [kpi_area, charts_area] =
        Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).areas(inner);
    frame.render_widget(cost_kpis(&mc), kpi_area);

    if !mc.has_spend() {
        let empty = Paragraph::new("No spend recorded this month.")
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(empty, charts_area);
        return;
    }

    let [cost_area, issues_area] =
        Layout::vertical([Constraint::Percentage(50), Constraint::Percentage(50)])
            .areas(charts_area);

    let cost_values: Vec<u64> = mc.cost_per_day.iter().map(|c| c.round() as u64).collect();
    let (bar_width, bar_gap) = bar_dims(cost_area.width, mc.days);
    let cost_chart = BarChart::new(day_bars(&cost_values))
        .block(
            Block::default()
                .borders(Borders::TOP)
                .title("Cost / day (cr)"),
        )
        .bar_width(bar_width)
        .bar_gap(bar_gap)
        .bar_style(Style::new().fg(Color::Green))
        .label_style(Style::new().fg(Color::DarkGray));
    frame.render_widget(cost_chart, cost_area);

    let issue_values: Vec<u64> = mc.issues_per_day.iter().map(|&n| u64::from(n)).collect();
    let max_issues = issue_values.iter().copied().max().unwrap_or(0);
    let (bar_width, bar_gap) = bar_dims(issues_area.width, mc.days);
    let issue_chart = BarChart::new(day_bars(&issue_values))
        .block(
            Block::default()
                .borders(Borders::TOP)
                .title(format!("Issues / day · max {max_issues}")),
        )
        .bar_width(bar_width)
        .bar_gap(bar_gap)
        .bar_style(Style::new().fg(Color::Cyan))
        .label_style(Style::new().fg(Color::DarkGray));
    frame.render_widget(issue_chart, issues_area);
}

/// Build the details popup's content as logical (pre-wrap) lines, each paired
/// with the style it renders in: the issue title, a meta line (number, author,
/// labels), the body, then the comment thread. Pure so the content is
/// unit-testable without a terminal (#152).
fn detail_content(issue: &Issue) -> Vec<(String, Style)> {
    let bold = Style::new().add_modifier(Modifier::BOLD);
    let dim = Style::new().fg(Color::DarkGray);
    let mut lines: Vec<(String, Style)> = Vec::new();

    lines.push((issue.title.clone(), bold.fg(Color::White)));

    let mut meta = format!("#{}", issue.number);
    let author = issue.author_login();
    if !author.is_empty() {
        meta.push_str(&format!(" · @{author}"));
    }
    let labels = issue.label_names();
    if !labels.is_empty() {
        meta.push_str(&format!(" · [{}]", labels.join(", ")));
    }
    lines.push((meta, dim));
    lines.push((String::new(), dim));

    if issue.body.trim().is_empty() {
        lines.push(("(no description)".to_string(), dim));
    } else {
        for line in issue.body.lines() {
            lines.push((line.to_string(), Style::new()));
        }
    }

    lines.push((String::new(), dim));
    lines.push((
        format!("Comments ({})", issue.comments.len()),
        bold.fg(Color::Cyan),
    ));

    if issue.comments.is_empty() {
        lines.push(("(no comments)".to_string(), dim));
    } else {
        for comment in &issue.comments {
            lines.push((String::new(), dim));
            lines.push((comment_heading(comment), bold.fg(Color::Green)));
            for line in comment.body.lines() {
                lines.push((line.to_string(), Style::new()));
            }
        }
    }

    lines
}

/// A comment's heading line for the details popup: `@author` plus the date it
/// was posted when known. Falls back to `unknown` when no author is recorded and
/// omits the date when `gh` did not return one. Pure for testing (#152).
fn comment_heading(comment: &crate::github::Comment) -> String {
    let who = match comment.author_login() {
        "" => "unknown",
        login => login,
    };
    match comment_date(&comment.created_at) {
        Some(date) => format!("@{who} · {date}"),
        None => format!("@{who}"),
    }
}

/// The calendar-day portion (`YYYY-MM-DD`) of a comment's ISO-8601 `createdAt`
/// timestamp, or `None` when it is empty or not a `YYYY-MM-DD`-shaped date. Pure
/// for testing.
fn comment_date(created_at: &str) -> Option<String> {
    let day = created_at.split('T').next().unwrap_or("");
    let is_iso_day = day.len() == 10
        && day.chars().enumerate().all(|(i, c)| match i {
            4 | 7 => c == '-',
            _ => c.is_ascii_digit(),
        });
    is_iso_day.then(|| day.to_string())
}

/// Word-wrap a single logical line to `width` columns, never panicking and
/// always yielding at least one (possibly empty) line so blank lines survive.
/// Over-long words are hard-split so they cannot overflow the popup. Pure for
/// testing (#152).
fn wrap_text(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    if text.is_empty() {
        return vec![String::new()];
    }

    let mut lines: Vec<String> = Vec::new();
    let mut current = String::new();
    for word in text.split(' ') {
        if word.chars().count() > width {
            if !current.is_empty() {
                lines.push(std::mem::take(&mut current));
            }
            let mut chunk = String::new();
            for ch in word.chars() {
                if chunk.chars().count() == width {
                    lines.push(std::mem::take(&mut chunk));
                }
                chunk.push(ch);
            }
            current = chunk;
            continue;
        }

        let sep = usize::from(!current.is_empty());
        if current.chars().count() + sep + word.chars().count() > width {
            lines.push(std::mem::take(&mut current));
        } else if sep == 1 {
            current.push(' ');
        }
        current.push_str(word);
    }
    lines.push(current);
    lines
}

/// Wrap the styled logical lines to `width` columns, producing the ratatui lines
/// the details popup renders. Each wrapped fragment keeps its logical line's
/// style. Pure for testing (#152).
fn wrap_styled(content: &[(String, Style)], width: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    for (text, style) in content {
        for fragment in wrap_text(text, width) {
            out.push(Line::from(Span::styled(fragment, *style)));
        }
    }
    out
}

/// Draw the issue-details popup: a centered, scrollable modal showing the
/// selected issue's title, metadata, body, and full comment thread, so the whole
/// issue — comments included — is readable without leaving the TUI. Content is
/// word-wrapped to the popup width and vertically scrollable, and the scroll is
/// clamped to the last page so it can never run past the end. A [`Clear`]
/// underneath wipes the cells so the list behind it does not show through (#152).
fn render_details(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(80, 80, area);
    frame.render_widget(Clear, popup);

    let (number, content) = match app.details() {
        Some(issue) => (issue.number, detail_content(issue)),
        None => (
            0,
            vec![(
                "No issue selected.".to_string(),
                Style::new().fg(Color::DarkGray),
            )],
        ),
    };

    let block = Block::default()
        .borders(Borders::ALL)
        .title(format!(" Issue #{number} "))
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" j/k scroll · g/G top/bottom · Esc close ").centered())
        .border_style(Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    let inner = block.inner(popup);
    let lines = wrap_styled(&content, inner.width as usize);

    // Clamp so the furthest scroll lands the last line at the bottom of the pane.
    let max_scroll = (lines.len() as u16).saturating_sub(inner.height);
    app.clamp_details_scroll(max_scroll);

    let body = Paragraph::new(lines)
        .block(block)
        .scroll((app.details_scroll(), 0));
    frame.render_widget(body, popup);
}

/// Draw the bots popup: a centered, navigable list of every background worker
/// the session has started — running, stopped, or failed — so a stopped or
/// failed one can be restarted in place with the same options it was launched
/// with (#82). A [`Clear`] underneath wipes the cells so the list behind it does
/// not show through.
fn render_bots(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(70, 70, area);
    frame.render_widget(Clear, popup);

    let views: Vec<WorkerView> = app.bots().to_vec();
    let running = views
        .iter()
        .filter(|v| v.status == WorkerStatus::Running)
        .count();
    let restartable = views.iter().filter(|v| v.status.is_restartable()).count();
    let title = format!(
        " Bots · {} total · {running} running · {restartable} restartable ",
        views.len()
    );

    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" j/k move · r restart · R restart all · Esc close ").centered())
        .border_style(Style::new().fg(Color::Green).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    if views.is_empty() {
        let body = Paragraph::new("No bots started yet. Press l to start one.")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(body, popup);
        return;
    }

    let items: Vec<ListItem> = views.iter().map(bot_item).collect();
    let list = List::new(items)
        .block(block)
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, popup, &mut app.bots_state);
}

/// Build a bots-popup row: the worker's slot, its colour-coded status, its most
/// recent pid while running (a dash once stopped), and the model it runs on so
/// "what was this launched with" is visible before a restart (#82).
fn bot_item(view: &WorkerView) -> ListItem<'static> {
    let (label, color) = match view.status {
        WorkerStatus::Running => ("running", Color::Green),
        WorkerStatus::Stopped => ("stopped", Color::Yellow),
        WorkerStatus::Failed => ("failed", Color::Red),
    };
    let pid = if view.status == WorkerStatus::Running {
        view.pid.to_string()
    } else {
        "—".to_string()
    };
    let model = view.model.clone().unwrap_or_else(|| "auto".to_string());
    ListItem::new(Line::from(vec![
        Span::styled(format!("#{:<4}", view.id), Style::new().fg(Color::Cyan)),
        Span::styled(
            format!("{label:<9}"),
            Style::new().fg(color).add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!("pid {pid:<8}"), Style::new().fg(Color::DarkGray)),
        Span::raw(format!("model {model}")),
    ]))
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
        // Actions (add-worker included) now hide behind the leader key (#129).
        assert!(text.contains("space actions"));
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
        assert!(text.contains("space actions"));
    }

    #[test]
    fn base_footer_hides_actions_behind_the_leader_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(160, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        // Only the leader hint shows; the issue actions stay hidden (#129).
        assert!(text.contains("space actions"));
        assert!(!text.contains("c new"));
        assert!(!text.contains("m models"));
        assert!(!text.contains("ACTIONS"));
    }

    #[test]
    fn leader_footer_lists_the_issue_actions() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(200, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        // The menu shows the actions the issue asked for, plus the rest (#129).
        assert!(text.contains("ACTIONS"));
        assert!(text.contains("c new"));
        assert!(text.contains("r ready"));
        assert!(text.contains("m models"));
        assert!(text.contains("add-worker"));
        assert!(text.contains("s summary"));
        assert!(text.contains("f refresh"));
        assert!(text.contains("esc cancel"));
        // The action menu replaces the base navigation hint.
        assert!(!text.contains("space actions"));
    }

    #[test]
    fn footer_advertises_the_output_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(160, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("o output"));
    }

    #[test]
    fn footer_advertises_the_bots_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(200, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("b bots"));
    }

    #[test]
    fn footer_shows_the_refreshing_indicator_while_refreshing() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.set_refreshing(true);
        app.enter_leader();
        // Wide enough that the whole footer — indicator plus key hints — renders.
        let mut terminal = Terminal::new(TestBackend::new(220, 6)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Refreshing"));
        // The key hints still share the footer.
        assert!(text.contains("f refresh"));
    }

    #[test]
    fn footer_hides_the_refreshing_indicator_when_idle() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(220, 6)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(!buffer_text(&terminal).contains("Refreshing"));
    }

    #[test]
    fn refreshing_indicator_shows_only_while_refreshing() {
        assert!(refreshing_indicator(false, "⠋").is_none());
        let span = refreshing_indicator(true, "⠋").expect("indicator while refreshing");
        assert!(span.content.contains("Refreshing"));
        assert!(span.content.contains("⠋"));
    }

    #[test]
    fn reporting_indicator_shows_only_while_reporting() {
        assert!(reporting_indicator(false, "⠋").is_none());
        let span = reporting_indicator(true, "⠋").expect("indicator while reporting");
        assert!(span.content.contains("Summarizing"));
        assert!(span.content.contains("⠋"));
    }

    #[test]
    fn footer_shows_the_summarizing_indicator_while_reporting() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.set_reporting(true);
        let mut terminal = Terminal::new(TestBackend::new(120, 6)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("Summarizing"));
    }

    #[test]
    fn footer_advertises_the_close_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(140, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("x close"));
    }

    #[test]
    fn footer_advertises_the_auto_merge_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(160, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("a auto-merge"));
    }

    #[test]
    fn footer_advertises_the_quality_assurance_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(200, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("q qa"));
    }

    #[test]
    fn footer_ready_key_flips_to_unready_when_selected_is_labelled() {
        // An unlabelled selection offers to mark it ready…
        let plain =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(plain);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(140, 10)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();
        let text = buffer_text(&terminal);
        assert!(text.contains("r ready"));
        assert!(!text.contains("r unready"));

        // …while an already-ready selection offers to remove the label (#146).
        let ready = parse_issues(
            r#"[{"number":96,"title":"t","labels":[{"name":"ready"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(ready);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(140, 10)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();
        assert!(buffer_text(&terminal).contains("r unready"));
    }

    #[test]
    fn renders_the_close_confirmation_popup_when_open() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        app.request_close();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Close issue #96?"));
        assert!(text.contains("y confirm"));
        assert!(text.contains("cancel"));
        // The popup states the summary side effect, on by default (#161).
        assert!(text.contains("summary will be posted"));
    }

    #[test]
    fn close_confirmation_reflects_a_disabled_summary() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"create a TUI","labels":[],"author":null}]"#)
                .unwrap();
        let mut app = App::new(issues);
        app.toggle_report_on_close(); // turn the summary off
        app.request_close();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No summary will be posted"));
    }

    #[test]
    fn renders_the_quit_confirmation_popup_when_open() {
        let mut app = App::new(Vec::new());
        app.request_quit();
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Quit bot-loop?"));
        assert!(text.contains("y quit"));
        assert!(text.contains("cancel"));
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
    fn pr_summary_lists_numbers_or_none() {
        assert_eq!(pr_summary(&[]), None);
        assert_eq!(pr_summary(&[12]).as_deref(), Some("resolving PR #12"));
        assert_eq!(
            pr_summary(&[12, 13]).as_deref(),
            Some("resolving PRs #12, #13")
        );
    }

    #[test]
    fn header_shows_spinner_and_working_issue_when_loop_runs() {
        let text = spans_text(&header_spans(
            3,
            Some(96),
            1,
            &[96],
            &[],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("⠋ loop: running"));
        assert!(text.contains("1 worker"));
        assert!(text.contains("working #96"));
        assert!(text.contains("model: auto"));
        assert!(text.contains("auto-merge: off"));
    }

    #[test]
    fn header_shows_the_worker_count_for_several_workers() {
        let text = spans_text(&header_spans(
            5,
            Some(96),
            3,
            &[96, 97, 98],
            &[],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("loop: running"));
        assert!(text.contains("3 workers"));
        assert!(text.contains("working #96, #97, #98"));
    }

    #[test]
    fn header_shows_pr_work_when_the_loop_resolves_a_pr() {
        // A PR being resolved is not in the issue list, so the header is the
        // only place the user learns the loop is busy (#133).
        let text = spans_text(&header_spans(
            3,
            None,
            1,
            &[],
            &[12],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("loop: running"));
        assert!(text.contains("resolving PR #12"));
        // With PR work in flight the loop is not idle.
        assert!(!text.contains("waiting for work"));
    }

    #[test]
    fn header_shows_both_issue_and_pr_work() {
        let text = spans_text(&header_spans(
            3,
            None,
            1,
            &[96],
            &[12],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("working #96"));
        assert!(text.contains("resolving PR #12"));
    }

    #[test]
    fn header_says_waiting_when_loop_runs_without_an_issue() {
        let text = spans_text(&header_spans(
            3,
            None,
            1,
            &[],
            &[],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("loop: running"));
        assert!(text.contains("waiting for work"));
    }

    #[test]
    fn header_hides_loop_details_when_off() {
        let text = spans_text(&header_spans(
            3,
            Some(96),
            0,
            &[96],
            &[12],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("loop: off"));
        assert!(!text.contains("working"));
        assert!(!text.contains("worker"));
        assert!(!text.contains("resolving PR"));
        assert!(!text.contains("⠋"));
    }

    #[test]
    fn header_reflects_auto_merge_state() {
        let on = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            true,
            true,
            true,
            "⠋",
        ));
        assert!(on.contains("auto-merge: on"));
        let off = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(off.contains("auto-merge: off"));
    }

    #[test]
    fn header_reflects_quality_assurance_state() {
        let on = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            false,
            true,
            false,
            "⠋",
        ));
        assert!(on.contains("qa: on"));
        let off = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            false,
            false,
            false,
            "⠋",
        ));
        assert!(off.contains("qa: off"));
    }

    #[test]
    fn header_reflects_summary_state() {
        let on = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            false,
            false,
            true,
            "⠋",
        ));
        assert!(on.contains("summary: on"));
        let off = spans_text(&header_spans(
            1,
            None,
            0,
            &[],
            &[],
            "auto",
            false,
            false,
            false,
            "⠋",
        ));
        assert!(off.contains("summary: off"));
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
    fn footer_advertises_the_pr_output_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(160, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("p pr-output"));
    }

    #[test]
    fn renders_the_pr_output_popup_with_the_selected_log() {
        let dir = std::env::temp_dir().join(format!("copilot-ui-proutput-{}", std::process::id()));
        let logs = dir.join(".copilot-loop").join("logs");
        std::fs::create_dir_all(&logs).unwrap();
        std::fs::write(
            logs.join("pr-12-20260101-000000.log"),
            "\x1b[32mresolving the conflict\x1b[0m\n",
        )
        .unwrap();

        let mut app = App::new(Vec::new());
        app.set_repo_root(dir.clone());
        app.set_in_progress_prs(
            crate::github::parse_pull_requests(
                r#"[{"number":12,"title":"resolve conflicts"},{"number":15,"title":"fix checks"}]"#,
            )
            .unwrap(),
        );
        app.open_pr_output();

        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Resolving PRs"));
        // Both in-flight PRs are listed so multiple resolutions are visible.
        assert!(text.contains("#12"));
        assert!(text.contains("#15"));
        // The selected PR's transcript shows, with ANSI colour codes stripped.
        assert!(text.contains("resolving the conflict"));
        assert!(!text.contains("[32m"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pr_output_popup_reports_when_no_prs_are_resolving() {
        let mut app = App::new(Vec::new());
        app.open_pr_output();

        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No PRs are being resolved."));
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

    #[test]
    fn format_credits_drops_trailing_zeros() {
        assert_eq!(format_credits(335.0), "335");
        assert_eq!(format_credits(25.7), "25.7");
        assert_eq!(format_credits(150.5), "150.5");
    }

    #[test]
    fn footer_advertises_the_closed_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(170, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("t closed"));
    }

    #[test]
    fn renders_the_closed_popup_with_spend_per_issue_and_total() {
        let json = format!(
            "[{},{}]",
            r#"{"number":143,"title":"resolve PR view","comments":[{"body":"```\nAI Credits 335 (9m)\n```\n<!-- copilot-loop:usage -->"}]}"#,
            r#"{"number":128,"title":"animate the line","comments":[]}"#,
        );
        let mut app = App::new(Vec::new());
        app.open_closed_with(parse_issues(&json).unwrap());

        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Closed Issues"));
        // Both closed issues are listed.
        assert!(text.contains("#143"));
        assert!(text.contains("#128"));
        // The spend leads each row: a figure where recorded, a dash where not.
        assert!(text.contains("335 cr"));
        assert!(text.contains("—"));
        // The grand total is surfaced in the border title.
        assert!(text.contains("spent 335 credits"));
    }

    #[test]
    fn closed_popup_reports_when_there_are_no_closed_issues() {
        let mut app = App::new(Vec::new());
        app.open_closed_with(Vec::new());

        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No closed issues."));
    }

    #[test]
    fn bar_dims_fit_within_the_available_width() {
        // Wide enough for a gap between two-cell bars.
        let (bar, gap) = bar_dims(120, 31);
        assert!(bar >= 1 && gap <= 1);
        assert!(u32::from(bar) * 31 + u32::from(gap) * 30 <= 120);
        // Too narrow for gaps: bars still at least one cell, no gap.
        let (bar, gap) = bar_dims(20, 31);
        assert_eq!((bar, gap), (1, 0));
        // Zero days never divides by zero; a bar is always at least one cell.
        assert!(bar_dims(10, 0).0 >= 1);
    }

    #[test]
    fn cost_dashboard_shows_kpis_and_both_charts() {
        // Date the usage in the current month so it lands in the dashboard's view.
        let m = crate::cost::current_month();
        let date = format!("{:04}-{:02}-02T10:00:00Z", m.year, m.month);
        let body = "```\nAI Credits 120 (1s)\n```\n<!-- copilot-loop:usage -->";
        let json = format!(
            r#"[{{"number":1,"title":"t","comments":[{{"body":{},"createdAt":"{date}"}}]}}]"#,
            serde_json::to_string(body).unwrap()
        );
        let mut app = App::new(Vec::new());
        app.open_cost_with(parse_issues(&json).unwrap());

        let mut terminal = Terminal::new(TestBackend::new(120, 40)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Cost dashboard"));
        assert!(text.contains("This month"));
        assert!(text.contains("Issues worked"));
        assert!(text.contains("Avg / issue"));
        assert!(text.contains("Cost / day"));
        assert!(text.contains("Issues / day"));
        // The peak day surfaces the day's spend.
        assert!(text.contains("Peak day"));
    }

    #[test]
    fn cost_dashboard_reports_an_empty_month() {
        let mut app = App::new(Vec::new());
        app.open_cost_with(Vec::new());

        let mut terminal = Terminal::new(TestBackend::new(120, 30)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Cost dashboard"));
        assert!(text.contains("No spend recorded this month."));
    }

    #[test]
    fn footer_advertises_the_cost_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(200, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("$ cost"));
    }

    #[test]
    fn footer_advertises_the_details_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("d details"));
    }

    #[test]
    fn detail_content_includes_the_body_and_comments() {
        let issue = crate::github::parse_issue(
            r#"{"number":152,"title":"see details","body":"line one\nline two",
                "labels":[{"name":"ready"}],"author":{"login":"octocat"},
                "comments":[{"author":{"login":"hubot"},"body":"a reply",
                             "createdAt":"2026-07-18T06:45:11Z"}]}"#,
        )
        .unwrap();
        let text: Vec<String> = detail_content(&issue)
            .into_iter()
            .map(|(line, _)| line)
            .collect();

        assert!(text.contains(&"see details".to_string()));
        assert!(
            text.iter()
                .any(|l| l.contains("#152") && l.contains("@octocat"))
        );
        assert!(text.contains(&"line one".to_string()));
        assert!(text.contains(&"line two".to_string()));
        assert!(text.contains(&"Comments (1)".to_string()));
        assert!(text.contains(&"@hubot · 2026-07-18".to_string()));
        assert!(text.contains(&"a reply".to_string()));
    }

    #[test]
    fn detail_content_notes_an_empty_body_and_no_comments() {
        let issue = crate::github::parse_issue(r#"{"number":1,"title":"bare"}"#).unwrap();
        let text: Vec<String> = detail_content(&issue)
            .into_iter()
            .map(|(line, _)| line)
            .collect();

        assert!(text.contains(&"(no description)".to_string()));
        assert!(text.contains(&"Comments (0)".to_string()));
        assert!(text.contains(&"(no comments)".to_string()));
    }

    #[test]
    fn comment_date_takes_the_calendar_day_only() {
        assert_eq!(
            comment_date("2026-07-18T06:45:11Z").as_deref(),
            Some("2026-07-18")
        );
        assert_eq!(comment_date(""), None);
        assert_eq!(comment_date("not-a-date"), None);
    }

    #[test]
    fn wrap_text_wraps_on_word_boundaries_and_keeps_blank_lines() {
        assert_eq!(wrap_text("hello world foo", 11), vec!["hello world", "foo"]);
        // A blank logical line survives as one empty rendered line.
        assert_eq!(wrap_text("", 10), vec![String::new()]);
        // An over-long word is hard-split so it cannot overflow the popup.
        assert_eq!(wrap_text("abcdefgh", 3), vec!["abc", "def", "gh"]);
    }

    #[test]
    fn renders_the_details_popup_with_body_and_comments() {
        let issue = crate::github::parse_issue(
            r#"{"number":152,"title":"see details","body":"the description",
                "author":{"login":"octocat"},
                "comments":[{"author":{"login":"hubot"},"body":"a reply",
                             "createdAt":"2026-07-18T06:45:11Z"}]}"#,
        )
        .unwrap();
        let mut app = App::new(Vec::new());
        app.open_details_with(issue);

        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Issue #152"));
        assert!(text.contains("see details"));
        assert!(text.contains("the description"));
        assert!(text.contains("Comments (1)"));
        assert!(text.contains("hubot"));
        assert!(text.contains("a reply"));
    }

    #[test]
    fn bots_popup_reports_when_no_bots_have_started() {
        let mut app = App::new(Vec::new());
        app.open_bots_with(Vec::new());

        let mut terminal = Terminal::new(TestBackend::new(80, 16)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Bots"));
        assert!(text.contains("No bots started yet."));
    }

    #[test]
    fn renders_the_bots_popup_with_each_worker_status() {
        let mut app = App::new(Vec::new());
        app.open_bots_with(vec![
            WorkerView {
                id: 1,
                pid: 4242,
                status: WorkerStatus::Running,
                model: Some("gpt-5.4".to_string()),
                log: std::path::PathBuf::from("/tmp/loop-1.log"),
            },
            WorkerView {
                id: 2,
                pid: 4243,
                status: WorkerStatus::Failed,
                model: None,
                log: std::path::PathBuf::from("/tmp/loop-2.log"),
            },
        ]);

        let mut terminal = Terminal::new(TestBackend::new(90, 16)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        // The popup lists every worker with its slot, status, and model.
        assert!(text.contains("Bots"));
        assert!(text.contains("2 total"));
        assert!(text.contains("1 running"));
        assert!(text.contains("1 restartable"));
        assert!(text.contains("#1"));
        assert!(text.contains("running"));
        assert!(text.contains("gpt-5.4"));
        assert!(text.contains("#2"));
        assert!(text.contains("failed"));
        assert!(text.contains("pid 4242"));
        // A stopped/failed worker shows no live pid and defaults to the auto model.
        assert!(text.contains("model auto"));
    }
}
