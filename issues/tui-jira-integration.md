# Integrate the TUI with Jira via jira-terminal

Teams that track work in Jira should be able to feed Jira issues to the bots
without leaving the TUI. The existing jira-terminal CLI already handles auth and
Jira queries, so wrap it rather than reimplementing a Jira client.

- Add a Jira panel that lists issues from a configurable JQL query by shelling
  out to jira-terminal.
- Let the user pick a Jira issue and hand it to a bot as its work item, mapping
  the Jira issue into the loop's issue-file / GitHub-issue flow.
- Reflect progress back to Jira where possible: transition status or add a
  comment when a PR opens, again via jira-terminal.
- Make the integration optional and no-op cleanly when jira-terminal is not
  installed or not configured.

Builds on the ratatui rewrite (#51). This meets teams where their backlog
already lives.

Label: none
