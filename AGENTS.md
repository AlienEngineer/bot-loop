# bot-loop

Autonomous software dev system. Pull GitHub issues labeled `ready`, hand each to GitHub Copilot CLI to resolve, open PRs auto. Unattended backlog worker, run many instances parallel.

## Architecture

**Two commands:**
- `bot-loop` (or `copilot-loop-tui.sh`) — Terminal UI (Rust/ratatui). Browse issues, start background workers, watch cost.
- `bot-loop-bash` (or `copilot-loop.sh`) — Raw autonomous bash loop. Run inside target repo.

**Flow per iteration:**
1. Sync markdown files in `issues/` → GitHub issues
2. Sync local default branch w/ remote (Copilot resolve conflicts if diverged)
3. Check open PRs for conflicts → Copilot resolve → push
4. Check open PRs for failing CI → Copilot fix → push
5. Pick next issue (GitHub lock prevent race):
   - Resume `needs-info` or `copilot-failed` if human replied
   - Draft plan for `plan`-labeled issues (read-only, no code)
   - Oldest `ready` issue (respect deps: `Wait for: #N`)
6. Claim issue (add `in-progress`, remove trigger label atomically)
7. Create branch `copilot/<n>-<slug>` in fresh worktree (isolate parallel runs)
8. Run `copilot -p` with issue thread as context
   - Triage cheap model classify issue → pick model from map
   - Quality assurance on (default): add user-perspective tests
9. Copilot need info → post question, label `needs-info`, wait for reply (no PR)
10. Else commit (cheap model write message), sync with default, push, open PR
11. Label issue `copilot-done` or `copilot-failed`
12. Post usage cost as comment on issue/PR
13. Sleep 5m (configurable), repeat

## Key Files and Directories

```
copilot-loop.sh            Main bash loop (~5800 lines, all logic)
copilot-loop-tui.sh        Bash TUI wrapper (spawns Rust TUI)
tui/                       Rust TUI (ratatui)
  src/main.rs              Entry point
  src/app.rs               Core state machine
  src/github.rs            gh CLI wrapper
  src/runner.rs            Loop worker management
  src/ui.rs                Rendering and keybinds
issues/                    Markdown → GitHub issues
  TEMPLATE.md              Issue template
tests/                     Bash integration tests
  run-all.sh               Test runner
Formula/bot-loop.rb        Homebrew formula
.github/workflows/         CI (shellcheck + test suite for bash, fmt/clippy/test for Rust)
.copilot-loop/             Runtime state (logs, GitHub lock, worktrees)
```

## Build, Test, Lint

**Bash loop:**
```sh
shellcheck copilot-loop.sh copilot-loop-tui.sh tests/*.sh
tests/run-all.sh                    # Runs all tests/*.test.sh
```

**Rust TUI:**
```sh
cd tui
cargo fmt --check                   # Format check
cargo clippy --all-targets -- -D warnings
cargo test
cargo build --release               # Binary: target/release/copilot-loop-tui
```

No package manager. Bash scripts run direct. Rust build to `tui/target/`.

## Conventions

**Branch names:** `copilot/<issue-number>-<slug>`  
**Worktrees:** Each issue run in own worktree (disable: `--no-worktrees`)  
**Lock file:** `.copilot-loop/github.lock` prevent multi-instance races  
**Log files:** `.copilot-loop/logs/issue-<n>-*.log` and `pr-<n>-*.log`

**Issue lifecycle labels:**
- `ready` — trigger label (configurable: `--trigger-label`)
- `plan` — draft implementation plan first (read-only pass)
- `plan-review` — plan posted, await approval (add `ready` to run)
- `pending` — wait for dependency (`Wait for: #N` in body)
- `in-progress` — claimed by loop instance
- `needs-info` — Copilot asked question, await human reply
- `copilot-done` — resolved, PR opened
- `copilot-failed` — failed, no auto-retry (human reply resumes)
- `conflict-unresolved` — PR conflict Copilot can't fix
- `checks-unresolved` — PR failing checks Copilot can't fix

**Issue markdown directives** (in `issues/*.md` files):
```markdown
Label: bug                          # Override default `ready` label
Labels: bug, enhancement            # Multiple labels
Label: none                         # No label (backlog item)
Wait for: #1, #2                    # Block until #1 and #2 close
Depends on: #3                      # Alias for Wait for
Blocked by: #4                      # Alias for Wait for
```

**Models:**
- `--model` / `COPILOT_MODEL` — default coding model (triage off)
- `--commit-model` / `COMMIT_MODEL` — cheap model, commit messages
- `--triage-model` / `TRIAGE_MODEL` — cheap model classify issue complexity
- `--triage-map` / `TRIAGE_MAP` — map difficulty class to model (e.g., `trivial=gpt-4o-mini,complex=claude-opus-4`)
- `--cost-saver` / `COST_SAVER` — preset that enables triage with built-in defaults (trivial→cheap, normal→mid, complex→`--model`/strong); explicit `--triage-model`/`--triage-map` override it
- `--agents-model` / `AGENTS_MODEL` — model for AGENTS.md bootstrap (default: `claude-sonnet-4.5`)

**Quality assurance:** On by default. Copilot add user-perspective tests. Disable: `--no-quality-assurance` / `--no-qa`

**Auto-merge:** Off by default. Enable: `--auto-merge` (use GitHub auto-merge or immediate merge)

**Merge methods:** `--merge-method merge|squash|rebase` (default: repo setting)

**Self-update:** Loop pull + re-exec itself when script change upstream. Disable: `SELF_UPDATE=0`

**Sync remote:** Loop sync default branch w/ remote before each pass. Disable: `SYNC_REMOTE=0`

**Cleanup:** Loop remove merged branches/worktrees each pass. Disable: `--no-cleanup-merged`

## Critical Constraints

- **Never push to default branch.** All work on `copilot/<n>-*` branches.
- **Never touch files outside repo.** File access limited to repo root.
- **Git worktrees isolate runs.** Parallel instances never conflict (unless `--no-worktrees`).
- **GitHub lock is atomic.** Claim add `in-progress` + remove trigger label in one gh call.
- **Failures never auto-retry.** `copilot-failed` issues wait human guidance.
- **Dependencies block planning + execution.** Issue with `Wait for: #1` held until #1 closes.

## Dependencies

- `gh` (authed for target repo)
- `copilot` (GitHub Copilot CLI, on PATH)
- `git`
- Rust toolchain (TUI only)

## Common Operations

**Run loop directly:**
```sh
./copilot-loop.sh                   # In target repo
./copilot-loop.sh --trigger-label todo --sleep-minutes 10
```

**Run TUI:**
```sh
./copilot-loop-tui.sh               # In target repo
# Or after Homebrew install:
bot-loop
```

**Parallel instances with worktrees:**
```sh
# Terminal 1 — main tree
./copilot-loop.sh

# Terminal 2 — second worktree
git worktree add ../instance-2
cd ../instance-2
./copilot-loop.sh
```

**Queue issue from markdown:**
```sh
cp issues/TEMPLATE.md issues/my-task.md
# Edit issues/my-task.md (first # heading = title, rest = body)
# Loop converts it to GitHub issue on next pass
```

**Check logs:**
```sh
tail -f .copilot-loop/logs/issue-<n>-*.log
tail -f .copilot-loop/logs/pr-<n>-*.log
```
