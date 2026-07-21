# bot-loop

Autonomous loop that pulls labelled GitHub issues, hands each one to the
[GitHub Copilot CLI](https://github.com/github/copilot-cli) to resolve, and opens
a pull request — so it works your backlog unattended. Several instances can run
in parallel against one repository; a GitHub lock keeps them off the same issue.

It ships as two commands:

- **`bot-loop-bash`** — the raw autonomous loop, run from inside the repository
  you want it to work on.
- **`bot-loop`** — a terminal UI to browse issues and start background workers.

## Getting started

Requires `git`, the authenticated GitHub CLI (`gh auth login`), and the
[GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot`) on your
`PATH`.

Install from the tap with Homebrew:

```sh
brew tap alienengineer/bot-loop
brew install bot-loop
```

Homebrew installs a prebuilt universal (arm64 + x86_64) macOS binary and pulls in
`git` and `gh`, but not `copilot` — install that separately. Upgrade later with
`brew upgrade bot-loop`.

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
   and waits. Otherwise commits, syncs the branch with the latest default branch,
   pushes, and opens a PR that closes the issue (auto-merging it when
   `--auto-merge` is on).
10. Labels the issue `copilot-done` on success, or `copilot-failed` on failure
    (never retried automatically). On success it also posts a short summary of
    what it did.
11. Sweeps merged branches and worktrees, then sleeps if there is no work (press
    `f` to wake it).

## Flags

Every option is a command-line flag or the matching environment variable; when
both are set, the flag wins. `--flag value` and `--flag=value` both work. Run
`bot-loop-bash --help` for the authoritative list.

| Flag | Env var | Default | Description |
|------|---------|---------|-------------|
| `--trigger-label <label>` | `TRIGGER_LABEL` | `ready` | Label that marks an issue as ready to be picked up. |
| `--plan-label <label>` | `PLAN_LABEL` | `plan` | Label that puts an issue into plan mode: Copilot drafts an implementation plan (no code changes), posts it for review, then the issue waits for the trigger label to run the plan. |
| `--sleep-minutes <n>` | `SLEEP_MINUTES` | `5` | Minutes to sleep when there is no work. Press `f` to wake early. |
| `--repo-dir <dir>` | `REPO_DIR` | current git repo | Repository to operate in. |
| `--model <model>` | `COPILOT_MODEL` | auto | Model passed to `copilot --model`. |
| `--copilot-timeout <dur>` | `COPILOT_TIMEOUT` | `30m` | Wall-clock limit per Copilot run so a stuck run cannot block the loop. Seconds, or an `s`/`m`/`h`/`d` suffix (`1800`, `30m`, `2h`); `0`/`off` disables it. |
| `--commit-model <model>` | `COMMIT_MODEL` | `off` | Model that writes the commit message from the staged diff. `off` uses a deterministic `Resolve #<n>: <title>` message. |
| `--summary-model <model>` | `SUMMARY_MODEL` | `gpt-5-mini` | Light model that writes the per-issue close summary from the run's session log. `auto`/`off` lets Copilot pick its own default. |
| `--triage-model <model>` | `TRIAGE_MODEL` | `off` | Cheap model that classifies each issue as trivial/normal/complex before coding, so the coding model can be chosen per difficulty. The same model also checks whether the issue is specified well enough: a genuinely vague one is asked a clarifying question (labelled `needs-info`) and gets no coding run. `off` disables triage. |
| `--triage-map <map>` | `TRIAGE_MAP` | unset | Comma-separated `class=model` pairs mapping a triage class to the coding model, e.g. `trivial=gpt-5-mini,complex=claude-opus-4.5`. An unmapped class falls back to `--model`. |
| `--cost-saver` / `--no-cost-saver` | `COST_SAVER` | `off` | Cost-saver preset: smart model routing with built-in defaults instead of a hand-written triage map — trivial on a cheap model, normal on a mid model, complex on your `--model` (or a strong default). An explicit `--triage-model`/`--triage-map` overrides it. |
| `--triage-timeout-map <m>` | `TRIAGE_TIMEOUT_MAP` | unset | Comma-separated `class=factor` pairs scaling `--copilot-timeout` by triage difficulty. The factor is a percentage of the baseline (`33%`) or an absolute duration (`10m`). Defaults to `trivial=33%,complex=200%` when triage is on; `off` keeps a flat timeout. |
| `--agents-model <model>` | `AGENTS_MODEL` | `claude-sonnet-4.5` | Model for the one-time AGENTS.md bootstrap. Runs once per repo, so it defaults to a capable mid model. `off` disables the bootstrap. |
| `--issues-dir <dir>` | `ISSUES_DIR` | `<repo>/issues` | Folder scanned for issue markdown files. |
| `--quiet` | `QUIET` | off | Only write Copilot's output to the per-run log files; do not stream it to stdout. |
| `--verbose` / `-v` | `VERBOSE` | off | Emit extra loop-level narration — each pass's phases (sync, sweep, PR scans, queue scan, claim, sleep). |
| `--worktrees` / `--no-worktrees` | `USE_WORKTREES` | on | Give every issue its own git worktree (never touch the shared checkout), or work in the current checkout instead. |
| `--auto-merge` / `--no-auto-merge` | `AUTO_MERGE` | off | Merge every PR automatically (GitHub auto-merge when the repo allows it, otherwise an immediate merge), or leave PRs open for manual review. |
| `--quality-assurance` / `--no-quality-assurance` | `QUALITY_ASSURANCE` | on | Ask Copilot to add tests for each issue, written from the user's perspective. Aliases: `--qa` / `--no-qa`. Turn off to save cost. |
| `--summary` / `--no-summary` | `REPORT_SUMMARY` | on | Post a short summary of what was done as a comment on each resolved issue. Turn off to save cost. |
| `--auto-fix` / `--no-auto-fix` | `AUTO_FIX` | on | When the loop itself crashes, report the crash to the bot-loop repo so it can be fixed. `--no-auto-fix` only logs crashes. |
| `--merge-method <method>` | `MERGE_METHOD` | `merge` | Merge method used for auto-merge: `merge`, `squash`, or `rebase`. |
| `--cleanup-merged` / `--no-cleanup-merged` | `CLEANUP_MERGED` | on | Sweep merged issue branches and worktrees each pass, or leave them in place. |
| `--delete-remote-branch` / `--no-delete-remote-branch` | `DELETE_REMOTE_BRANCH` | auto | Delete a merged issue's remote branch. `auto` deletes only when the repo does not already delete head branches on merge. |
| `-h`, `--help` | — | — | Show help and exit. |
| `-V`, `--version` | — | — | Print the version and exit. |

A few settings are environment-only (no flag):

- **`SELF_UPDATE`** (default on) — set to `0` to stop the loop pulling and
  re-execing itself when the script changes upstream.
- **`SYNC_REMOTE`** (default on) — set to `0` to stop the loop syncing the local
  default branch with the remote before each pass.
- **`BOT_LOOP_REPO`** (default `AlienEngineer/bot-loop`) — the repo `--auto-fix`
  files loop-crash reports against.
- **`BOT_LOOP_EMAIL`** (default `aimirim.software@gmail.com`) — maintainer address
  the auto-fix path emails when you cannot push to `BOT_LOOP_REPO`.
