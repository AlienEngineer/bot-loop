# Add a command palette / command mode

With vim-style keybindings planned for the rewrite, a command mode is a natural
fit and makes every action reachable without memorising a key.

- Add a command palette (e.g. opened with `:`) that lists every action with a
  fuzzy filter and runs the selected one on Enter.
- Drive it from the same action/keybinding table as the keymap so the two never
  diverge, and show each action's currently bound key(s) alongside it.
- Make it responsive to terminal size and dismissable with Esc.

Builds on the ratatui rewrite (#51). Complements the configurable keybindings and
the help overlay.

Label: none
