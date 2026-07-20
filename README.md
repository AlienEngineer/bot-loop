# copilot-loop

A tool to automate software development. It pulls labelled GitHub issues, hands
each one to the [GitHub Copilot CLI](https://github.com/github/copilot-cli) to
resolve, opens a pull request, and repeats — so it works your backlog
unattended. Several instances can run in parallel against one repository; a
GitHub lock file keeps them off the same issue.

It ships as two commands:

- **`bot-loop`** — a terminal UI (TUI) to browse, create, and close issues, start
  background workers, and watch cost. It is self-explanatory; press `space` for
  the action menu.
- **`bot-loop-bash`** — the raw autonomous loop, run from inside the repository
  you want it to work on.

### The TUI

```
 GitHub Issues   3 open  ·  loop: running  ·  2 workers  ·  working #96, #97  ·  model: auto  ·  auto-merge: off  ·  qa: on  ·  summary: on
┌ Issues ──────────────────────────────────────────────────────────────────────┐
│> #96    Add dark-mode toggle              [in-progress]  @alienengineer      │
│  #97    Fix crash on empty config         [in-progress]  @alienengineer      │
│  #98    Document the CLI flags            [ready]        @alienengineer      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
 j/k move · g/G top/bottom · space actions · q quit
```

### The script

```
$ bot-loop-bash
2026-07-20 09:46:01 | starting copilot-loop
2026-07-20 09:46:01 | ============================================================
2026-07-20 09:46:01 |   GitHub repo: AlienEngineer/bot-loop
2026-07-20 09:46:01 |   gh account:  alienengineer @ github.com
2026-07-20 09:46:01 |   local dir:   /repos/bot-loop
2026-07-20 09:46:01 | ============================================================
2026-07-20 09:46:01 | default_branch=main trigger_label=ready sleep=5m
2026-07-20 09:46:02 | issue #98 on AlienEngineer/bot-loop: Document the CLI flags
2026-07-20 09:46:02 | issue #98: working on branch copilot/98-document-the-cli-flags
2026-07-20 09:46:03 | issue #98: running copilot (log: .copilot-loop/logs/issue-98-…log)
2026-07-20 09:47:38 | issue #98: copilot exited with code 0
2026-07-20 09:47:40 | issue #98: 3 commit(s), pushing branch copilot/98-document-the-cli-flags
2026-07-20 09:47:41 | issue #98: DONE -> https://github.com/AlienEngineer/bot-loop/pull/171
```

## Getting Started

Requires `git`, the authenticated GitHub CLI (`gh auth login`), and the
[GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot`) on your
`PATH`.

Install from the tap with Homebrew:

```sh
brew tap alienengineer/bot-loop https://github.com/AlienEngineer/bot-loop
brew install bot-loop
```

Homebrew pulls in `git` and `gh`, but not `copilot` — install that separately.
Upgrade with `brew upgrade bot-loop`.

Then run from inside your repository:

```sh
bot-loop-bash        # the autonomous loop
bot-loop             # the TUI
```

## How the loop works

Each pass the loop:

1. Turns any markdown files in `issues/` into GitHub issues.
2. Syncs the local default branch with the remote.
3. Resolves merge conflicts on open PRs (hands the conflicts to Copilot).
4. Fixes failing CI checks on open PRs.
5. Picks the next issue — one awaiting a human reply (`needs-info` /
   `copilot-failed`), otherwise the oldest open issue with the trigger label
   (`ready`). Issues with an unmet `Wait for: #N` dependency are held back.
6. Claims it (`in-progress` label, under a GitHub lock so parallel instances
   never collide).
7. Creates a branch — and its own worktree — from the latest default branch.
8. Runs Copilot to resolve it, then posts the run's cost as an issue comment.
   Unless disabled, Copilot also adds tests from the user's perspective.
9. If Copilot needs more info, posts the question, labels the issue `needs-info`,
   and waits. Otherwise commits, pushes, and opens a PR that closes the issue
   (auto-merging it when `--auto-merge` is on).
10. Labels the issue `copilot-done` on success, or `copilot-failed` on failure
    (never retried automatically).
11. Sweeps merged branches and worktrees, then sleeps if there is no work (press
    `f` to wake it).

## Flags

Every option is a command-line flag or the matching environment variable; when
both are set, the flag wins. `--flag value` and `--flag=value` both work. Run
`bot-loop-bash --help` for the authoritative list.

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--trigger-label <label>` | `TRIGGER_LABEL` | `ready` | Label that marks an issue as ready to be picked up. |
| `--sleep-minutes <n>` | `SLEEP_MINUTES` | `5` | Minutes to sleep when there is no work. Press `f` to wake early. |
| `--repo-dir <dir>` | `REPO_DIR` | current git repo | Repository to operate in. |
| `--model <model>` | `COPILOT_MODEL` | auto | Model passed to `copilot --model`. |
| `--copilot-timeout <dur>` | `COPILOT_TIMEOUT` | `30m` | Wall-clock limit per Copilot run so a stuck run cannot block the loop. Seconds, or an `s`/`m`/`h`/`d` suffix (`1800`, `30m`, `2h`); `0`/`off` disables it. |
| `--commit-model <model>` | `COMMIT_MODEL` | `off` | Model that writes the commit message from the staged diff. `off` uses a deterministic `Resolve #<n>: <title>` message. |
| `--triage-model <model>` | `TRIAGE_MODEL` | `off` | Cheap model that classifies each issue as trivial/normal/complex before coding, so the coding model can be chosen per difficulty. `off` disables triage. |
| `--triage-map <map>` | `TRIAGE_MAP` | unset | Comma-separated `class=model` pairs mapping a triage class to the coding model, e.g. `trivial=gpt-5-mini,complex=claude-opus-4.5`. An unmapped class falls back to `--model`. |
| `--issues-dir <dir>` | `ISSUES_DIR` | `<repo>/issues` | Folder scanned for issue markdown files. |
| `--quiet` | `QUIET` | off | Only write Copilot's output to the per-run log files; do not stream it to stdout. |
| `--worktrees` / `--no-worktrees` | `USE_WORKTREES` | on | Give every issue its own git worktree (never touch the shared checkout), or work in the current checkout instead. |
| `--auto-merge` / `--no-auto-merge` | `AUTO_MERGE` | off | Merge every PR automatically (GitHub auto-merge when the repo allows it, otherwise an immediate merge), or leave PRs open for manual review. |
| `--quality-assurance` / `--no-quality-assurance` | `QUALITY_ASSURANCE` | on | Ask Copilot to add tests for each issue, written from the user's perspective. Aliases: `--qa` / `--no-qa`. Turn off to save cost. |
| `--merge-method <method>` | `MERGE_METHOD` | `merge` | Merge method used for auto-merge: `merge`, `squash`, or `rebase`. |
| `--cleanup-merged` / `--no-cleanup-merged` | `CLEANUP_MERGED` | on | Sweep merged issue branches and worktrees each pass, or leave them in place. |
| `--delete-remote-branch` / `--no-delete-remote-branch` | `DELETE_REMOTE_BRANCH` | auto | Delete a merged issue's remote branch. `auto` deletes only when the repo does not already delete head branches on merge. |
| `-h`, `--help` | — | — | Show help and exit. |
| `-V`, `--version` | — | — | Print the version and exit. |

Env-only settings:

- **`SELF_UPDATE`** (default on) — set to `0` to stop the loop pulling and
  re-execing itself when the script changes upstream.
- **`SYNC_REMOTE`** (default on) — set to `0` to stop the loop syncing the local
  default branch with the remote before each pass.
