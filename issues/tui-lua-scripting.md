# Make the TUI extensible with Lua scripts

Power users will want behaviour the core TUI does not ship: custom actions,
extra columns, event hooks, or their own integrations. Rather than growing the
core for every request, expose a Lua scripting layer.

- Embed a Lua runtime (e.g. mlua) and load user scripts from a scripts/ or
  plugins/ directory.
- Expose a small, documented API: register a custom action bound to a key, add a
  status/column renderer, and subscribe to lifecycle events (bot spawned, bot
  stopped, PR opened, issue failed).
- Sandbox scripts sensibly and isolate failures so a broken script logs an error
  instead of crashing the TUI.
- Ship one example script (e.g. a custom notification) and document the API.

Builds on the ratatui rewrite (#51). This keeps the core lean while letting
users extend it.

Label: none
