# Add a bot detail/inspector pane

The list shows each bot's latest status line but not the richer context a user
wants when deciding what to do: which issue the bot is on, how long it has run,
and any PR it opened.

- Add a detail pane for the selected bot showing: bot id, PID, state, elapsed
  uptime, the issue number/title it is working, and the PR URL once opened.
- Derive this from the bot's log/status output, reusing the status-line parsing
  the list already does.
- Add a key to open the current issue or PR in the browser (gh browse / opener).
- Update the pane live as the bot progresses.

Builds on the ratatui rewrite (#51). This turns the TUI from a launcher into a
real monitor.

Label: none
