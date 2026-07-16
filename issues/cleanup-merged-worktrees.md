# Clean up branches and worktrees after their PR is merged

Each issue runs on its own branch and (optionally) worktree. After a PR merges,
stale local branches and worktrees accumulate, wasting disk and cluttering git.

- After confirming a PR merged (or on a periodic sweep), remove the local work
  branch and its worktree for that issue.
- Optionally delete the remote branch when the repo does not auto-delete on merge.
- Be safe: never touch the default branch or a branch that still has un-pushed work.

Label: none
