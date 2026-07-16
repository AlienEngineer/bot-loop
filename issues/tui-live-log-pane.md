# Show a live log pane inside the TUI instead of an external pager

Viewing a bot's log today (l / Enter) shells out to an external pager, which
takes over the screen and drops you out of the dashboard. A built-in log pane
would keep context.

- Add a split layout: the bot list on one side, a live-tailing log pane for the
  selected bot on the other.
- Follow the log as it grows (tail -f style) with an option to pause following
  and scroll back through history.
- Support scrollback with the configured navigation keys and show a scrollbar.
- Keep the external-pager option available for full-screen reading.

Builds on the ratatui rewrite (#51). This makes monitoring several bots at once
far smoother.

Label: none
