# Filter and search the bot list

With many bots running, finding the one you care about (by state, or by the
issue it is on) means scanning the whole list by eye.

- Add an incremental filter/search box (e.g. bound to /) that narrows the list
  by bot id, state, or the issue/PR text in its status line.
- Add quick filters by state (running, stopped, failed) via keys or the command
  layer.
- Keep the selection stable while filtering and show a clear "N of M shown"
  indicator.

Builds on the ratatui rewrite (#51). Scales the TUI to busy sessions with lots
of parallel work.

Label: none
