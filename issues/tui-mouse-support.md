# Add mouse support to the TUI

The TUI is keyboard-only. Mouse support is a low-effort, high-comfort addition
for many users.

- Click a bot row to select it; double-click (or click a log affordance) to open
  its log/detail.
- Use the scroll-wheel to move the selection and to scroll the log pane.
- Make header/footer actions clickable where it makes sense.
- Keep full keyboard parity; mouse input is additive, never required.

Builds on the ratatui rewrite (#51); ratatui/crossterm expose mouse events
directly.

Label: none
