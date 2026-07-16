# Make the TUI keybindings configurable via a config file

Every TUI key is hardcoded today in tui_action_for_key (s/n spawn, x/d stop,
j/k navigate, l/Enter log, c clear, r refresh, ?/h help, q quit). Users who
prefer a different layout cannot change them.

- Load keybindings from a config file (e.g. TOML) that maps keys to the existing
  action names: spawn, stop, stop-all, up, down, log, clear, refresh, help, quit.
- Fall back to the current defaults for any action left unmapped, so existing
  muscle memory keeps working.
- Allow several keys per action and detect/report conflicting bindings on load
  instead of silently shadowing one.
- Surface the active bindings in the help overlay so they stay discoverable.

Builds on the ratatui rewrite (#51). Ship a documented default config.

Label: none
