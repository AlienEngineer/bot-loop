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

It opens issues from any markdown files in `issues/`, picks the oldest open
issue labelled `ready`, works it on a fresh branch, and opens a PR that closes
the issue. Press `f` while it is sleeping to wake it and check for work
immediately. Prefer to review the approach first? Label an issue `plan` and the
loop drafts an implementation plan for you to review before any code is written
(see [Plan mode](#plan-mode)).

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
key (#129): press `space` to reveal them in a which-key popup (#160), then one
key runs the action (or `Esc` cancels). Press `space` then `r` to toggle the trigger
label (`ready`, or `$TRIGGER_LABEL`) on the selected issue: it is added when
absent so the loop picks the issue up, or removed when present so a
mistakenly-queued issue can be pulled back out (#146). Marking an `in-progress`
issue ready asks for confirmation first, since the loop is already working it
(`y` confirms, `n`/`Esc` cancels) (#173). Press `space` then `c` to create a new issue: fill in a title and description, then
`Ctrl+S` to submit it (no label is added by default). Press `space` then `x` to close the
selected issue: a confirmation popup names it (and whether a summary will be
posted), then `y` closes it on GitHub (`n`/`Esc` cancels), and — unless the
summary is turned off — a short recap of what the loop did is posted as a comment
(#161, see below). Press `space` then `l` to start a background `copilot-loop.sh` worker
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

Press `space` then `q` to toggle quality assurance (#162). It is **on by default**: the
loop asks Copilot to add tests for the work it did on each issue, written from the
user's perspective (dropping to technical/unit tests only when a user-level test
is impractical). The header shows `qa: on`/`qa: off`; turning it off starts the loop
with `--no-quality-assurance` to save cost. Like auto-merge, the setting takes effect
the next time the loop starts.

Press `space` then `s` to toggle the closing summary (#161). When on (the default),
closing an issue posts a comment recapping what the loop did: a *light* model reads
the tail of that issue's session log (its `.copilot-loop/logs/issue-<n>-…log`) and
writes a short Markdown summary, which is posted with `gh issue comment`. The header
shows `summary: on`/`off` and the close confirmation says whether a summary will be
posted. It runs on a background thread so the model call never freezes the UI, and
issues with no session log (e.g. closed by hand) are skipped. The summary model is a
cheap default (`gpt-5-mini`) to keep costs down — override it with `$SUMMARY_MODEL`
(`auto`/`off` lets Copilot pick), and set `$SUMMARY_ON_CLOSE=off` to start with the
summary disabled.

Press `space` then `t` to open a popup listing the repository's closed issues alongside how
much each one cost to resolve. The spend is the sum of the `AI Credits` the loop
posted on the issue (its `<!-- copilot-loop:usage -->` comments), shown per row
with the grand total in the popup's title; issues closed by hand — with no
recorded spend — show a `—`. Navigate with `j`/`k`; `Esc` (or `t`/`q`) closes it
(#145).

Press `space` then `$` to open the cost dashboard: a monitor of spend over time (#163).
It pulls every issue (open and closed) with its `AI Credits` usage comments and,
for the current month, shows three things at the top — the total spent this
month, how many issues were worked, and the average cost per issue — plus the
costliest day. Below that are two by-day bar charts spanning the whole month
(day-of-month on X): spend per day, and the number of issues worked per day, so
you can see the shape of the spend at a glance. `Esc` (or `$`/`q`) closes it.

Press `space` then `d` to open a popup with the selected issue's full details — its title,
number, author, labels, description, and the whole comment thread (each comment's
author, date, and body) — so an issue can be read without leaving the TUI. The
content is fetched fresh with `gh issue view`; scroll it with `j`/`k` (`g`/`G`
jump to top/bottom) and `Esc` (or `d`/`q`) closes it (#152).

Press `space` then `i` to reply to a Copilot question straight from the TUI (#165).
When Copilot needs more information it posts the question on the issue and labels
it `needs-info`; those issues carry a magenta `?` marker in the list so a pending
question is easy to spot. The popup shows Copilot's question (fetched fresh with
`gh issue view`) above a text field for your answer: type your reply, `↑`/`↓`
scroll a long question, `Enter` inserts a newline, `Ctrl+S` posts the reply as an
issue comment, and `Esc` cancels. A running loop then resumes the issue on its
next pass — it picks a `needs-info` issue back up once the latest comment is not
its own — so the reply alone unblocks it and no label needs changing by hand.

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

Feedback messages appear on their own line just above the keybinds, so a status
never crowds the bindings. Press `space` then `M` to open the messages popup: a
scrollable log of the latest messages the TUI reported, newest first, so a status
that scrolled past on the message line can be read back. Navigate with `j`/`k`
(`g`/`G` jump to the newest/oldest), and `Esc` (or `M`/`q`) closes it (#182).

```sh
cd tui
cargo run
```

Keys: `j`/`k` move, `g`/`G` jump to top/bottom, `q` (or `Esc`) quit — which asks
for confirmation first (`y` quits, `n`/`Esc` cancels) so a stray key does not drop
you out of the TUI (#167). Press
`space` to open the issue-action menu, then: `c` create a new issue, `r` toggle
the ready label (mark ready, or remove it if already ready; marking an
`in-progress` issue ready confirms first), `x` close the
selected issue (confirm with `y`), `d` view the selected issue's details and
comments, `i` reply to a Copilot question (`needs-info` issues), `l` add a
background worker, `L` stop all workers, `b` bots (restart a
stopped/failed worker in place, or all with `R`), `M` show the messages popup (a
log of the latest feedback), `a` toggle
auto-merge, `q` toggle quality assurance, `s` toggle the closing summary, `m` pick
the model, `o` show/hide the output panel, `p` show the resolving-PRs popup, `t`
show closed issues and their cost, `$` open the cost dashboard, `f` refresh, `Esc`
cancel. In the new-issue
form: `Tab` switches fields, `Enter` adds a newline (or moves from title to
description), `Ctrl+S` creates, `Esc` cancels. In the reply popup: `↑`/`↓`
scroll the question, `Enter` adds a newline, `Ctrl+S` sends, `Esc` cancels.


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

### AGENTS.md bootstrap

Every issue runs in a fresh Copilot session with no memory, so without repo-level
context the agent re-discovers the layout, build/test commands and conventions on
**every** run — repeated input-token cost across the whole backlog. To front-load
that context, the first time the loop starts against a repo that has **no**
`AGENTS.md` and **no** `.github/copilot-instructions.md`, it runs a single
read-only Copilot pass that writes a **short** `AGENTS.md` (architecture, where
things live, build/test/lint commands, conventions) and opens it as its own PR.
Copilot CLI auto-loads `AGENTS.md` into every later run, so future runs — and
humans — start with that context instead of rediscovering it.

The file is kept deliberately short: it is loaded into every run, so bloat becomes
a fixed per-run cost. If the repo already has either file, the step does nothing,
and once the bootstrap branch is on the remote it is never opened twice. Because it
runs once per repo and pays off on every later run, it uses a capable mid model by
default (`--agents-model` / `AGENTS_MODEL`, default `claude-sonnet-4.5`; set to `off`
to disable). The whole step is time-boxed by `--copilot-timeout` and fully
failure-safe — a failed or empty generation is logged and skipped, never blocking
issue work.

## Flags and environment variables

Every option can be set as a command-line flag or via the matching environment
variable; when both are given, the flag wins. The commonly used ones:

| Flag | Env var | Purpose |
|------|---------|---------|
| `--trigger-label <label>` | `TRIGGER_LABEL` | Label marking an issue ready (default: `ready`) |
| `--plan-label <label>` | `PLAN_LABEL` | Label that puts an issue into [plan mode](#plan-mode): Copilot drafts a plan for review before any code is written (default: `plan`) |
| `--sleep-minutes <n>` | `SLEEP_MINUTES` | Idle sleep when no work (default: 5) |
| `--repo-dir <dir>` | `REPO_DIR` | Repository to operate in |
| `--model <model>` | `COPILOT_MODEL` | Model passed to `copilot --model` |
| `--copilot-timeout <dur>` | `COPILOT_TIMEOUT` | Wall-clock limit for each Copilot run so a stuck run cannot block the loop; seconds or an `s`/`m`/`h`/`d` suffix (`30m`), `0`/`off` disables (default: `30m`) |
| `--commit-model <model>` | `COMMIT_MODEL` | Model that writes the commit message |
| `--triage-model <model>` | `TRIAGE_MODEL` | Cheap model that classifies each issue and asks the author to clarify vague ones |
| `--triage-map <map>` | `TRIAGE_MAP` | `class=model` pairs mapping difficulty to model |
| `--agents-model <model>` | `AGENTS_MODEL` | Model for the one-time [AGENTS.md bootstrap](#agentsmd-bootstrap) (default: `claude-sonnet-4.5`; `off` disables) |
| `--issues-dir <dir>` | `ISSUES_DIR` | Folder scanned for issue markdown files |
| `--quiet` | `QUIET` | Log only to files, do not stream to stdout |
| `--worktrees` / `--no-worktrees` | `USE_WORKTREES` | Per-issue worktrees (default: on) |
| `--auto-merge` / `--no-auto-merge` | `AUTO_MERGE` | Merge each PR automatically |
| `--quality-assurance` / `--no-quality-assurance` | `QUALITY_ASSURANCE` | Ask Copilot to add user-perspective tests for each issue (default: on; `--qa`/`--no-qa` aliases) |
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
| `plan` | Plan mode — the loop drafts an implementation plan for review before writing any code (configurable via `--plan-label`). See [Plan mode](#plan-mode). |
| `plan-review` | A plan was posted; waiting for the user to review it and add the trigger label to run it. |
| `pending` | Held back because it declares a still-open dependency (`Wait for: #N`). Cleared once every dependency closes. |
| `in-progress` | Claimed by a loop instance and being worked on. |
| `needs-info` | Copilot asked a question; waiting for a human reply. Reply from the TUI with `space` then `i`, or comment on the issue; a reply resumes it. |
| `copilot-done` | Resolved successfully and a PR was opened. |
| `copilot-failed` | Failed; the loop does not retry automatically. A later human reply resumes it for another attempt. |

## Plan mode

For a bigger or riskier change you can have the loop propose a plan and let you
review it *before* any code is written. Label an issue `plan` (configurable via
`--plan-label` / `PLAN_LABEL`) instead of `ready`:

1. The loop picks up the `plan`-labelled issue and runs Copilot in a read-only
   planning pass — it investigates the repository but makes **no code changes**.
2. Copilot's implementation plan is posted as a comment on the issue, and the
   issue is relabelled `plan-review`. The loop then leaves it alone.
3. You review the plan. To adjust it, leave a comment with your changes — the
   **most recent** plan in the thread is the one that gets executed.
4. When you're happy, add the trigger label (`ready`) to the issue. The loop
   picks it up, follows the approved plan, and opens a PR as usual.

Nothing is committed or pushed during planning, so a plan costs only the one
Copilot run (tracked like any other — see below). An issue that lists a
dependency (`Wait for: #N`) is held back from planning until its blockers close,
exactly like a ready issue.

## Cost tracking

After every Copilot run the loop posts what that prompt cost as a comment on the
issue (or PR, for conflict resolution). The comment carries the `AI Credits` and
`Tokens` summary Copilot prints at the end of a run, taken from the run's log,
and is tagged with a hidden `<!-- copilot-loop:usage -->` marker so the cost
comments are easy to spot and filter in the thread:

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
brew tap alienengineer/bot-loop
brew install bot-loop
```

Homebrew installs a prebuilt universal (arm64 + x86_64) macOS binary and pulls in
`git` and `gh`, but not `copilot` — install that separately.
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
   Unless disabled, Copilot also adds tests from the user's perspective. When
   triage is on, the cheap model first checks the issue is specified well enough;
   a genuinely vague one is asked a clarifying question (labelled `needs-info`)
   and skips the coding run (asked at most once, biased toward proceeding).
9. If Copilot needs more info, posts the question, labels the issue `needs-info`,
   and waits. Otherwise commits, rebases the branch onto the latest default
   branch — handing any rebase conflicts to Copilot to resolve rather than
   failing the issue (#193) — then pushes and opens a PR that closes the issue
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
| `--triage-model <model>` | `TRIAGE_MODEL` | `off` | Cheap model that classifies each issue as trivial/normal/complex before coding, so the coding model can be chosen per difficulty. The same model also checks whether the issue is specified well enough: a genuinely vague one is asked a clarifying question (labelled `needs-info`) and gets no coding run — asked at most once and biased toward proceeding. `off` disables triage. |
| `--triage-map <map>` | `TRIAGE_MAP` | unset | Comma-separated `class=model` pairs mapping a triage class to the coding model, e.g. `trivial=gpt-5-mini,complex=claude-opus-4.5`. An unmapped class falls back to `--model`. |
| `--agents-model <model>` | `AGENTS_MODEL` | `claude-sonnet-4.5` | Model for the one-time [AGENTS.md bootstrap](#agentsmd-bootstrap). Runs once per repo (high-leverage), so it defaults to a capable mid model rather than the cheapest. `off` disables the bootstrap. |
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
