# Send a notification when a PR is opened or an issue fails

The loop runs unattended for long periods with no signal when it opens a PR or
gives up on an issue short of watching the logs.

- Add an optional notification hook fired on key events: PR opened, issue marked
  needs-info, issue marked copilot-failed.
- Support a generic webhook URL (env, e.g. NOTIFY_WEBHOOK) posting a small JSON
  payload so it works with Slack, Discord, or a custom endpoint.
- No-op cleanly when unset, and never let a notification failure abort the loop.

Label: none
