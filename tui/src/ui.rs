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

/// Draw the whole UI: header, issue list (or placeholder), the feedback message
/// line, and the keybinds footer.
pub fn render(frame: &mut Frame, app: &mut App) {
    let workers = app.workers_running();
    let [header_area, body_area, message_area, footer_area] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    render_header(frame, header_area, app, workers);
    render_body(frame, body_area, app);
    render_message(frame, message_area, app);
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
    // The mark-ready confirmation floats on top of the list (#173).
    if let Some(number) = app.ready_confirm() {
        render_ready_confirm(frame, frame.area(), app, number);
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
    // The reply popup floats on top of everything else when open (#165).
    if app.reply_open() {
        render_reply(frame, frame.area(), app);
    }
    // The label editor popup floats on top of everything else when open (#204).
    if app.label_editor_open() {
        render_label_editor(frame, frame.area(), app);
    }
    // The messages popup floats on top of everything else when open (#182).
    if app.messages_open() {
        render_messages(frame, frame.area(), app);
    }
    // The leader-key action menu floats above the list as a which-key popup so
    // the bindings are discoverable after tapping `space` (#160).
    if app.leader_active() {
        render_leader_popup(frame, frame.area(), app);
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
/// and the model. Whenever work is in flight — local workers the TUI started, or
/// issues/PRs an external loop is working (carrying the in-progress label) — a
/// turning spinner, "loop: running", and the work being done (the issues *and*
/// any PRs), or "waiting for work" when a local worker is idle, are shown so it
/// is clear something is happening and on what. The worker count is shown only
/// when the TUI started workers itself; when it is merely watching an external
/// loop the count is omitted. "loop: off" shows only when nothing is running
/// (#115, #133, #134, #157). Pure so the running branch — which otherwise needs
/// live child processes — is unit-testable.
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
    let has_work = !working.is_empty() || !working_prs.is_empty();
    if workers > 0 || has_work {
        spans.push(Span::styled(
            format!("  ·  {spinner} loop: running"),
            Style::new().fg(Color::Green).add_modifier(Modifier::BOLD),
        ));
        if workers > 0 {
            spans.push(Span::styled(
                format!(
                    "  ·  {workers} worker{}",
                    if workers == 1 { "" } else { "s" }
                ),
                Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD),
            ));
        }
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
        // Only a local worker can sit idle waiting; when merely watching an
        // external loop, the in-progress labels are the only signal, so an empty
        // set means there is simply nothing to show, not an idle worker.
        if idle && workers > 0 {
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
fn render_body(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App) {
    if app.output_visible() && app.selected().is_some() {
        let [list_area, panel_area] =
            Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
                .areas(area);
        render_list(frame, list_area, app);
        render_output_panel(frame, panel_area, app);
    } else {
        render_list(frame, area, app);
    }
}

fn render_list(frame: &mut Frame, area: ratatui::layout::Rect, app: &mut App) {
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
        .map(|issue| issue_item(issue, spinner, app.issue_worker_pid(issue.number)))
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

/// The feedback message line, drawn just above the keybinds so status messages
/// never crowd the bindings (#182). Shows the in-flight refreshing/summarizing
/// indicators and the latest status message; blank when there is nothing to say.
fn render_message(frame: &mut Frame, area: Rect, app: &App) {
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
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// The keybinds footer: the leader badge while the action menu is open (#160),
/// otherwise the base navigation hint. Feedback messages live on their own line
/// above this one so they never share the keybinds line (#182).
fn render_footer(frame: &mut Frame, area: Rect, app: &App) {
    let mut spans = Vec::new();
    if app.leader_active() {
        // The full binding list now lives in the leader popup (#160); the footer
        // just flags the menu is open and how to leave it.
        spans.push(Span::styled(
            " ACTIONS ",
            Style::new()
                .fg(Color::Black)
                .bg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            "  pick an action · esc cancel",
            Style::new().fg(Color::DarkGray),
        ));
    } else {
        // Actions stay hidden until `space` opens the menu; only navigation, the
        // global refresh, and the leader hint show here (#129, #174).
        spans.push(Span::styled(
            "j/k move · g/G top/bottom · f refresh · space actions · q quit",
            Style::new().fg(Color::DarkGray),
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// The issue actions unlocked by the `space` leader key, as `(key, label)`
/// pairs. Kept in one place so the leader popup renders every binding and the
/// ready entry flips to *unready* when the selection already carries the label
/// (#160, #146).
fn leader_actions(app: &App) -> Vec<(&'static str, &'static str)> {
    let ready = if app.selected_is_ready() {
        "unready"
    } else {
        "ready"
    };
    vec![
        ("c", "new"),
        ("r", ready),
        ("x", "close"),
        ("d", "details"),
        ("i", "reply"),
        ("e", "labels"),
        ("l", "add-worker"),
        ("L", "stop-all"),
        ("b", "bots"),
        ("M", "messages"),
        ("a", "auto-merge"),
        ("q", "qa"),
        ("s", "summary"),
        ("m", "models"),
        ("o", "output"),
        ("p", "pr-output"),
        ("t", "closed"),
        ("$", "cost"),
        ("Esc", "cancel"),
    ]
}

/// Draw the leader-key action menu as a centered which-key popup: one binding
/// per row with the key highlighted, so the actions unlocked by `space` are
/// discoverable rather than memorised (#160). A [`Clear`] underneath wipes the
/// list so it does not show through.
fn render_leader_popup(frame: &mut Frame, area: Rect, app: &App) {
    let actions = leader_actions(app);
    let rows: Vec<Line> = actions
        .iter()
        .map(|(key, label)| {
            Line::from(vec![
                Span::styled(
                    format!(" {key:>3} "),
                    Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
                ),
                Span::raw(*label),
            ])
        })
        .collect();

    // Size the popup to its contents: the key column, the widest label, borders
    // and a little breathing room.
    let label_w = actions
        .iter()
        .map(|(_, label)| label.chars().count())
        .max()
        .unwrap_or(0) as u16;
    let width = label_w + 9;
    let height = actions.len() as u16 + 2;
    let popup = centered_popup_fixed(area, width, height);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Actions ")
        .title_alignment(Alignment::Center)
        .border_style(Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    frame.render_widget(Clear, popup);
    frame.render_widget(Paragraph::new(rows).block(block), popup);
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

/// Draw the mark-ready confirmation popup: a centered prompt naming the
/// in-progress issue about to be re-queued with the trigger label, with a
/// [`Clear`] underneath so the list does not show through (#173). A yellow
/// border marks it a caution rather than a destructive action.
fn render_ready_confirm(frame: &mut Frame, area: Rect, app: &App, number: u64) {
    let title = app
        .issues
        .iter()
        .find(|issue| issue.number == number)
        .map(|issue| issue.title.clone())
        .unwrap_or_default();

    let popup = centered_popup(area, 50, 7);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(format!(" Mark #{number} ready? "))
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" y confirm · n/Esc cancel ").centered())
        .border_style(Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    let body = Paragraph::new(vec![
        Line::from(Span::styled(
            title,
            Style::new().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(Span::styled(
            "The loop is already working this issue; marking it ready re-queues it.",
            Style::new().fg(Color::DarkGray),
        )),
    ])
    .block(block)
    .wrap(Wrap { trim: false });

    frame.render_widget(Clear, popup);
    frame.render_widget(body, popup);
}

/// The note shown under the quit prompt. Warns that quitting stops the running
/// workers the TUI started (#209), or that it just closes the UI when none run.
/// Pure for testing.
fn quit_note(workers_running: usize) -> &'static str {
    if workers_running > 0 {
        "Quitting stops all running workers."
    } else {
        "This closes the terminal UI."
    }
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

    // Warn the operator that quitting stops the workers the TUI started, so a
    // background loop is never left running after close (#209). Only mention it
    // when a worker is actually up.
    let note = quit_note(app.workers_running());

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
/// text (the Y-axis and KPI header carry the numbers) so the graph reads as a
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

/// Build the right-aligned Y-axis gutter for a day chart whose drawing area is
/// `height` rows tall (bars fill every row above the bottom X-axis label row).
/// The scale runs from `max` at the top down to `0` on the baseline row, with a
/// handful of evenly spaced rows carrying a tick value and every row drawing the
/// vertical rule, so the reader sizes each bar against values on the axis instead
/// of a number stamped on every bar (#203). Pure for testing.
fn y_axis(max: u64, height: u16) -> Vec<Line<'static>> {
    let h = height.max(1);
    if h == 1 {
        return vec![Line::from("0 └")];
    }
    let span = h - 1; // rows between the top of the scale and the baseline
    let mut lines: Vec<Line<'static>> = (0..h)
        .map(|i| {
            if i == h - 1 {
                Line::from("0 └")
            } else {
                Line::from("│")
            }
        })
        .collect();
    if max == 0 {
        return lines;
    }

    // Aim for a tick roughly every three rows, but never more ticks than the axis
    // has rows or whole-number values to place — so a small scale (e.g. max issues
    // of 1) shows just its endpoints rather than a run of rounded-down zeros.
    let mut divisions = (span / 3).clamp(1, 5).min(span);
    if u64::from(divisions) > max {
        divisions = max as u16;
    }
    for k in 1..=divisions {
        let value = max * u64::from(k) / u64::from(divisions);
        let pos =
            (u32::from(k) * u32::from(span) + u32::from(divisions) / 2) / u32::from(divisions);
        let row = span - pos.min(u32::from(span)) as u16;
        lines[usize::from(row)] = Line::from(format!("{value} ┤"));
    }
    lines
}

/// Draw one day chart: a titled panel with a labelled Y-axis down the left gutter
/// and the day bars filling the rest, so spend (or issue count) reads against a
/// scale on the axis rather than a value printed on every bar (#203).
fn draw_day_chart(
    frame: &mut Frame,
    area: Rect,
    title: &str,
    values: &[u64],
    days: u32,
    color: Color,
) {
    let block = Block::default()
        .borders(Borders::TOP)
        .title(title.to_string());
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let max = values.iter().copied().max().unwrap_or(0);
    let gutter_width = ((max.to_string().len() as u16) + 2)
        .clamp(3, 8)
        .min(inner.width);
    let [gutter, plot] =
        Layout::horizontal([Constraint::Length(gutter_width), Constraint::Min(0)]).areas(inner);

    let axis = Paragraph::new(y_axis(max, inner.height))
        .alignment(Alignment::Right)
        .style(Style::new().fg(Color::DarkGray));
    frame.render_widget(axis, gutter);

    let (bar_width, bar_gap) = bar_dims(plot.width, days);
    let chart = BarChart::new(day_bars(values))
        .bar_width(bar_width)
        .bar_gap(bar_gap)
        .bar_style(Style::new().fg(color))
        .label_style(Style::new().fg(Color::DarkGray));
    frame.render_widget(chart, plot);
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
    draw_day_chart(
        frame,
        cost_area,
        "Cost / day (cr)",
        &cost_values,
        mc.days,
        Color::Green,
    );

    let issue_values: Vec<u64> = mc.issues_per_day.iter().map(|&n| u64::from(n)).collect();
    draw_day_chart(
        frame,
        issues_area,
        "Issues / day",
        &issue_values,
        mc.days,
        Color::Cyan,
    );
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

/// The styled lines shown in the reply popup's question pane: the Copilot
/// question split into logical lines, or a dim placeholder when none was found
/// (the issue is `needs-info` but no marked comment was fetched). Pure for
/// testing (#165).
fn reply_question_content(question: Option<&str>) -> Vec<(String, Style)> {
    match question {
        Some(q) if !q.trim().is_empty() => {
            q.lines().map(|l| (l.to_string(), Style::new())).collect()
        }
        _ => vec![(
            "(no question text found — reply anyway to resume the issue)".to_string(),
            Style::new().fg(Color::DarkGray),
        )],
    }
}

/// Draw the reply popup: a centered modal showing the Copilot question and a
/// text field for the user's answer, so a `needs-info` issue can be answered
/// without leaving the TUI (#165). Ctrl+S posts the reply as an issue comment,
/// which the running loop then picks up. The question pane word-wraps and
/// scrolls (clamped to its last page); the reply field wraps and shows a cursor.
/// A [`Clear`] underneath wipes the cells so the list behind it does not show
/// through.
fn render_reply(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(70, 70, area);
    frame.render_widget(Clear, popup);

    let number = app.reply_issue().unwrap_or(0);
    let outer = Block::default()
        .borders(Borders::ALL)
        .title(format!(" Reply · #{number} "))
        .title_alignment(Alignment::Center)
        .title_bottom(
            Line::from(" type reply · ↑/↓ scroll · Enter newline · Ctrl+S send · Esc cancel ")
                .centered(),
        )
        .border_style(Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));
    let inner = outer.inner(popup);
    frame.render_widget(outer, popup);

    let [question_area, reply_area] =
        Layout::vertical([Constraint::Min(3), Constraint::Length(7)]).areas(inner);

    let q_block = Block::default()
        .borders(Borders::ALL)
        .title(" Copilot asks ")
        .border_style(Style::new().fg(Color::Magenta));
    let q_inner = q_block.inner(question_area);
    let content = reply_question_content(app.reply_question());
    let lines = wrap_styled(&content, q_inner.width as usize);
    // Clamp so the furthest scroll lands the last line at the bottom of the pane.
    let max_scroll = (lines.len() as u16).saturating_sub(q_inner.height);
    app.clamp_reply_scroll(max_scroll);
    let question = Paragraph::new(lines)
        .block(q_block)
        .scroll((app.reply_scroll(), 0));
    frame.render_widget(question, question_area);

    // The reply field is always the focused surface here, so it shows a cursor.
    frame.render_widget(
        field_widget("Your reply", app.reply_text(), true),
        reply_area,
    );
}

/// Draw the label editor popup: the issue's current labels above a field for a
/// label name, which Enter adds when the issue lacks it or removes when it
/// already carries it (#204). A [`Clear`] underneath wipes the cells so the list
/// behind it does not show through.
fn render_label_editor(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(60, 40, area);
    frame.render_widget(Clear, popup);

    let number = app.label_editor_issue().unwrap_or(0);
    let outer = Block::default()
        .borders(Borders::ALL)
        .title(format!(" Labels · #{number} "))
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" type label · Enter add/remove · Esc close ").centered())
        .border_style(Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));
    let inner = outer.inner(popup);
    frame.render_widget(outer, popup);

    let [labels_area, field_area] =
        Layout::vertical([Constraint::Min(3), Constraint::Length(3)]).areas(inner);

    let names = app.label_editor_labels();
    let current = if names.is_empty() {
        Line::from(Span::styled(
            "(no labels)",
            Style::new().fg(Color::DarkGray),
        ))
    } else {
        let mut spans: Vec<Span> = Vec::new();
        for name in &names {
            spans.push(Span::styled(
                format!(" {name} "),
                Style::new().fg(Color::Black).bg(Color::Cyan),
            ));
            spans.push(Span::raw(" "));
        }
        Line::from(spans)
    };
    let labels = Paragraph::new(current)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" Current ")
                .border_style(Style::new().fg(Color::Magenta)),
        )
        .wrap(Wrap { trim: false });
    frame.render_widget(labels, labels_area);

    // The name field is always the focused surface here, so it shows a cursor.
    frame.render_widget(
        field_widget("Label", app.label_editor_text(), true),
        field_area,
    );
}

/// Draw the bots popup: a centered, navigable list of every background worker
/// the session has started — running, stopped, or failed — so a stopped or
/// failed one can be restarted in place with the same options it was launched
/// with (#82), and a running one can be stopped from here (#210). A [`Clear`]
/// underneath wipes the cells so the list behind it does not show through.
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
        .title_bottom(
            Line::from(" j/k move · r restart · R restart all · s stop · Esc close ").centered(),
        )
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

/// Draw the messages popup: a centered, scrollable log of the feedback messages
/// the TUI has reported, newest first, so a status that scrolled past on the
/// message line can be read back later (#182). A [`Clear`] underneath wipes the
/// cells so the list behind it does not show through.
fn render_messages(frame: &mut Frame, area: Rect, app: &mut App) {
    let popup = centered_rect(70, 70, area);
    frame.render_widget(Clear, popup);

    let messages: Vec<String> = app.messages().to_vec();
    let title = format!(" Messages · {} ", messages.len());
    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .title_alignment(Alignment::Center)
        .title_bottom(Line::from(" j/k move · g/G top/bottom · Esc close ").centered())
        .border_style(Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD))
        .style(Style::new().bg(Color::Black));

    if messages.is_empty() {
        let body = Paragraph::new("No messages yet.")
            .block(block)
            .alignment(Alignment::Center)
            .style(Style::new().fg(Color::DarkGray));
        frame.render_widget(body, popup);
        return;
    }

    // Newest first so the latest feedback sits at the top of the log.
    let items: Vec<ListItem> = messages
        .iter()
        .rev()
        .map(|message| ListItem::new(Line::from(message.clone())))
        .collect();
    let list = List::new(items)
        .block(block)
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED))
        .highlight_symbol("▶ ");
    frame.render_stateful_widget(list, popup, &mut app.messages_state);
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

/// Like [`centered_popup`] but with an absolute column `width` so the leader
/// menu hugs its contents instead of a screen percentage (#160). Clamped to fit.
fn centered_popup_fixed(area: Rect, width: u16, height: u16) -> Rect {
    let [row] = Layout::vertical([Constraint::Length(height.min(area.height))])
        .flex(Flex::Center)
        .areas(area);
    let [col] = Layout::horizontal([Constraint::Length(width.min(area.width))])
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

/// The two-column gutter shown before an issue's number: a turning spinner while
/// the issue is being worked (whether by a local worker or an external loop), a
/// `?` when Copilot is waiting on the user (needs-info) so a pending question is
/// easy to spot (#165), or blanks so every row's number stays aligned. Animating
/// on the label alone means watching an external loop still shows motion on each
/// line being worked (#115, #157).
fn progress_marker(in_progress: bool, needs_info: bool, spinner: &str) -> Span<'static> {
    if in_progress {
        return Span::styled(
            format!("{spinner} "),
            Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        );
    }
    if needs_info {
        return Span::styled(
            "? ",
            Style::new().fg(Color::Magenta).add_modifier(Modifier::BOLD),
        );
    }
    Span::raw("  ")
}

/// Format a single issue as a list row: an in-progress marker, number, title,
/// and labels.
/// Build one issue row: a progress marker, the number, the title, any labels,
/// the author, and — when a background worker (bot) is currently working it —
/// that worker's pid, so the operator can see which bot is on which issue (#214).
fn issue_item(issue: &Issue, spinner: &str, worker_pid: Option<u32>) -> ListItem<'static> {
    let mut spans = vec![
        progress_marker(issue.is_in_progress(), issue.needs_info(), spinner),
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

    if let Some(pid) = worker_pid {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!("bot pid {pid}"),
            Style::new().fg(Color::Magenta),
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

    /// The text of a single terminal row, so a test can assert what lands on a
    /// specific line (e.g. the message line vs the keybinds line) (#182).
    fn row_text(terminal: &Terminal<TestBackend>, row: u16) -> String {
        let buffer = terminal.backend().buffer();
        let width = buffer.area.width as usize;
        let start = row as usize * width;
        buffer.content[start..start + width]
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
    fn shows_the_worker_pid_on_the_issue_it_is_working() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"create a TUI","labels":[{"name":"in-progress"}],"author":{"login":"octocat"}}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        // The loop published that the worker with this pid is on issue #96, so
        // the row should name that bot's pid (#214).
        app.set_worker_issue_pids(std::collections::HashMap::from([(96u64, 4242u32)]));
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("#96"));
        assert!(text.contains("bot pid 4242"));
    }

    #[test]
    fn hides_the_worker_pid_when_no_bot_is_on_the_issue() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"create a TUI","labels":[],"author":{"login":"octocat"}}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        // No worker is assigned, so the row carries no bot-pid label (#214).
        assert!(!buffer_text(&terminal).contains("bot pid"));
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
        // Only navigation, the global refresh, and the leader hint show; the
        // issue actions stay hidden (#129, #174).
        assert!(text.contains("space actions"));
        assert!(text.contains("f refresh"));
        assert!(!text.contains("c new"));
        assert!(!text.contains("m models"));
        assert!(!text.contains("ACTIONS"));
    }

    #[test]
    fn leader_popup_lists_the_issue_actions() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(120, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        // The popup titles itself and lists every binding the leader unlocks (#160).
        assert!(text.contains("Actions"));
        assert!(text.contains("c new"));
        assert!(text.contains("r ready"));
        assert!(text.contains("i reply"));
        assert!(text.contains("m models"));
        assert!(text.contains("add-worker"));
        assert!(text.contains("s summary"));
        // Refresh left the issue menu — it is a global key now (#174).
        assert!(!text.contains("f refresh"));
        // The footer still flags the open menu and how to leave it.
        assert!(text.contains("ACTIONS"));
        assert!(text.contains("esc cancel"));
        // The action menu replaces the base navigation hint.
        assert!(!text.contains("space actions"));
    }

    #[test]
    fn leader_actions_flip_ready_and_cover_every_binding() {
        let plain =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let app = App::new(plain);
        let keys: Vec<&str> = leader_actions(&app).iter().map(|(k, _)| *k).collect();
        // Every leader binding is present, matching handle_leader_key (#160).
        // Refresh is not here — it moved to the global keymap (#174).
        assert_eq!(
            keys,
            vec![
                "c", "r", "x", "d", "i", "e", "l", "L", "b", "M", "a", "q", "s", "m", "o", "p",
                "t", "$", "Esc"
            ]
        );
        // An unlabelled selection is offered *ready*…
        assert!(leader_actions(&app).contains(&("r", "ready")));

        // …and flips to *unready* once the selection carries the label (#146).
        let ready = parse_issues(
            r#"[{"number":96,"title":"t","labels":[{"name":"ready"}],"author":null}]"#,
        )
        .unwrap();
        let app = App::new(ready);
        assert!(leader_actions(&app).contains(&("r", "unready")));
    }

    #[test]
    fn leader_popup_advertises_the_output_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("o output"));
    }

    #[test]
    fn leader_popup_advertises_the_bots_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

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
        // Tall enough that the popup and the footer both render without overlap.
        let mut terminal = Terminal::new(TestBackend::new(220, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Refreshing"));
        // The refreshing indicator now lives on the message line, while the leader
        // badge stays on the keybinds line below it (#182)…
        assert!(text.contains("ACTIONS"));
        // …and the issue bindings live in the popup above them both (#160).
        assert!(text.contains("c new"));
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
    fn leader_popup_advertises_the_close_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("x close"));
    }

    #[test]
    fn leader_popup_advertises_the_auto_merge_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("a auto-merge"));
    }

    #[test]
    fn leader_popup_advertises_the_quality_assurance_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("q qa"));
    }

    #[test]
    fn leader_popup_ready_key_flips_to_unready_when_selected_is_labelled() {
        // An unlabelled selection offers to mark it ready…
        let plain =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(plain);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();
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
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();
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

    #[test]
    fn quit_note_warns_that_quitting_stops_running_workers() {
        // With workers up, the prompt tells the operator quitting stops them so
        // the new close-kills-workers behaviour is not a surprise (#209).
        assert_eq!(quit_note(1), "Quitting stops all running workers.");
        assert_eq!(quit_note(3), "Quitting stops all running workers.");
        // With none running there is nothing to stop, so it just notes the close.
        assert_eq!(quit_note(0), "This closes the terminal UI.");
    }

    #[test]
    fn renders_the_ready_confirmation_for_an_in_progress_issue() {
        let issues = parse_issues(
            r#"[{"number":96,"title":"create a TUI","labels":[{"name":"in-progress"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        app.toggle_ready(); // in-progress → opens the confirmation (#173)
        let mut terminal = Terminal::new(TestBackend::new(120, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Mark #96 ready?"));
        assert!(text.contains("y confirm"));
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
    fn header_shows_external_work_without_a_local_worker() {
        // No local workers, but issues/PRs carry the in-progress label because an
        // external loop is working them — the header still animates and names the
        // work so it is clear something is running, without a worker count (#157).
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
        assert!(text.contains("⠋ loop: running"));
        assert!(text.contains("working #96"));
        assert!(text.contains("resolving PR #12"));
        // Watching an external loop, the TUI started no workers of its own.
        assert!(!text.contains("worker"));
        assert!(!text.contains("waiting for work"));
    }

    #[test]
    fn header_shows_loop_off_when_nothing_is_running() {
        let text = spans_text(&header_spans(
            3,
            Some(96),
            0,
            &[],
            &[],
            "auto",
            false,
            true,
            true,
            "⠋",
        ));
        assert!(text.contains("loop: off"));
        assert!(!text.contains("loop: running"));
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
        // Args: in_progress, needs_info.
        // Not in progress, no question: blank gutter, two columns wide for alignment.
        assert_eq!(spans_text(&[progress_marker(false, false, "⠋")]), "  ");
        // In progress: a turning spinner, whoever is doing the work (#157).
        assert_eq!(spans_text(&[progress_marker(true, false, "⠋")]), "⠋ ");
        // A needs-info issue (never in-progress) shows the question marker (#165).
        assert_eq!(spans_text(&[progress_marker(false, true, "⠋")]), "? ");
        // In-progress wins over needs-info: still a spinner (#157).
        assert_eq!(spans_text(&[progress_marker(true, true, "⠋")]), "⠋ ");
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

        // An in-progress issue animates with a turning spinner even when the TUI
        // started no local worker, so watching an external loop shows motion on
        // the line being worked (#157) — never the old static dot.
        let text = buffer_text(&terminal);
        assert!(SPINNER_FRAMES.iter().any(|frame| text.contains(frame)));
        assert!(!text.contains("●"));
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
    fn leader_popup_advertises_the_pr_output_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

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
    fn leader_popup_advertises_the_closed_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

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
    fn y_axis_scales_from_max_down_to_zero() {
        let plain = |l: &Line| -> String { l.spans.iter().map(|s| s.content.as_ref()).collect() };
        let lines: Vec<String> = y_axis(120, 10).iter().map(plain).collect();

        assert_eq!(lines.len(), 10);
        // The top of the axis carries the max as a tick value, not the bars.
        assert!(
            lines[0].starts_with("120"),
            "top tick = max, got {:?}",
            lines[0]
        );
        assert!(lines[0].ends_with('┤'));
        // The baseline is zero with a corner rule that meets the X-axis.
        assert_eq!(lines[9], "0 └");
        // Every row draws a rule so the axis reads as one continuous line.
        for l in &lines {
            let last = l.chars().last().unwrap();
            assert!(matches!(last, '┤' | '│' | '└'), "row {:?} lacks a rule", l);
        }
        // An intermediate tick interpolates a value strictly between 0 and max.
        let ticks: Vec<u64> = lines
            .iter()
            .filter_map(|l| l.split_whitespace().next()?.parse().ok())
            .collect();
        assert!(ticks.contains(&120) && ticks.contains(&0));
        assert!(
            ticks.iter().any(|&v| v > 0 && v < 120),
            "no interior tick in {ticks:?}"
        );

        // A single-row axis degrades to just the baseline.
        assert_eq!(y_axis(50, 1), vec![Line::from("0 └")]);
        // A zero max never divides by zero: only the baseline is labelled, the
        // rest of the axis is a plain rule.
        let zero = y_axis(0, 6);
        assert_eq!(plain(zero.last().unwrap()), "0 └");
        assert!(zero[..zero.len() - 1].iter().all(|l| plain(l) == "│"));
    }

    #[test]
    fn cost_dashboard_draws_a_labelled_y_axis() {
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
        // The charts now carry a Y-axis: tick marks and a baseline corner down the
        // left gutter, with the scale value at the top rather than on each bar.
        assert!(text.contains('┤'), "expected a Y-axis tick rule");
        assert!(text.contains('└'), "expected a Y-axis baseline corner");
        assert!(
            text.contains("120"),
            "expected the peak spend on the axis scale"
        );
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
    fn leader_popup_advertises_the_cost_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("$ cost"));
    }

    #[test]
    fn leader_popup_advertises_the_details_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

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
    fn footer_advertises_the_reply_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(120, 10)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("i reply"));
    }

    #[test]
    fn reply_question_content_shows_the_question_or_a_placeholder() {
        let q = reply_question_content(Some("line one\nline two"));
        let text: Vec<String> = q.into_iter().map(|(l, _)| l).collect();
        assert_eq!(text, vec!["line one".to_string(), "line two".to_string()]);
        // No question falls back to a single placeholder line.
        let none = reply_question_content(None);
        assert_eq!(none.len(), 1);
        assert!(none[0].0.contains("no question text"));
    }

    #[test]
    fn renders_the_reply_popup_with_the_question_and_draft() {
        let issue = crate::github::parse_issue(
            r#"{"number":165,"title":"reply","labels":[{"name":"needs-info"}],
                "comments":[{"author":{"login":"hubot"},
                             "body":"Which database should I use? <!-- copilot-loop:needs-info -->"}]}"#,
        )
        .unwrap();
        let mut app = App::new(Vec::new());
        app.open_reply_with(issue);
        app.reply_input('u');
        app.reply_input('s');
        app.reply_input('e');

        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Reply"));
        assert!(text.contains("#165"));
        assert!(text.contains("Copilot asks"));
        assert!(text.contains("Which database"));
        assert!(text.contains("Your reply"));
        // The typed draft shows in the reply field.
        assert!(text.contains("use"));
        // The send/cancel hint is offered on the border.
        assert!(text.contains("Ctrl+S send"));
    }

    #[test]
    fn renders_the_label_editor_with_current_labels_and_typed_name() {
        let issues = crate::github::parse_issues(
            r#"[{"number":204,"title":"t","labels":[{"name":"bug"}],"author":null}]"#,
        )
        .unwrap();
        let mut app = App::new(issues);
        app.open_label_editor();
        app.label_editor_input('r');
        app.label_editor_input('e');
        app.label_editor_input('a');
        app.label_editor_input('d');
        app.label_editor_input('y');

        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Labels"));
        assert!(text.contains("#204"));
        // The issue's existing labels are shown so the user knows what to remove.
        assert!(text.contains("Current"));
        assert!(text.contains("bug"));
        // The typed label name shows in the field.
        assert!(text.contains("ready"));
        // The add/remove hint is offered on the border.
        assert!(text.contains("Enter add/remove"));
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
        // The footer advertises the stop action so the user can end a bot (#210).
        assert!(text.contains("s stop"));
    }

    #[test]
    fn message_line_sits_on_its_own_row_above_the_keybinds() {
        // Feedback moves off the keybinds line onto its own line above it (#182).
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.set_status("Created issue #7.");
        let height = 10u16;
        let mut terminal = Terminal::new(TestBackend::new(80, height)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let message_row = row_text(&terminal, height - 2);
        let keybinds_row = row_text(&terminal, height - 1);
        // The status shows on the message line…
        assert!(message_row.contains("Created issue #7."));
        // …the keybinds show on their own line…
        assert!(keybinds_row.contains("space actions"));
        // …and the two never share a line.
        assert!(!keybinds_row.contains("Created issue #7."));
        assert!(!message_row.contains("space actions"));
    }

    #[test]
    fn messages_popup_lists_the_recorded_feedback_newest_first() {
        let mut app = App::new(Vec::new());
        app.set_status("Older message.");
        app.set_status("Newer message.");
        app.open_messages();
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        let text = buffer_text(&terminal);
        assert!(text.contains("Messages"));
        assert!(text.contains("Older message."));
        assert!(text.contains("Newer message."));
        assert!(text.contains("Esc close"));
    }

    #[test]
    fn messages_popup_shows_a_placeholder_when_empty() {
        let mut app = App::new(Vec::new());
        app.open_messages();
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("No messages yet."));
    }

    #[test]
    fn leader_popup_advertises_the_messages_key() {
        let issues =
            parse_issues(r#"[{"number":96,"title":"t","labels":[],"author":null}]"#).unwrap();
        let mut app = App::new(issues);
        app.enter_leader();
        let mut terminal = Terminal::new(TestBackend::new(60, 24)).unwrap();

        terminal.draw(|frame| render(frame, &mut app)).unwrap();

        assert!(buffer_text(&terminal).contains("M messages"));
    }
}
