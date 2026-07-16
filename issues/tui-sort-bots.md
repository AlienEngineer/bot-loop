# Sort the bot list

The list is always ordered by bot id (spawn order). With several bots running,
there is no way to bring the interesting ones to the top.

- Add a sort action that cycles the ordering: by id, state (running / stopped /
  failed), uptime, or the issue a bot is on.
- Show the active sort in the header and keep the selection stable across
  re-sorts.
- Keep id-ascending as the default so current behaviour is unchanged until the
  user changes it.

Builds on the ratatui rewrite (#51). Pairs with the filter/search issue to scale
the TUI to busy sessions.

Label: none
