# Add a timeout to the main Copilot run so a stuck run cannot block the loop

The commit-message model call is wrapped in _run_with_timeout, but the main
issue-resolving run (run_copilot in process_single_issue) has no timeout. If that
run hangs, the whole loop is stuck indefinitely with no progress and no retry.

- Add a configurable COPILOT_TIMEOUT (env + --copilot-timeout flag) with a
  sensible default (e.g. 30m) and 0/off to disable.
- Wrap the main run in the existing timeout helper.
- On timeout, treat it as a failed attempt so the existing retry / copilot-failed
  path applies, and record it in the issue log.
- Apply the same timeout to the PR conflict-resolution Copilot run.

Label: none
