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
- `gh` — the GitHub CLI, authenticated (`gh auth login`)
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

When the repo is used with worktrees, each issue automatically runs in its own
worktree so the shared checkout is never touched. Force this on or off with
`--worktrees` / `--no-worktrees`.

There is also an optional terminal UI, [`copilot-loop-tui.sh`](./copilot-loop-tui.sh),
that spawns, monitors, and stops several loop instances ("bots") side by side.

## Flags and environment variables

Every option can be set as a command-line flag or via the matching environment
variable; when both are given, the flag wins. The commonly used ones:

| Flag | Env var | Purpose |
|------|---------|---------|
| `--trigger-label <label>` | `TRIGGER_LABEL` | Label marking an issue ready (default: `ready`) |
| `--sleep-minutes <n>` | `SLEEP_MINUTES` | Idle sleep when no work (default: 5) |
| `--repo-dir <dir>` | `REPO_DIR` | Repository to operate in |
| `--model <model>` | `COPILOT_MODEL` | Model passed to `copilot --model` |
| `--commit-model <model>` | `COMMIT_MODEL` | Model that writes the commit message |
| `--triage-model <model>` | `TRIAGE_MODEL` | Cheap model that classifies each issue |
| `--triage-map <map>` | `TRIAGE_MAP` | `class=model` pairs mapping difficulty to model |
| `--issues-dir <dir>` | `ISSUES_DIR` | Folder scanned for issue markdown files |
| `--quiet` | `QUIET` | Log only to files, do not stream to stdout |
| `--worktrees` / `--no-worktrees` | `USE_WORKTREES` | Force per-issue worktrees on/off |
| `--auto-merge` / `--no-auto-merge` | `AUTO_MERGE` | Merge each PR automatically |
| `--merge-method <method>` | `MERGE_METHOD` | `merge`, `squash`, or `rebase` |

Env-only settings: `MAX_ATTEMPTS` (attempts per issue, default 2) and
`SELF_UPDATE` (set to `0` to stop the loop pulling and re-execing itself when the
script changes upstream).

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
| `copilot-failed` | Failed after `MAX_ATTEMPTS` attempts. A later human reply resumes it for another attempt. |

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
