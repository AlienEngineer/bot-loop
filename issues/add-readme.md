# Add a README with setup, usage, and the issue-file workflow

The repo has no README, so new users must read the 1000-line script header to
understand it. Add a top-level README.md covering:

- What copilot-loop does and its requirements (git, gh authenticated, copilot).
- Quick start: running ./copilot-loop.sh, plus the multi-instance / worktree setup.
- The flags and their env-var equivalents (link to the header as source of truth
  rather than duplicating the whole list).
- The issues/ markdown workflow: how a file becomes an issue, and the
  "Wait for:", "Depends on:", and "Label:" directives.
- The lifecycle states (ready, in-progress, pending, needs-info, copilot-done,
  copilot-failed) and what each means.
- How to run the test suite under tests/.

Keep it concise and point back to the script header for the authoritative detail.

Label: none
