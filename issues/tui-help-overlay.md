# Replace the help screen with a keybinding cheat-sheet overlay

Help today (? / h) is a basic screen. A proper overlay that reflects the actual
(possibly user-configured) keybindings would be more useful and discoverable.

- Show a modal overlay listing every action and its currently bound key(s),
  grouped by category (navigation, bot control, view).
- Generate it from the live keybinding table so it stays correct when keys are
  remapped (see the keybinds issue).
- Dismiss with Esc/any key and make it responsive to terminal size, scrolling if
  needed.
- Show a persistent one-line hint of the most common keys in the footer.

Builds on the ratatui rewrite (#51). Keeps the growing keymap learnable.

Label: none
