# Add a status dashboard header with aggregate stats

The header shows a running-bot count. A richer dashboard would give an
at-a-glance picture of the whole session.

- Summarise across all bots: running / stopped / failed counts, PRs opened,
  issues completed, and issues that needed info or failed.
- Color-code the summary and update it live.
- Keep it compact and responsive so it still fits narrow terminals.

Builds on the ratatui rewrite (#51). Gives a quick pulse of how the fleet is
doing without drilling into each bot.

Label: none
