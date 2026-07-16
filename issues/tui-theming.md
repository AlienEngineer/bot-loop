# Add theming and color schemes

The TUI uses a fixed color treatment. Configurable themes improve readability
across terminals and let users match their setup.

- Support named color schemes (at least a dark and a light default) selectable
  via config.
- Color-code bot states consistently (running, stopped, failed) and theme the
  header, selection highlight, borders and log pane.
- Allow overriding individual colors in the config file.
- Respect NO_COLOR and degrade gracefully on terminals without truecolor.

Builds on the ratatui rewrite (#51) and shares the config file (see the config
issue).

Label: none
