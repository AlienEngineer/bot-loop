# Show an activity indicator for working bots

A running bot looks the same whether it is actively making progress or idle and
stuck; only the last status line hints at any movement.

- Add an animated indicator (spinner / pulse) next to actively-working bots,
  advanced on the render tick, and static for stopped or failed bots.
- Mark a bot as "stalled" when its log has not advanced for a configurable
  interval, so hung bots stand out.
- Keep it subtle and theme-aware (see the theming issue).

Builds on the ratatui rewrite (#51). Makes progress and stalls visible at a
glance across the fleet.

Label: none
