# Restart a stopped or failed bot in place

When a bot stops or fails, the only options today are to clear it (c) and spawn
a fresh one (s), losing its slot and context. A direct restart would be quicker.

- Add a restart action on the selected bot that re-spawns it with the same
  options it was launched with (repo dir, forwarded loop flags).
- Preserve or archive the previous log rather than silently overwriting it.
- Optionally offer "restart all stopped/failed" as a bulk action.

Builds on the ratatui rewrite (#51). Reduces friction when transient failures
happen.

Label: none
