# copilot-loop

An autonomous loop that pulls labelled GitHub issues, hands each one to the
GitHub Copilot CLI to resolve, and opens a pull request. When no work is
available it sleeps and checks again.

Multiple instances can run at once against the same repository. Issue selection
and claiming are protected by a GitHub lock file (`.copilot-loop/github.lock`),
so bots never work on the same issue.

> The authoritative reference for every flag, environment variable, and the full
> per-iteration flow lives in the header comment of
> [`copilot-loop.sh`](./copilot-loop.sh). This README is a concise entry point;
> read the header for the detail.

## Requirements

- `git`
- `gh` — the GitHub CLI, authenticated (`gh auth login`) for the host **and account** that can access the repo you point it at. If the repo lives on a GitHub Enterprise host, log in to that host too: `gh auth login --hostname your.enterprise.host`.
- `copilot` — the GitHub Copilot CLI

## Quick start

Run the loop from inside the repository you want it to work on:

```sh
./copilot-loop.sh
```

It opens issues from any markdown files in `issues/`, picks the oldest open
issue labelled `ready`, works it on a fresh branch, and opens a PR that closes
the issue. Press `f` while it is sleeping to wake it and check for work
immediately.

### Multiple instances / worktrees

Several instances can run in parallel. To avoid file-system conflicts, give each
one its own [git worktree](https://git-scm.com/docs/git-worktree):

```sh
# Terminal 1 — main working tree
./copilot-loop.sh

# Terminal 2 — a second worktree and instance
git worktree add ../instance-2
cd ../instance-2
./copilot-loop.sh
```

By default each issue runs in its own worktree (a different folder) so the
shared checkout is never touched and parallel instances never conflict. Turn
this off with `--no-worktrees` to work in the current checkout instead.

When the loop runs inside a bare-repository worktree setup (a `git clone --bare`
whose branches are all checked out as linked worktrees), each issue's worktree
is created directly under the bare root and named after its branch (slashes
flattened to dashes) — the same folder a manual `git worktree add` would use — so
the loop's worktrees and any you manage by hand share one namespace and never
collide. In an ordinary checkout they are grouped in a `copilot-loop-worktrees`
folder beside the repository instead.

There is also an optional terminal UI, [`copilot-loop-tui.sh`](./copilot-loop-tui.sh),
that spawns, monitors, and stops several loop instances ("bots") side by side.

### Rust TUI (experimental)

A ratatui-based rewrite of the terminal UI lives in [`tui/`](./tui) (see #51). The
first slice lists the repository's open GitHub issues in a scrollable,
vim-navigable view. It reads issues with the `gh` CLI, so `gh` must be
authenticated for the target repo. Issue actions live behind a `space` leader
key (#129): press `space` to reveal them in the footer, then one key runs the
action (or `Esc` cancels). Press `space` then `r` to toggle the trigger
label (`ready`, or `$TRIGGER_LABEL`) on the selected issue: it is added when
absent so the loop picks the issue up, or removed when present so a
mistakenly-queued issue can be pulled back out (#146). Press `space` then `c` to create a new issue: fill in a title and description, then
`Ctrl+S` to submit it (no label is added by default). Press `space` then `x` to close the
selected issue: a confirmation popup names it, then `y` closes it on GitHub
(`n`/`Esc` cancels). Press `space` then `l` to start a background `copilot-loop.sh` worker
that works through the ready issues; press `space` then `l` again to add more workers running
in parallel. Each worker claims issues under a GitHub lock (and isolates each in
its own git worktree), so multiple workers safely pick *different* issues (#134).
Press `space` then `L` (Shift+L) to stop every worker. Workers run detached — each one's
output captured to `.copilot-loop/tui/loop-<n>.log` — and keep going after you
quit the TUI. The loop script is found at the repo root
(override with `$COPILOT_LOOP_SCRIPT`). Press `space` then `o` to open a side panel on the
right that tails the running loop's output for the selected issue (its
`.copilot-loop/logs/issue-<n>-…log`, following the PR run too); press `space` then `o` again
to close it. That log holds the loop's own narration — branch creation, "running
copilot", the PR push — interleaved with Copilot's transcript, so the panel shows
the whole run just as the bash loop prints it to the terminal, not only Copilot's
output (#126).

While workers run the header shows a turning spinner next to `loop: running`,
how many workers are running, and the issues they are working (`working #96, #97`,
or `waiting for work` when idle), and the list refreshes on its own so
`in-progress` issues — flagged with a spinner in their row — appear as the
workers claim them, without a manual refresh (#115). The workers also handle pull
requests (resolving merge conflicts and fixing failing checks); since PRs are not
in the issue list, the header calls that out with its own spinner and a
`resolving PR #12` note, and the status line announces each PR a worker starts, so
it is always clear a worker is busy on a PR (#133). Press `space` then `p` to open a popup that
lists the PRs being resolved and tails the selected one's transcript (its
`.copilot-loop/logs/pr-<n>-…log`); when several resolve at once, `j`/`k` switch
between them, and `Esc` (or `p`/`q`) closes it (#143).

Press `space` then `m` to open a popup and pick which model the background loop runs on
(`j`/`k` to move, `Enter` to select, `Esc` to cancel). The choice is forwarded to
`copilot-loop.sh` as `--model` for workers started after that; `auto` lets Copilot
pick. The picker's list defaults to a small built-in set — override it with
`$COPILOT_MODELS` (a comma- or space-separated list).

Press `space` then `a` to toggle auto-merge (#135). When on, the loop is started with
`--auto-merge` so each PR merges without manual review (GitHub auto-merge when the
repo allows it, otherwise an immediate merge); the header shows `auto-merge: on`.
Like the model, the setting takes effect the next time the loop starts, so a
running loop keeps its behaviour until restarted.

Press `space` then `t` to open a popup listing the repository's closed issues alongside how
much each one cost to resolve. The spend is the sum of the `AI Credits` the loop
posted on the issue (its `<!-- copilot-loop:usage -->` comments), shown per row
with the grand total in the popup's title; issues closed by hand — with no
recorded spend — show a `—`. Navigate with `j`/`k`; `Esc` (or `t`/`q`) closes it
(#145).

Press `space` then `d` to open a popup with the selected issue's full details — its title,
number, author, labels, description, and the whole comment thread (each comment's
author, date, and body) — so an issue can be read without leaving the TUI. The
content is fetched fresh with `gh issue view`; scroll it with `j`/`k` (`g`/`G`
jump to top/bottom) and `Esc` (or `d`/`q`) closes it (#152).

Press `space` then `b` to open the bots popup: a list of every worker the session has
started, each showing its slot, status (`running`, `stopped`, or `failed`), and
model. Navigate with `j`/`k`; press `r` (or `Enter`) to restart the selected
stopped or failed worker in place — re-spawned with the same options it was
launched with (repo dir and forwarded loop flags such as `--model` and
`--auto-merge`) and reusing its slot, so its previous capture log is archived to
`.copilot-loop/tui/loop-<n>.log.<k>` rather than overwritten — or `R` to restart
every stopped or failed worker at once. Running workers are left untouched, and
`Esc` (or `b`/`q`) closes the popup. This turns a transient failure into a one-key
restart instead of losing the worker's slot and context (#82).

```sh
cd tui
cargo run
```

Keys: `j`/`k` move, `g`/`G` jump to top/bottom, `q` (or `Esc`) quit. Press
`space` to open the issue-action menu, then: `c` create a new issue, `r` toggle
the ready label (mark ready, or remove it if already ready), `x` close the
selected issue (confirm with `y`), `d` view the selected issue's details and
comments, `l` add a background worker, `L` stop all workers, `b` bots (restart a
stopped/failed worker in place, or all with `R`), `a` toggle
auto-merge, `m` pick the model, `o` show/hide the output panel, `p` show the
resolving-PRs popup, `t` show closed issues and their cost, `f` refresh, `Esc`
cancel. In the new-issue
form: `Tab` switches fields, `Enter` adds a newline (or moves from title to
description), `Ctrl+S` creates, `Esc` cancels.


### Branch and worktree cleanup

Every issue runs on its own branch (`copilot/<n>-<slug>`) and, in worktree mode,
its own worktree. Once a PR merges these are dead weight, so each pass the loop
sweeps them: it removes any of its own local branches and worktrees whose PR has
merged and, when the repository does not delete head branches on merge, deletes
the merged remote branch too. It never touches the default branch or a branch
that still has un-pushed work. Turn the sweep off with `--no-cleanup-merged`, and
control remote-branch deletion with `--delete-remote-branch` /
`--no-delete-remote-branch` (default: auto).

### Keeping PRs mergeable

Before starting any new task, each pass the loop checks every open PR targeting
the default branch for merge conflicts. When one is found it merges the base
branch into the PR's head branch and, if that conflicts, hands the conflicted
files to Copilot to resolve, then pushes so the PR becomes mergeable again.

Only one PR is worked at a time, and a PR is *claimed* by adding the
`in-progress` label while the GitHub lock is held, so several instances running
in parallel never grab the same PR to solve. The label is removed once the
conflicts are resolved. If the loop cannot resolve a PR's conflicts it labels it
`conflict-unresolved` and leaves it alone rather than retrying forever — remove
that label by hand to let the loop try again.

### Fixing failing checks

Still before starting new work, each pass the loop also checks those open PRs for
failing CI checks. When it finds one it checks out the PR's branch and hands the
failing checks to Copilot to investigate and fix — running the build, test, or
lint commands to reproduce and verify — then commits and pushes so CI re-runs and
the PR can go green.

As with conflict resolution only one PR is fixed per pass, claimed with the
`in-progress` label under the GitHub lock so parallel instances never grab the
same PR. Conflicts are handled first, so a conflicting PR is never picked up for a
check fix. Checks that are still running or already passing are ignored, so the
loop never interrupts in-flight CI. A PR whose checks Copilot cannot fix (it makes
no changes, or the push fails) is labelled `checks-unresolved` and left alone
rather than retried forever — remove that label by hand to let the loop try again.

### Syncing with the remote

Before starting any new work each pass, the loop syncs the local default branch
with the remote so new tasks branch from the latest baseline. A clean update is a
fast-forward. If the local default branch has *diverged* from the remote (it
carries local commits that conflict with what landed upstream), the loop merges
the remote in and, when that conflicts, hands the conflicted files to Copilot to
resolve so it can move forward instead of stalling on a stale branch. The
resolved merge is kept **local only** — the loop never pushes the default branch
(pull requests do that). A divergence Copilot cannot resolve is left untouched
and not re-tried until either side moves, so it never loops forever. Turn the
whole step off with `SYNC_REMOTE=0`.

This runs for every loop instance, including the ones the TUI starts, since the
TUI drives the same `copilot-loop.sh`.

## Flags and environment variables

Every option can be set as a command-line flag or via the matching environment
variable; when both are given, the flag wins. The commonly used ones:

| Flag | Env var | Purpose |
|------|---------|---------|
| `--trigger-label <label>` | `TRIGGER_LABEL` | Label marking an issue ready (default: `ready`) |
| `--sleep-minutes <n>` | `SLEEP_MINUTES` | Idle sleep when no work (default: 5) |
| `--repo-dir <dir>` | `REPO_DIR` | Repository to operate in |
| `--model <model>` | `COPILOT_MODEL` | Model passed to `copilot --model` |
| `--copilot-timeout <dur>` | `COPILOT_TIMEOUT` | Wall-clock limit for each Copilot run so a stuck run cannot block the loop; seconds or an `s`/`m`/`h`/`d` suffix (`30m`), `0`/`off` disables (default: `30m`) |
| `--commit-model <model>` | `COMMIT_MODEL` | Model that writes the commit message |
| `--triage-model <model>` | `TRIAGE_MODEL` | Cheap model that classifies each issue |
| `--triage-map <map>` | `TRIAGE_MAP` | `class=model` pairs mapping difficulty to model |
| `--issues-dir <dir>` | `ISSUES_DIR` | Folder scanned for issue markdown files |
| `--quiet` | `QUIET` | Log only to files, do not stream to stdout |
| `--worktrees` / `--no-worktrees` | `USE_WORKTREES` | Per-issue worktrees (default: on) |
| `--auto-merge` / `--no-auto-merge` | `AUTO_MERGE` | Merge each PR automatically |
| `--merge-method <method>` | `MERGE_METHOD` | `merge`, `squash`, or `rebase` |
| `--cleanup-merged` / `--no-cleanup-merged` | `CLEANUP_MERGED` | Sweep merged branches/worktrees each pass (default: on) |
| `--delete-remote-branch` / `--no-delete-remote-branch` | `DELETE_REMOTE_BRANCH` | Delete a merged issue's remote branch (default: auto) |

Env-only settings: `SELF_UPDATE` (set to `0` to stop the loop pulling and
re-execing itself when the script changes upstream) and `SYNC_REMOTE` (set to
`0` to stop the loop syncing the local default branch with the remote before each
pass).

Run `./copilot-loop.sh --help`, or read the header of
[`copilot-loop.sh`](./copilot-loop.sh), for the complete and authoritative list.

## The `issues/` markdown workflow

You can queue work as markdown files instead of creating issues by hand. At the
start of each iteration the loop turns every markdown file in `issues/` into a
GitHub issue, then deletes the file.

1. Copy [`issues/TEMPLATE.md`](./issues/TEMPLATE.md) to a new file ending in
   `.md`.
2. The first `# ` heading becomes the issue title; everything below it becomes
   the body.
3. The loop opens the issue (labelled `ready` by default) and removes the file.

Directives you can add on their own line in the file body:

- **`Label: <label>`** — file the issue with `<label>` instead of `ready`. Use
  `Label: none` for an unlabelled backlog item the loop leaves alone, or
  `Labels: bug, enhancement` to apply several.
- **`Wait for: #N`** — hold this issue until issue `#N` is closed. List several
  with `Wait for: #1, #2`. **`Depends on:`** and **`Blocked by:`** are accepted
  aliases. While an issue waits on a still-open dependency it is labelled
  `pending`.

## Lifecycle states

Each issue moves through these labels:

| Label | Meaning |
|-------|---------|
| `ready` | Trigger label — queued and waiting to be picked up (this is the default; configurable via `--trigger-label`). |
| `pending` | Held back because it declares a still-open dependency (`Wait for: #N`). Cleared once every dependency closes. |
| `in-progress` | Claimed by a loop instance and being worked on. |
| `needs-info` | Copilot asked a question; waiting for a human reply. A reply resumes the issue. |
| `copilot-done` | Resolved successfully and a PR was opened. |
| `copilot-failed` | Failed; the loop does not retry automatically. A later human reply resumes it for another attempt. |

## Cost tracking

After every Copilot run the loop posts what that prompt cost as a comment on the
issue (or PR, for conflict resolution). The comment carries the `AI Credits` and
`Tokens` summary Copilot prints at the end of a run, taken from the run's log,
and is tagged with a hidden `<!-- copilot-loop:usage -->` marker so the cost
comments are easy to spot and filter in the thread:

```
**copilot-loop usage** (model: claude-opus-4.5)

AI Credits 25.7 (8s)
Tokens     ↑ 40.2k (40.2k written) • ↓ 221 (217 reasoning)
```

It is best-effort: when the log holds no usage stats nothing is posted, and it
never fails or blocks a run.

## Troubleshooting

**The loop starts but never picks up any issues (just keeps logging "no ready
issues; sleeping").** This almost always means `gh` is not authenticated for the
account or host that owns the target repo. `gh auth status` passing is not
enough — this machine may be logged in to several hosts at once (e.g. a personal
`github.com` account plus one or more enterprise hosts), and the account that
resolves for the repo's host may have no access, or the repo's host may not be
logged in at all (for example when `origin` points at a GitHub Enterprise host
or an SSH host alias).

The loop now verifies this at startup: if `gh` cannot see the repo it exits
immediately with a `FATAL: gh cannot access this repository` message that names
the origin host and the account in use. To fix it:

```sh
gh auth status                               # list the hosts/accounts you are logged in to
gh auth login --hostname your.enterprise.host   # log in to the repo's host, or
gh auth switch                               # switch to an account that can access it
```

The startup banner also prints the resolved `gh account:  <login> @ <host>`, so
you can confirm the loop is acting as the expected account on the expected host.

## Running the tests

The test suite lives in [`tests/`](./tests). Each file is a standalone bash
script that extracts helpers from `copilot-loop.sh`, mocks `gh`, and runs
without touching GitHub. Run one:

```sh
bash tests/wait-for.test.sh
```

Run them all:

```sh
for t in tests/*.test.sh; do bash "$t"; done
```
