# Add a persistent config file for TUI defaults

Every run currently re-specifies options on the command line (--bots,
--repo-dir, --loop-script, plus forwarded loop flags). A config file would let
users set their defaults once.

- Load a config file (e.g. TOML) for defaults: startup bot count, repo dir,
  loop-script path, default model and other forwarded loop flags, and the
  locations of the theme and keybind files.
- Precedence: command-line flags override the config file, which overrides the
  built-in defaults.
- Look in a standard location (e.g. ~/.config/copilot-loop/config.toml) plus an
  optional repo-local file.
- Document the schema and ship a commented example.

Builds on the ratatui rewrite (#51). One config becomes the home for keybinds
and theming (see the keybinds and theming issues).

Label: none
