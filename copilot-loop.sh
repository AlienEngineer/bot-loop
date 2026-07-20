#!/usr/bin/env bash
#
# copilot-loop.sh
#
# Autonomous loop that pulls labelled GitHub issues and hands each one to the
# GitHub Copilot CLI to resolve, then opens a pull request. When no work is
# available it sleeps and checks again.
#
# MULTI-INSTANCE SUPPORT: Multiple instances of this script can run concurrently
# without interfering with each other. Each instance will work on a different issue,
# and synchronization is handled via a GitHub lock file (.copilot-loop/github.lock)
# that protects issue selection and claiming operations. This allows you to:
# - Run multiple instances on the same machine (with different REPO_DIR)
# - Run multiple instances in parallel for the same repository
# - Use git worktrees for each instance to avoid file system conflicts
#
# Example multi-instance setup with worktrees:
#   # Main working tree
#   ./copilot-loop.sh
#
#   # In another terminal, create a worktree and run another instance:
#   git worktree add ../instance-2
#   cd ../instance-2
#   ./copilot-loop.sh
#
# Before each iteration the loop keeps itself current: it pulls the default
# branch and, if this script changed upstream, re-execs so the loop always runs
# the latest code. Set SELF_UPDATE=0 to turn this off.
#
# Flow per iteration:
#   0. Turn any markdown files in issues/ into GitHub issues (labelled with the
#      trigger label, or per a "Label:" directive in the file) so file-based
#      tasks enter the queue below.
#   0b. Sync the local default branch with origin/<default> so the loop's
#      baseline matches the remote before any work. A clean update fast-forwards;
#      when the local default branch has diverged and the merge conflicts, the
#      conflicts are handed to Copilot to resolve so the loop can move forward
#      (the resolved merge is kept local, never pushed). Set SYNC_REMOTE=0 to
#      turn this off (see the "sync-default helpers").
#   1. Before starting any new task, check open PRs targeting the default branch
#      for merge conflicts. GitHub computes mergeability asynchronously, so the
#      loop first waits (bounded) for any PR still reported UNKNOWN to be
#      evaluated, then — if a PR is conflicting — merges the base branch into it
#      and lets Copilot resolve the conflicts, then pushes, so PRs stay mergeable.
#   1b. Still before starting new work, check those open PRs for failing CI checks
#      and, when one is found, hand its failing checks to Copilot to fix on the PR
#      branch, commit and push so CI re-runs. Only one PR is fixed per pass; a PR
#      Copilot cannot fix is labelled "checks-unresolved" so it is not retried
#      forever. Conflicts are handled first, so a conflicting PR is never grabbed
#      here (see the "failing-checks-pr helpers").
#   2. Pick the next issue to work on (protected by GitHub lock):
#        a. an issue awaiting a reply ("needs-info") or a failed issue
#           ("copilot-failed") whose latest comment came from a human (the user
#           answered a question or gave more guidance) -> resume it; else
#        b. the oldest open issue with the trigger label (default: "ready").
#      Issues that declare a dependency ("Wait for: #N" in the body) are held
#      back (and labelled "pending" while they wait) until every issue they name
#      is closed (see "Issue dependencies: Wait for: #N" further down).
#   3. Claim it: add "in-progress", remove the trigger/"needs-info" labels
#      (done atomically by the claiming functions to prevent race conditions).
#   4. Create a fresh branch for the issue, based on the latest default branch.
#      The default branch (main/master) is never checked out for the work; by
#      default each issue also runs in its own git worktree (a different folder)
#      so the shared checkout is left untouched (disable with --no-worktrees).
#   5. Run `copilot -p` (all tools, file access restricted to this repo),
#      passing the issue's comment thread so any prior Q&A is available. When
#      triage is enabled (TRIAGE_MODEL) the issue is first classified by that
#      cheap model as trivial/normal/complex and the coding model is picked from
#      TRIAGE_MAP, so cheap issues run on a cheap model; any failure falls back
#      to the global COPILOT_MODEL. Unless quality assurance is disabled
#      (QUALITY_ASSURANCE=0 / --no-quality-assurance) the prompt also asks Copilot
#      to add tests for the work, written from the user's perspective.
#   5b. Right after the run, post what that prompt cost (the "AI Credits" and
#      "Tokens" summary Copilot prints at the end, taken from the run's log) as a
#      comment on the issue/PR, tagged with the hidden "copilot-loop:usage"
#      marker. This is best-effort: it is skipped when no stats were captured and
#      never fails the run. The same happens after the conflict-resolution run in
#      resolve_pr_conflicts, so every prompt's cost is tracked.
#   6a. If Copilot needs more information it writes a question file; post the
#       question as an issue comment, label the issue "needs-info", and wait for
#       the user to reply (no PR opened, not counted as a failure).
#   6b. Otherwise stage and commit the work (the commit message is written from
#       the staged diff by the cheapest model, COMMIT_MODEL, with a deterministic
#       fallback). The commit must succeed, so a commit failure fails the issue
#       loudly instead of silently opening an empty PR. Then sync the branch with
#       the latest default branch and, only if commits remain after the sync,
#       push and open a PR that closes the issue. When --auto-merge is on the PR
#       is set to merge automatically (GitHub auto-merge when the repo allows it,
#       otherwise merged immediately) so no manual review is required.
#   7. On success label the issue "copilot-done". On failure label it
#      "copilot-failed" and stop — failures are never retried automatically. A
#      later user reply on a failed issue resumes it for another attempt.
#   8. Sweep merged branches: each pass removes any local work branch and worktree
#      whose PR has merged and, when the repo does not auto-delete on merge,
#      deletes the merged remote branch too (CLEANUP_MERGED / DELETE_REMOTE_BRANCH).
#      Only the loop's own branches are touched, never the default branch or a
#      branch with un-pushed work.
#   9. If no issues are found, sleep and repeat. While sleeping, press 'f' to
#      wake immediately and check for work.
#
# Requirements: git, gh (authenticated), copilot.
#
# Usage:
#   ./copilot-loop.sh [options]
#
# Options (each is also settable via the matching environment variable; when
# both are given the command-line flag wins):
#   --trigger-label <label>  Label that marks an issue as ready   (default: ready)
#   --sleep-minutes <n>      Idle sleep, minutes, when no work     (default: 5)
#   --repo-dir <dir>         Repository to operate in              (default: current git repo)
#   --model <model>          Model passed to copilot --model       (default: unset/auto)
#   --copilot-timeout <dur>  Wall-clock limit for each Copilot run (issue resolve,
#                            PR conflict/checks fix, default-branch sync) so a stuck
#                            run cannot block the loop. Accepts seconds or an
#                            s/m/h/d suffix (e.g. 1800, 30m, 2h); "0"/"off" disables
#                            it                                      (default: 30m)
#   --commit-model <model>   Model used to write the commit message from the
#                            staged diff; unset/"off" uses a deterministic
#                            "Resolve #<n>: <title>" message        (default: off)
#   --triage-model <model>   Cheap model that classifies each issue as
#                            trivial/normal/complex before coding, so the coding
#                            model can be chosen per difficulty; unset/"off"
#                            disables triage (current behaviour)     (default: off)
#   --triage-map <map>       class=model pairs (comma-separated) mapping a triage
#                            class to the coding model, e.g.
#                            "trivial=gpt-5-mini,complex=claude-opus-4.5"; an
#                            unmapped class falls back to --model. Defaults to
#                            "trivial=<triage-model>" when triage is on and this
#                            is unset                                (default: unset)
#   --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
#   --quiet                  Do not stream Copilot's output to stdout; write it
#                            only to the per-run log files (the original
#                            behaviour). By default the loop streams Copilot's
#                            output live to stdout as well as the log files.
#   --worktrees / --no-worktrees
#                            Give each issue its own git worktree, or work in the
#                            current checkout (default: on — every task uses a new
#                            worktree so parallel runs never conflict).
#   --auto-merge / --no-auto-merge
#                            Merge each PR automatically instead of leaving it for
#                            review (default: off).
#   --quality-assurance / --no-quality-assurance
#                            Ask Copilot to add tests (from the user's perspective)
#                            for the work it did on each issue; disable to save cost
#                            (default: on). --qa / --no-qa are accepted aliases.
#   --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
#                            (default: merge).
#   --cleanup-merged / --no-cleanup-merged
#                            Sweep merged issue branches and worktrees each pass
#                            (default: on).
#   --delete-remote-branch / --no-delete-remote-branch
#                            Delete a merged issue's remote branch (default: auto,
#                            on only when the repo does not auto-delete on merge).
#   -h, --help               Show help and exit.
#   -V, --version            Print the copilot-loop version and exit.
#
# Environment variables (equivalent to the flags above):
#   TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COPILOT_TIMEOUT,
#   COMMIT_MODEL, TRIAGE_MODEL, TRIAGE_MAP, ISSUES_DIR, QUIET, USE_WORKTREES,
#   AUTO_MERGE, QUALITY_ASSURANCE, MERGE_METHOD, CLEANUP_MERGED, DELETE_REMOTE_BRANCH
# Plus SELF_UPDATE (env-only, no flag): set to 0 to stop the loop pulling the
# default branch and restarting when this script changes upstream (default:
# auto, on when the script is tracked in the repo it operates on).
# Plus SYNC_REMOTE (env-only, no flag): set to 0 to stop the loop syncing the
# local default branch with the remote before each pass; on by default (see the
# flow's step 0b — a diverged merge conflict is handed to Copilot to resolve).
# Plus MERGEABILITY_WAIT_ATTEMPTS / MERGEABILITY_WAIT_SECONDS (env-only): bound
# the wait for GitHub to finish computing PR mergeability before the conflict
# check, so a still-UNKNOWN (not yet evaluated) conflict is not skipped. Defaults
# 5 attempts, 3s apart; set MERGEABILITY_WAIT_ATTEMPTS=0 to disable the wait.
#
set -uo pipefail

# Version of this script. Reported by -V/--version and bumped automatically by
# .github/workflows/release.yml on every push to main (kept in step with the
# Homebrew formula and the TUI). Keep this on its own line: the release workflow
# rewrites it with sed.
COPILOT_LOOP_VERSION="0.1.0"

# Preserve the original invocation so self-update can re-exec the loop with the
# same options after pulling a newer copy of this script (see self_update).
SELF_ARGS=("$@")

# Resolve this script to an absolute, symlink-free path now, before any later cd
# changes the working directory. self_update() compares this file against its
# upstream copy and overwrites it in place, so it must point at the real tracked
# file even when invoked via a relative path or a symlink on PATH.
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  _link="$(readlink "$SCRIPT_PATH")"
  case "$_link" in
    /*) SCRIPT_PATH="$_link" ;;
    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$_link" ;;
  esac
done
SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/$(basename "$SCRIPT_PATH")"

# --- Configuration -----------------------------------------------------------
# Every option below can be supplied two ways: as an environment variable, or as
# a command-line flag (see --help / usage). A flag always overrides the matching
# environment variable, which overrides the built-in default. Read the raw env
# values here and fill in defaults after argument parsing, so a flag such as
# --repo-dir can still influence the derived paths (ISSUES_DIR, WORK_DIR, ...).
REPO_DIR="${REPO_DIR:-}"
TRIGGER_LABEL="${TRIGGER_LABEL:-}"
SLEEP_MINUTES="${SLEEP_MINUTES:-}"
COPILOT_MODEL="${COPILOT_MODEL:-}"
# Wall-clock limit for each main Copilot run so a stuck run can never block the
# loop. Read raw here; normalised (to a timeout(1) duration, or empty=disabled)
# after argument parsing so a flag can still override it. Default 30m; "0"/"off"
# disables it.
COPILOT_TIMEOUT="${COPILOT_TIMEOUT:-}"
# Model used *only* to write the commit message from the staged diff. Kept
# separate from COPILOT_MODEL so the coding model is never spent on a commit
# message. Off by default (deterministic message); set a model such as the cheap
# gpt-5-mini to have the message written from the diff, or "off" to force the
# deterministic fallback.
COMMIT_MODEL="${COMMIT_MODEL:-}"
# Optional cheap model used to CLASSIFY each issue as trivial/normal/complex
# before coding, so the expensive coding model is reserved for hard issues (the
# COMMIT_MODEL idea applied to routing). Empty/"off" disables triage and every
# issue runs on COPILOT_MODEL exactly as before.
TRIAGE_MODEL="${TRIAGE_MODEL:-}"
# Maps a difficulty class to the coding model, as comma-separated "class=model"
# pairs, e.g. "trivial=gpt-5-mini,complex=claude-opus-4.5". A class with no entry
# (or an empty value) falls back to COPILOT_MODEL. When triage is enabled but
# this is unset it defaults to routing trivial issues to TRIAGE_MODEL so turning
# triage on lowers cost with zero extra configuration.
TRIAGE_MAP="${TRIAGE_MAP:-}"
ISSUES_DIR="${ISSUES_DIR:-}"
# Stream Copilot's output live to stdout in addition to the per-run log files.
# Set QUIET=1 (or pass --quiet) to keep the original log-file-only behaviour.
QUIET="${QUIET:-}"
# When non-empty, log() also appends its line to this per-run log file, so the
# loop's own narration (branch creation, "running copilot", PR push, ...) lands
# in the same issue-<n>/pr-<n> log as Copilot's transcript. The TUI's per-issue
# output panel reads that file, so it then shows the full run — matching what the
# bash loop prints to the terminal instead of "just the copilot output" (#126).
CURRENT_RUN_LOG=""
# Set SELF_UPDATE=0 to stop the loop pulling and restarting itself when this
# script changes upstream. Left unset it is auto-enabled whenever the script is
# a tracked file inside the repo it operates on.
SELF_UPDATE="${SELF_UPDATE:-}"
# Set SYNC_REMOTE=0 to stop the loop syncing the local default branch with the
# remote before each pass. On by default; when the default branch has diverged
# and the merge conflicts, Copilot is asked to resolve it so the loop can move on.
SYNC_REMOTE="${SYNC_REMOTE:-}"
# Whether each issue gets its own git worktree instead of switching branches in
# the shared checkout. On by default so every task runs in a different folder;
# set to 0 (or pass --no-worktrees) to work in place. 1/true/yes/on force it on.
# The default branch (main/master) is never checked out for work in either mode.
USE_WORKTREES="${USE_WORKTREES:-}"
# Merge each PR automatically instead of leaving it open for review. Off by
# default; set AUTO_MERGE=1 (or pass --auto-merge) to turn it on.
AUTO_MERGE="${AUTO_MERGE:-}"
# Ask Copilot to add tests (from the user's perspective) for the work it did on
# each issue. On by default (issue #162); set QUALITY_ASSURANCE=0 (or pass
# --no-quality-assurance) to turn it off and save the extra cost.
QUALITY_ASSURANCE="${QUALITY_ASSURANCE:-}"
# Merge method used when AUTO_MERGE is on: merge, squash or rebase.
MERGE_METHOD="${MERGE_METHOD:-}"
# Delete the remote head branch of an issue once its PR merges. Empty means
# auto-detect (on only when the repository does not already delete branches on
# merge, so we complement GitHub's own cleanup instead of duplicating it); 1/0
# force it on/off.
DELETE_REMOTE_BRANCH="${DELETE_REMOTE_BRANCH:-}"
# Periodically remove local branches, worktrees and remote branches whose PR has
# merged. On by default; set to 0 (or pass --no-cleanup-merged) to disable.
CLEANUP_MERGED="${CLEANUP_MERGED:-}"
# GitHub computes a PR's mergeable state asynchronously, so just after a push or a
# base-branch move it reports UNKNOWN for a while. Before the per-iteration
# conflict check the loop waits for that computation to settle, so a PR that is
# really in conflict but not yet evaluated is not skipped. Env-only (no flag):
# MERGEABILITY_WAIT_ATTEMPTS bounds the wait (0 disables it), and
# MERGEABILITY_WAIT_SECONDS is the pause between polls.
MERGEABILITY_WAIT_ATTEMPTS="${MERGEABILITY_WAIT_ATTEMPTS:-}"
MERGEABILITY_WAIT_SECONDS="${MERGEABILITY_WAIT_SECONDS:-}"

INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
FAILED_LABEL="copilot-failed"
NEEDS_INFO_LABEL="needs-info"
# Marks an open issue held back because it declares a still-open dependency
# ("Wait for: #N"), so the wait is visible in GitHub. Reconciled every pass and
# removed once every dependency closes (or the issue is claimed for work).
PENDING_LABEL="pending"
# Marks a PR whose conflicts the loop tried and failed to resolve, so it is not
# retried forever. Remove it by hand to let the loop try again.
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
# Marks a PR whose failing CI checks the loop tried and failed to fix, so it is
# not retried forever. Remove it by hand to let the loop try again.
CHECKS_UNRESOLVED_LABEL="checks-unresolved"

# Prefix of every work branch the loop creates ("copilot/<num>-<slug>"). Used to
# recognise the loop's own branches when cleaning up so a sweep never touches the
# default branch or a branch a human created.
BRANCH_PREFIX="copilot/"

# Hidden marker appended to comments the loop posts when asking the user a
# question, so they are easy to recognise in the thread.
QUESTION_MARKER="<!-- copilot-loop:needs-info -->"

# Hidden marker appended to every failure comment so they are easy to recognise
# in the thread (mirrors QUESTION_MARKER).
FAILURE_MARKER="<!-- copilot-loop:failed -->"

# Hidden marker appended to every per-run cost/usage comment so they are easy to
# recognise (and filter) in the thread (mirrors QUESTION_MARKER).
USAGE_MARKER="<!-- copilot-loop:usage -->"

# --- Helpers -----------------------------------------------------------------
# Emit a timestamped status line to stdout. When CURRENT_RUN_LOG is set (during a
# per-issue or per-PR run) the same line is also appended to that run's log file,
# so the loop's narration is interleaved with Copilot's transcript there and the
# TUI's output panel shows the full run, not just Copilot's output (#126). The
# mirror is best-effort: a write failure never breaks the loop.
log() {
  local line
  line="$(printf '%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$line"
  if [ -n "${CURRENT_RUN_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$CURRENT_RUN_LOG" 2>/dev/null || true
  fi
}

die() {
  log "FATAL: $*"
  exit 1
}

# Guard that a flag which expects a value was actually given one. Call as:
#   need_arg $# "$1"
# where the first argument is the remaining arg count (the flag plus anything
# after it) and the second is the flag name used in the error message.
need_arg() {
  [ "$1" -ge 2 ] || die "option $2 requires a value"
}

# Ensure a label exists (ignore "already exists" errors).
ensure_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" >/dev/null 2>&1 || true
}

# >>> gh-host helpers >>>
# Echo the hostname embedded in a git remote URL, for both SSH and HTTPS forms:
#   https://bmw.ghe.com/unit/x.git    -> bmw.ghe.com
#   git@bmw.ghe.com:unit/x.git        -> bmw.ghe.com
#   ssh://git@code.connected.bmw/o/r  -> code.connected.bmw
# Empty output when no host can be parsed. Used to target `gh` calls that do NOT
# resolve a host from the repo (e.g. `gh api user`) at the host that actually
# owns this repo, so a machine logged in to several hosts (a personal github.com
# account plus one or more enterprise hosts) never resolves the wrong account.
_gh_host_from_url() {
  printf '%s' "$1" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/@]*@##; s#[/:].*$##'
}
# <<< gh-host helpers <<<

# >>> terminal-title helpers >>>
# Emit the OSC escape that sets a terminal's window/tab title to $1. Pure (writes
# only the sequence to stdout), so it can be unit tested.
terminal_title_seq() {
  printf '\033]0;%s\007' "$1"
}

# Make the branch being worked on visible on the terminal tab/window title.
# Inside tmux, rename the current window (shown as a tab on the status line);
# otherwise emit an OSC escape to the attached terminal. Best-effort: only
# touches a real terminal (stdout is a TTY) and never fails the caller.
set_terminal_title() {
  local title="$1"
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux rename-window "$title" 2>/dev/null || true
    return 0
  fi
  [ -t 1 ] || return 0
  terminal_title_seq "$title"
}
# <<< terminal-title helpers <<<

usage() {
  cat <<'EOF'
Usage: ./copilot-loop.sh [options]

Autonomous loop that resolves labelled GitHub issues with the Copilot CLI.

Options (each is also settable via the matching environment variable; when both
are given the command-line flag wins). "--flag value" and "--flag=value" both
work:
  --trigger-label <label>  Label that marks an issue as ready    (default: ready)
  --sleep-minutes <n>      Idle sleep, in minutes, when no work   (default: 5)
  --repo-dir <dir>         Repository to operate in               (default: current git repo)
  --model <model>          Model passed to copilot --model        (default: unset/auto)
  --copilot-timeout <dur>  Wall-clock limit for each Copilot run (issue resolve,
                           PR conflict/checks fix, default-branch sync) so a stuck
                           run cannot block the loop. Accepts seconds or an s/m/h/d
                           suffix (e.g. 1800, 30m, 2h); "0"/"off" disables it
                                                                    (default: 30m)
  --commit-model <model>   Model used to write the commit message from the
                           staged diff; unset/"off" uses a deterministic
                           "Resolve #<n>: <title>" message         (default: off)
  --triage-model <model>   Cheap model that classifies each issue as
                           trivial/normal/complex before coding so the coding
                           model can be chosen per difficulty; unset/"off"
                           disables triage (current behaviour)      (default: off)
  --triage-map <map>       Comma-separated class=model pairs mapping a triage
                           class to the coding model, e.g.
                           "trivial=gpt-5-mini,complex=claude-opus-4.5". An
                           unmapped class falls back to --model; defaults to
                           "trivial=<triage-model>" when triage is on and this is
                           unset                                    (default: unset)
  --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
  --quiet                  Do not stream Copilot's output to stdout; write it
                           only to the per-run log files (the original
                           behaviour). By default the loop streams Copilot's
                           output live to stdout as well as the log files.
  --worktrees              Give every issue its own git worktree (never touch
                           the shared checkout). This is the default, so each
                           task always works in a different folder.
  --no-worktrees           Work in the current checkout instead of per-issue
                           worktrees. The default branch is still never checked
                           out for work; the issue branch is created directly.
  --auto-merge             Merge every PR automatically (GitHub auto-merge when
                           the repo allows it, otherwise an immediate merge) so
                           no manual review is needed. Default: off.
  --no-auto-merge          Leave PRs open for manual review (the default).
  --quality-assurance      Ask Copilot to add tests for the work it did on each
                           issue, written from the user's perspective (the
                           default). Alias: --qa.
  --no-quality-assurance   Skip the quality-assurance tests to save cost.
                           Alias: --no-qa.
  --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
                           (default: merge).
  --cleanup-merged         Sweep merged issue branches and worktrees each pass
                           (the default).
  --no-cleanup-merged      Leave merged branches and worktrees in place.
  --delete-remote-branch   Delete a merged issue's remote branch. Default: auto —
                           on only when the repository does not already delete
                           head branches on merge.
  --no-delete-remote-branch
                           Never delete remote branches; leave that to GitHub.
  -h, --help               Show this help and exit.
  -V, --version            Print the copilot-loop version and exit.

Environment variables (equivalent to the flags above):
  TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COPILOT_TIMEOUT,
  COMMIT_MODEL, TRIAGE_MODEL, TRIAGE_MAP, ISSUES_DIR, QUIET, USE_WORKTREES,
  AUTO_MERGE, QUALITY_ASSURANCE, MERGE_METHOD, CLEANUP_MERGED, DELETE_REMOTE_BRANCH
EOF
}

# Run copilot with the given args, always capturing output to $log_file. Unless
# QUIET is set, the output is also streamed live to stdout via tee. When
# COPILOT_TIMEOUT is set the run is time-boxed through _run_with_timeout, so a
# stuck run can never block the loop; on expiry COPILOT_RC is 124 (per timeout(1))
# and the caller treats it as a failed attempt. Sets the global COPILOT_RC to
# copilot's own exit code (not tee's).
run_copilot() {
  local log_file="$1"; shift
  local -a _timeout_guard=()
  [ -n "${COPILOT_TIMEOUT:-}" ] && _timeout_guard=(_run_with_timeout "$COPILOT_TIMEOUT")
  if [ "$QUIET" = 1 ]; then
    ${_timeout_guard[@]+"${_timeout_guard[@]}"} copilot "$@" >>"$log_file" 2>&1
    COPILOT_RC=$?
  else
    ${_timeout_guard[@]+"${_timeout_guard[@]}"} copilot "$@" 2>&1 | tee -a "$log_file"
    COPILOT_RC="${PIPESTATUS[0]}"
  fi
}

# >>> usage helpers >>>
# Extract the per-run cost/usage summary Copilot prints at the end of a run from
# its captured output (read on stdin). Copilot ends a run with lines like:
#     AI Credits 25.7 (8s)
#     Tokens     ↑ 40.2k (40.2k written) • ↓ 221 (217 reasoning)
# Echoes the LAST "AI Credits" (or legacy "Premium requests") line followed by
# the LAST "Tokens" line, each with indentation and any trailing CR/space
# stripped, as one multi-line summary. Taking the LAST occurrence ignores an
# earlier triage run's stats captured in the same log. Echoes nothing when
# neither line is present. Pure: reads only stdin, writes only stdout.
parse_usage_stats() {
  local input credits tokens
  input="$(cat)"
  credits="$(printf '%s\n' "$input" | sed 's/\r$//' \
    | grep -E '^[[:space:]]*(AI Credits|Premium requests)[[:space:]]' \
    | tail -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  tokens="$(printf '%s\n' "$input" | sed 's/\r$//' \
    | grep -E '^[[:space:]]*Tokens[[:space:]]' \
    | tail -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -n "$credits" ] && [ -n "$tokens" ]; then
    printf '%s\n%s\n' "$credits" "$tokens"
  elif [ -n "$credits" ]; then
    printf '%s\n' "$credits"
  elif [ -n "$tokens" ]; then
    printf '%s\n' "$tokens"
  fi
}
# <<< usage helpers <<<

# Post the per-run cost/usage summary Copilot printed (parsed out of $log_file)
# as a comment on the issue or PR, tagged with USAGE_MARKER so it is easy to spot
# and filter in the thread. Skips silently when the log held no usage stats, and
# never fails the loop (every failure is swallowed) so cost tracking can never
# block or break a run.
# Usage: _report_usage <issue|pr> <num> <log_file> <model>
_report_usage() {
  local kind="$1" num="$2" log_file="$3" model="${4:-}" summary header body
  [ -f "$log_file" ] || return 0
  summary="$(parse_usage_stats <"$log_file" 2>/dev/null)"
  [ -n "$summary" ] || return 0
  header="**copilot-loop usage**"
  [ -n "$model" ] && header="$header (model: $model)"
  # shellcheck disable=SC2016  # backticks/%s are literal printf format, not expansions
  body="$(printf '%s\n\n```\n%s\n```\n\n%s' "$header" "$summary" "$USAGE_MARKER")"
  case "$kind" in
    pr) gh pr comment "$num" --body "$body" >/dev/null 2>&1 || true ;;
    *)  gh issue comment "$num" --body "$body" >/dev/null 2>&1 || true ;;
  esac
  return 0
}

# Run a command with a wall-clock limit when a timeout utility is available so a
# hung helper (e.g. the commit-message model) can never stall the whole loop.
# Uses timeout/gtimeout if present, otherwise runs the command unguarded. Passes
# through the command's exit status (124 on timeout, per timeout(1)).
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# --- Copilot run timeout -----------------------------------------------------
# Pure helpers that normalise the COPILOT_TIMEOUT setting and detect a timed-out
# run. Extracted between the markers by tests/timeout.test.sh, so keep the marker
# comments intact.
# >>> copilot-timeout helpers >>>
# True (rc 0) when a COPILOT_TIMEOUT spec means "no timeout": an empty value, one
# of the disable words (off/none/false/no/disable/disabled), or a zero-magnitude
# duration (0, 0s, 0m, 0h, 0d). Case- and whitespace-insensitive. Anything else (a
# real duration, or garbage) returns rc 1. Pure: reads only $1.
copilot_timeout_disabled() {
  local raw num
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$raw" in
    ''|off|none|false|no|disable|disabled) return 0 ;;
    *[!0-9smhd]*)                          return 1 ;;
  esac
  num="${raw%[smhd]}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$num))" -eq 0 ] 2>/dev/null && return 0
  return 1
}

# Echo a duration usable by timeout(1) for a COPILOT_TIMEOUT spec, or nothing when
# the spec is not a valid duration. Accepts bare seconds ("1800") or an integer
# with a single s/m/h/d suffix ("30m", "2h"). Case- and whitespace-insensitive.
# Pure: reads only $1; callers treat empty output as "unparseable".
normalize_copilot_timeout() {
  local raw num
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$raw" in
    ''|*[!0-9smhd]*) return 0 ;;
  esac
  num="${raw%[smhd]}"
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$raw"
}

# True (rc 0) when a run guarded by COPILOT_TIMEOUT was killed for exceeding it:
# timeout(1) exits 124 on expiry, so treat that code as a timeout only when a
# timeout was actually in force ($1, the effective spec, is non-empty). Pure:
# reads $1 (spec) and $2 (exit code).
copilot_run_timed_out() {
  [ -n "${1:-}" ] || return 1
  [ "${2:-}" = "124" ]
}
# <<< copilot-timeout helpers <<<

# Echo a commit message for the staged changes in WORKSPACE_DIR. Tries to have
# the cheapest model (COMMIT_MODEL) summarise the staged diff, and always falls
# back to a deterministic "Resolve #<n>: <title>" so a missing, disabled, slow or
# failing model never blocks the commit. Only the diff is sent to the model (no
# tools, no repo access needed), and the call is time-boxed. Never fails.
build_commit_message() {
  local num="$1" title="$2"
  local fallback="Resolve #${num}: ${title}"
  local diff prompt msg

  # Model generation disabled -> deterministic message.
  [ -n "$COMMIT_MODEL" ] || { printf '%s' "$fallback"; return 0; }

  # Feed the model a bounded view of the staged diff (name-status + patch),
  # capped so a huge change set cannot blow up the prompt or the cost.
  diff="$(git -C "$WORKSPACE_DIR" diff --cached --stat 2>/dev/null)"$'\n\n'"$(git -C "$WORKSPACE_DIR" diff --cached 2>/dev/null | head -c 12000)"
  [ -n "${diff// /}" ] || { printf '%s' "$fallback"; return 0; }

  prompt="$(cat <<EOF
Write a git commit message for the staged changes below, which resolve GitHub issue #${num} ("${title}").
Reply with ONLY the commit message and nothing else: a single subject line of at most 72 characters in the imperative mood, optionally followed by a blank line and a short body. Do not wrap it in code fences or add any preamble.

${diff}
EOF
)"

  # Cheapest model, no tools, no color/logs; time-boxed. Discard stderr so any
  # provider noise cannot leak into the message. Fall back on any failure.
  msg="$(cd "$WORKSPACE_DIR" 2>/dev/null \
         && _run_with_timeout 120 copilot -p "$prompt" \
              --model "$COMMIT_MODEL" --allow-all-tools --no-color --log-level none 2>/dev/null)"
  # Trim leading/trailing blank lines and strip stray surrounding code fences.
  msg="$(printf '%s\n' "$msg" | sed -e 's/^```.*$//' -e '/^[[:space:]]*$/d' | head -c 500)"

  if [ -n "$msg" ]; then
    printf '%s' "$msg"
  else
    printf '%s' "$fallback"
  fi
}

# --- Triage: pick the coding model per issue difficulty ----------------------
# normalize_triage_class and parse_triage_map are pure and covered by
# tests/triage.test.sh (extracted between the markers), so keep the marker
# comments intact.
# >>> triage helpers >>>
# Normalize a raw difficulty answer (possibly multi-word, mixed case, punctuated,
# or using a synonym) to one canonical class: trivial, normal, or complex. Echoes
# the class, or nothing when no known keyword is present so the caller can fall
# back to the default model.
normalize_triage_class() {
  local raw="$1" word
  word="$(printf '%s' "$raw" \
          | tr '[:upper:]' '[:lower:]' \
          | grep -oE 'trivial|simple|easy|complex|complicated|hard|difficult|normal|medium|moderate|standard' \
          | head -n1)"
  case "$word" in
    trivial|simple|easy)                printf 'trivial\n' ;;
    complex|complicated|hard|difficult) printf 'complex\n' ;;
    normal|medium|moderate|standard)    printf 'normal\n' ;;
    *)                                  return 0 ;;
  esac
}

# Look up the coding model for a difficulty class in a TRIAGE_MAP string of
# comma-separated "class=model" pairs (e.g. "trivial=gpt-5-mini, complex=o1").
# Class keys match case-insensitively; the model value is echoed verbatim (model
# ids are case-sensitive) with surrounding whitespace trimmed. The first entry
# for a class wins. Echoes nothing when the class is absent or its value is
# empty, so the caller falls back to the global default model.
# Usage: parse_triage_map <map> <class>
parse_triage_map() {
  local map="$1" class="$2" lc_class pair key val
  lc_class="$(printf '%s' "$class" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r pair; do
    case "$pair" in *=*) ;; *) continue ;; esac
    key="$(printf '%s' "${pair%%=*}" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    val="$(printf '%s' "${pair#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ "$key" = "$lc_class" ]; then
      [ -n "$val" ] && printf '%s\n' "$val"
      return 0
    fi
  done < <(printf '%s\n' "$map" | tr ',' '\n')
  return 0
}
# <<< triage helpers <<<

# >>> quality-assurance helpers >>>
# Decide whether quality assurance is on from a raw config value. QA is ON by
# default (issue #162 asked for it to run by default), so only the explicit falsy
# spellings turn it off; anything else -- including unset/empty -- is on. Echoes
# 1 (on) or 0 (off).
qa_enabled() {
  case "$1" in
    0|false|no|off|disable|disabled) printf '0\n' ;;
    *)                               printf '1\n' ;;
  esac
}

# The quality-assurance instruction appended to the issue prompt so Copilot adds
# tests covering the work it just did. Tests are asked for from the user's
# perspective (observable behaviour/outcomes), dropping to technical/unit tests
# only when a user-level test is impractical or makes no sense. Echoes the
# instruction paragraph when enabled ("1"), or nothing when disabled so the
# prompt is left unchanged.
qa_instruction() {
  [ "${1:-1}" = 1 ] || return 0
  cat <<'EOF'
Quality assurance: after implementing the change, add automated tests that cover
everything you did. Write the tests from the perspective of the user -- exercise
the behaviour and outcomes a user would observe, not internal implementation
details. Only fall back to technical/unit tests when testing from the user's
perspective is too complex or does not make sense for the change. Use the
project's existing test framework and conventions, and run the tests to verify
they pass.
EOF
}
# <<< quality-assurance helpers <<<

# Classify an issue's difficulty with the cheap TRIAGE_MODEL so the coding model
# can be chosen per difficulty (see parse_triage_map / TRIAGE_MAP). Echoes one
# normalized class (trivial|normal|complex) on success, or nothing when triage is
# disabled, the model is unavailable, times out, or its answer is unrecognised --
# the caller then falls back to the global model. Only the issue text is sent (no
# repo access needed) and the call is time-boxed, so triage can never block or
# fail the loop. Never returns non-zero.
triage_issue() {
  local num="$1" title="$2" body="$3" log_file="${4:-/dev/null}"
  local prompt raw class capped

  [ -n "$TRIAGE_MODEL" ] || return 0

  # Cap the body so a huge issue cannot blow up the triage prompt or its cost;
  # the difficulty is clear from the opening description.
  capped="$(printf '%s' "$body" | head -c 4000)"

  prompt="$(cat <<EOF
Classify the difficulty of this software task for an autonomous coding agent.
Answer with ONE word only, no punctuation or explanation, exactly one of:
  trivial - a tiny, low-risk change (typo, doc tweak, one-line or config fix)
  normal  - an average change with clear scope touching a few files
  complex - a large, ambiguous, or cross-cutting change needing careful design

Issue #${num}: ${title}

${capped}
EOF
)"

  # Cheapest model, no color/logs; time-boxed. Pin to the issue workspace (when
  # one exists) so triage never runs against the shared checkout. Append provider
  # noise to the log for debugging but keep stdout to just the class. Fall back
  # on any failure.
  local -a _ws_args=()
  [ -n "${WORKSPACE_DIR:-}" ] && _ws_args=(-C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR")
  raw="$(_run_with_timeout 60 copilot -p "$prompt" \
           ${_ws_args[@]+"${_ws_args[@]}"} \
           --model "$TRIAGE_MODEL" --allow-all-tools --no-color --log-level none 2>>"$log_file")"
  class="$(normalize_triage_class "$raw")"
  [ -n "$class" ] && printf '%s' "$class"
  return 0
}

# Sleep for the given number of seconds, but wake early if the user presses
# 'f'. Returns 0 if the full time elapsed, 1 if the user asked to start now.
# Falls back to a plain sleep when stdin is not a terminal (e.g. detached or
# piped), where keypresses cannot be read.
interruptible_sleep() {
  local seconds="$1"
  if [ ! -t 0 ]; then
    sleep "$seconds"
    return 0
  fi
  local key
  local end=$(( $(date +%s) + seconds ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if read -rsn1 -t 1 key && [ "$key" = "f" ]; then
      return 1
    fi
  done
  return 0
}

# --- Argument parsing --------------------------------------------------------
# Flags override the matching environment variables read above. Both
# "--flag value" and "--flag=value" forms are accepted.
while [ $# -gt 0 ]; do
  case "$1" in
    --trigger-label)   need_arg $# "$1"; TRIGGER_LABEL="$2"; shift ;;
    --trigger-label=*) TRIGGER_LABEL="${1#*=}" ;;
    --sleep-minutes)   need_arg $# "$1"; SLEEP_MINUTES="$2"; shift ;;
    --sleep-minutes=*) SLEEP_MINUTES="${1#*=}" ;;
    --repo-dir)        need_arg $# "$1"; REPO_DIR="$2"; shift ;;
    --repo-dir=*)      REPO_DIR="${1#*=}" ;;
    --model)           need_arg $# "$1"; COPILOT_MODEL="$2"; shift ;;
    --model=*)         COPILOT_MODEL="${1#*=}" ;;
    --copilot-timeout)   need_arg $# "$1"; COPILOT_TIMEOUT="$2"; shift ;;
    --copilot-timeout=*) COPILOT_TIMEOUT="${1#*=}" ;;
    --commit-model)    need_arg $# "$1"; COMMIT_MODEL="$2"; shift ;;
    --commit-model=*)  COMMIT_MODEL="${1#*=}" ;;
    --triage-model)    need_arg $# "$1"; TRIAGE_MODEL="$2"; shift ;;
    --triage-model=*)  TRIAGE_MODEL="${1#*=}" ;;
    --triage-map)      need_arg $# "$1"; TRIAGE_MAP="$2"; shift ;;
    --triage-map=*)    TRIAGE_MAP="${1#*=}" ;;
    --issues-dir)      need_arg $# "$1"; ISSUES_DIR="$2"; shift ;;
    --issues-dir=*)    ISSUES_DIR="${1#*=}" ;;
    --quiet)           QUIET=1 ;;
    --worktrees)       USE_WORKTREES=1 ;;
    --no-worktrees)    USE_WORKTREES=0 ;;
    --auto-merge)      AUTO_MERGE=1 ;;
    --no-auto-merge)   AUTO_MERGE=0 ;;
    --quality-assurance|--qa)       QUALITY_ASSURANCE=1 ;;
    --no-quality-assurance|--no-qa) QUALITY_ASSURANCE=0 ;;
    --merge-method)    need_arg $# "$1"; MERGE_METHOD="$2"; shift ;;
    --merge-method=*)  MERGE_METHOD="${1#*=}" ;;
    --delete-remote-branch)    DELETE_REMOTE_BRANCH=1 ;;
    --no-delete-remote-branch) DELETE_REMOTE_BRANCH=0 ;;
    --cleanup-merged)          CLEANUP_MERGED=1 ;;
    --no-cleanup-merged)       CLEANUP_MERGED=0 ;;
    -h|--help)         usage; exit 0 ;;
    -V|--version)      printf 'copilot-loop %s\n' "$COPILOT_LOOP_VERSION"; exit 0 ;;
    *)                 die "unknown argument: $1 (use --help)" ;;
  esac
  shift
done

# --- Apply configuration defaults --------------------------------------------
# Fill in anything left unset by both the environment and the flags. Done after
# parsing so a --repo-dir flag feeds the derived paths below.
# Operate on the current directory's repository by default, not the script's
# install location (it may be a symlink on PATH). Resolve to the git top-level
# so running from a subdirectory still targets the whole repo.
REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TRIGGER_LABEL="${TRIGGER_LABEL:-ready}"
SLEEP_MINUTES="${SLEEP_MINUTES:-5}"
QUIET="${QUIET:-0}"
ISSUES_DIR="${ISSUES_DIR:-$REPO_DIR/issues}"
# Commit messages use a deterministic "Resolve #<n>: <title>" by default so the
# loop spends Copilot only on implementing issues, not on writing commit
# messages. Opt in to model-written messages with --commit-model <model> (e.g.
# the cheap gpt-5-mini); an unset value or "off"/"none" keeps the deterministic
# message.
COMMIT_MODEL="${COMMIT_MODEL:-}"
case "$COMMIT_MODEL" in off|none|0) COMMIT_MODEL="" ;; esac

# Wall-clock limit for each main Copilot run (issue resolve, PR conflict fix, PR
# checks fix, default-branch sync) so a stuck run can never block the loop.
# Default 30m; "0"/"off" (and other disable spellings) turn it off. An unparseable
# value falls back to the default so protection is never silently lost. Stored
# normalised: a timeout(1) duration, or empty when disabled.
COPILOT_TIMEOUT="${COPILOT_TIMEOUT:-30m}"
if copilot_timeout_disabled "$COPILOT_TIMEOUT"; then
  COPILOT_TIMEOUT=""
else
  _ct_norm="$(normalize_copilot_timeout "$COPILOT_TIMEOUT")"
  COPILOT_TIMEOUT="${_ct_norm:-30m}"
fi

# Triage: a cheap model classifies each issue and a class->model map routes the
# coding model per difficulty. "off"/"none"/"0" disables triage (current
# behaviour). When triage is on but no map was given, default to sending trivial
# issues to the triage model itself so enabling triage lowers cost with zero
# extra config; normal/complex then fall back to COPILOT_MODEL.
TRIAGE_MODEL="${TRIAGE_MODEL:-}"
case "$TRIAGE_MODEL" in off|none|0) TRIAGE_MODEL="" ;; esac
TRIAGE_MAP="${TRIAGE_MAP:-}"
if [ -n "$TRIAGE_MODEL" ] && [ -z "$TRIAGE_MAP" ]; then
  TRIAGE_MAP="trivial=${TRIAGE_MODEL}"
fi

# Auto-merge each PR instead of leaving it for review. Normalise the various
# truthy/falsy spellings to 1/0; anything unset or unrecognised means off.
case "$AUTO_MERGE" in
  1|true|yes|on)  AUTO_MERGE=1 ;;
  *)              AUTO_MERGE=0 ;;
esac
# Quality assurance: ask Copilot to add user-perspective tests for the work.
# On by default (issue #162); only the explicit falsy spellings turn it off.
QUALITY_ASSURANCE="$(qa_enabled "$QUALITY_ASSURANCE")"
# Merge method used by auto-merge. Default to a merge commit; reject anything
# other than the three methods gh understands so a typo fails loudly at startup.
MERGE_METHOD="${MERGE_METHOD:-merge}"
case "$MERGE_METHOD" in
  merge|squash|rebase) ;;
  *) die "invalid --merge-method: $MERGE_METHOD (use merge, squash or rebase)" ;;
esac

# Periodic cleanup of merged issue branches/worktrees. On unless explicitly
# disabled; DELETE_REMOTE_BRANCH (auto-detected further below, once gh is known
# to be available) then decides whether remote branches are removed too.
case "$CLEANUP_MERGED" in
  0|false|no|off) CLEANUP_MERGED=0 ;;
  *)              CLEANUP_MERGED=1 ;;
esac

# Bounded wait for GitHub's async mergeability computation before the conflict
# check (see the "mergeability helpers"). Defaults give a freshly updated PR time
# to be evaluated without stalling the loop; 0 attempts disables the wait. Force
# both to non-negative integers so a bad value never breaks the arithmetic.
MERGEABILITY_WAIT_ATTEMPTS="${MERGEABILITY_WAIT_ATTEMPTS:-5}"
case "$MERGEABILITY_WAIT_ATTEMPTS" in ''|*[!0-9]*) MERGEABILITY_WAIT_ATTEMPTS=5 ;; esac
MERGEABILITY_WAIT_SECONDS="${MERGEABILITY_WAIT_SECONDS:-3}"
case "$MERGEABILITY_WAIT_SECONDS" in ''|*[!0-9]*) MERGEABILITY_WAIT_SECONDS=3 ;; esac

WORK_DIR="$REPO_DIR/.copilot-loop"
LOG_DIR="$WORK_DIR/logs"

# --- Preflight ---------------------------------------------------------------
for bin in git gh copilot; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

cd "$REPO_DIR" || die "cannot cd into REPO_DIR: $REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO_DIR"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# `gh auth status` only proves *some* account is logged in. This machine may be
# logged in to several hosts at once (a personal github.com account plus one or
# more enterprise hosts); the account that resolves for THIS repo's host can
# still lack access, or the repo's host may not be logged in at all — e.g. an
# origin on an enterprise host, or an SSH host alias gh cannot map to a login.
# When that happens `gh repo view` fails, yet the loop used to carry on: REPO_SLUG
# became "unknown" and every `gh issue list` silently returned nothing, so the
# loop just slept forever and looked "broken". Fail fast instead, naming the
# host and account so the mismatch is obvious and actionable.
if ! gh repo view --json nameWithOwner >/dev/null 2>&1; then
  _pf_url="$(git remote get-url origin 2>/dev/null)"
  _pf_host="$(_gh_host_from_url "$_pf_url")"
  log "FATAL: gh cannot access this repository from $REPO_DIR"
  log "  origin remote: ${_pf_url:-<none>}"
  log "  repo host:     ${_pf_host:-<unknown>}"
  log "  gh account:    $(gh api --hostname "${_pf_host:-github.com}" user --jq '.login' 2>/dev/null || echo '<no access on this host>')"
  log "  The gh account for this host cannot see the repo (wrong account, missing access, or the host is not logged in)."
  log "  Fix: run 'gh auth status' to list hosts/accounts, then 'gh auth login --hostname ${_pf_host:-HOST}'"
  log "       (or 'gh auth switch') for an account that can access this repo."
  exit 1
fi

mkdir -p "$LOG_DIR"

# Lock file for GitHub operations (issue fetching/claiming).
# Multiple instances can run concurrently but must synchronize around GitHub API calls.
GITHUB_LOCK_FILE="$WORK_DIR/github.lock"

# Best-effort modification time (epoch seconds) of a path. Portable across the
# BSD stat on macOS (-f %m) and GNU stat on Linux (-c %Y); echoes 0 when it
# cannot tell.
_lock_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Acquire the GitHub lock (a directory created with mkdir). Waits up to max_wait
# real seconds, then gives up (returns 1) so a busy peer never stalls the loop
# for long. A lock left behind by a crashed instance is reclaimed once it is
# older than stale_after seconds, so a hard-killed holder cannot wedge every
# instance forever. Caller must release with release_github_lock().
acquire_github_lock() {
  local max_wait=30 stale_after=600 start now lock_mtime
  start="$(date +%s)"
  while ! mkdir "$GITHUB_LOCK_FILE" 2>/dev/null; do
    now="$(date +%s)"
    # Reclaim a stale lock from a crashed holder (skip when mtime is unknown).
    lock_mtime="$(_lock_mtime "$GITHUB_LOCK_FILE")"
    if [ "$lock_mtime" -gt 0 ] 2>/dev/null && [ $(( now - lock_mtime )) -ge "$stale_after" ]; then
      log "WARNING: breaking stale GitHub lock (older than ${stale_after}s)"
      rm -rf "$GITHUB_LOCK_FILE" 2>/dev/null || true
      continue
    fi
    if [ $(( now - start )) -ge "$max_wait" ]; then
      log "WARNING: GitHub lock busy after ${max_wait}s; skipping this pass"
      return 1
    fi
    sleep 0.2
  done
  return 0
}

# Release the GitHub lock.
release_github_lock() {
  rm -rf "$GITHUB_LOCK_FILE" 2>/dev/null || true
}

cleanup() {
  release_github_lock
  log "shutting down"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
# Host that owns this repo, used to pin repo-independent `gh` calls (below) to
# the right account when several hosts are logged in.
GH_HOST_ORIGIN="$(_gh_host_from_url "$ORIGIN_URL")"
REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[ -n "$REPO_SLUG" ] || REPO_SLUG="unknown"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
# Linked worktrees (and some manually-added remotes) can have no fetch refspec,
# so `git fetch origin` never populates origin/* remote-tracking refs and every
# `origin/<branch>` reference fails with "invalid upstream". Restore the standard
# refspec so remote-tracking refs always resolve.
if ! git config --get-all remote.origin.fetch 2>/dev/null | grep -q .; then
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
    && log "restored missing fetch refspec for origin"
fi

# Decide whether to delete an issue's remote branch once its PR merges. When not
# forced with 1/0, auto-detect from the repository: skip it when GitHub already
# deletes head branches on merge (it cleans up for us) and enable it otherwise,
# so a repo without that setting no longer accumulates merged branches.
case "$DELETE_REMOTE_BRANCH" in
  1|true|yes|on)  DELETE_REMOTE_BRANCH=1 ;;
  0|false|no|off) DELETE_REMOTE_BRANCH=0 ;;
  *)
    if [ "$(gh repo view --json deleteBranchOnMerge --jq '.deleteBranchOnMerge' 2>/dev/null)" = "true" ]; then
      DELETE_REMOTE_BRANCH=0
    else
      DELETE_REMOTE_BRANCH=1
    fi
    ;;
esac

# --- Self-update setup -------------------------------------------------------
# Decide whether the loop keeps itself current by pulling the default branch and
# re-execing when this script changed upstream (see self_update, called at the
# top of the main loop). Auto-enable when the script is a tracked file in the
# repo we operate on; an explicit SELF_UPDATE=1/0 always wins.
case "$SELF_UPDATE" in
  1|true|yes|on)   SELF_UPDATE=1 ;;
  0|false|no|off)  SELF_UPDATE=0 ;;
  *)
    if git -C "$REPO_DIR" ls-files --error-unmatch -- "$SCRIPT_PATH" >/dev/null 2>&1; then
      SELF_UPDATE=1
    else
      SELF_UPDATE=0
    fi
    ;;
esac
# Path of the running script relative to the repo root, used to read its upstream
# version. Empty (self-update off) when the script is not tracked in this repo.
SCRIPT_REL=""
if [ "$SELF_UPDATE" = 1 ]; then
  SCRIPT_REL="$(git -C "$REPO_DIR" ls-files --full-name -- "$SCRIPT_PATH" 2>/dev/null | head -1)"
  [ -n "$SCRIPT_REL" ] || SELF_UPDATE=0
fi

# Whether to sync the local default branch with origin/<default> before each pass
# (see sync_default_branch, called at the top of the main loop). On unless an
# explicit 0/false/no/off turns it off.
case "$SYNC_REMOTE" in
  0|false|no|off) SYNC_REMOTE=0 ;;
  *)              SYNC_REMOTE=1 ;;
esac

# Decide whether to isolate each issue in its own git worktree. On by default so
# every task works in a different folder and parallel instances never touch the
# same checkout; pass --no-worktrees (or USE_WORKTREES=0) to work in place
# instead. This keeps the shared checkout untouched and guarantees the default
# branch is never used for the work. Each issue still gets its own branch in
# either mode.
# >>> worktree-default helpers >>>
case "$USE_WORKTREES" in
  0|false|no|off) USE_WORKTREES=0 ;;
  *)              USE_WORKTREES=1 ;;
esac
# <<< worktree-default helpers <<<
# Where per-issue worktrees are created (only used when USE_WORKTREES=1). In a
# bare-repo worktree workflow (git clone --bare + linked worktrees, e.g. the
# cw/aw/sw shell helpers) they live directly under the bare root, named after the
# branch with slashes flattened to dashes — exactly what `sw <branch>` creates —
# so the loop shares one worktree namespace with any created by hand and the two
# never collide. In an ordinary (non-bare) checkout they are grouped in a
# copilot-loop-worktrees sibling of REPO_DIR so they never land inside the
# tracked working tree.
_common_dir="$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null || echo .)"
case "$_common_dir" in /*) : ;; *) _common_dir="$REPO_DIR/$_common_dir" ;; esac
_common_dir="$(cd "$_common_dir" 2>/dev/null && pwd)" || _common_dir=""
if [ -n "$_common_dir" ] && [ "$(git --git-dir="$_common_dir" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
  WORKTREE_BASE="$_common_dir"
else
  WORKTREE_BASE="$(dirname "$REPO_DIR")/copilot-loop-worktrees"
fi
unset _common_dir

# Our own login, used to tell the user's replies apart from the loop's own
# comments when deciding whether a "needs-info" issue is ready to resume. Pin the
# query to the repo's host so a machine logged in to several hosts reports the
# identity that actually comments on this repo (github.com's `gh api user` would
# otherwise be returned for an enterprise repo, breaking reply detection).
if [ -n "$GH_HOST_ORIGIN" ]; then
  BOT_LOGIN="$(gh api --hostname "$GH_HOST_ORIGIN" user --jq '.login' 2>/dev/null)"
else
  BOT_LOGIN="$(gh api user --jq '.login' 2>/dev/null)"
fi
[ -n "$BOT_LOGIN" ] || log "WARNING: could not determine gh login; reply detection disabled"

log "starting copilot-loop"
log "============================================================"
log "  GitHub repo: $REPO_SLUG"
log "  gh account:  ${BOT_LOGIN:-<unknown>} @ ${GH_HOST_ORIGIN:-github.com}"
log "  origin url:  $ORIGIN_URL"
log "  local dir:   $REPO_DIR"
log "============================================================"
log "default_branch=$DEFAULT_BRANCH trigger_label=$TRIGGER_LABEL sleep=${SLEEP_MINUTES}m"
if [ "$USE_WORKTREES" = 1 ]; then
  log "isolation: per-issue git worktrees under $WORKTREE_BASE (default branch never checked out)"
else
  log "isolation: per-issue branches in the current checkout (default branch never checked out)"
fi
if [ "$QUIET" = 1 ]; then
  log "copilot output: log files only (--quiet); stdout hidden"
else
  log "copilot output: streamed to stdout and log files (pass --quiet to hide)"
fi
if [ "$AUTO_MERGE" = 1 ]; then
  log "auto-merge: on (method=$MERGE_METHOD) — PRs merge without review"
else
  log "auto-merge: off — PRs are left open for review (pass --auto-merge to enable)"
fi
if [ "$QUALITY_ASSURANCE" = 1 ]; then
  log "quality assurance: on — Copilot adds user-perspective tests per issue (pass --no-quality-assurance to disable)"
else
  log "quality assurance: off — no tests requested (pass --quality-assurance to enable)"
fi
if [ "$CLEANUP_MERGED" = 1 ]; then
  if [ "$DELETE_REMOTE_BRANCH" = 1 ]; then
    log "cleanup: on — merged branches and worktrees removed, remote branches deleted"
  else
    log "cleanup: on — merged branches and worktrees removed (remote branches left to GitHub)"
  fi
else
  log "cleanup: off — merged branches and worktrees are not swept (pass --cleanup-merged to enable)"
fi

ensure_label "$TRIGGER_LABEL"    "0e8a16" "Ready for the copilot loop to pick up"
ensure_label "$INPROGRESS_LABEL" "fbca04" "Currently being worked by the copilot loop"
ensure_label "$DONE_LABEL"       "1d76db" "A PR was opened by the copilot loop"
ensure_label "$FAILED_LABEL"     "b60205" "The copilot loop failed to produce changes"
ensure_label "$NEEDS_INFO_LABEL" "d93f0b" "Waiting for the issue author to answer a question"
ensure_label "$PENDING_LABEL"    "d4c5f9" "Waiting for another issue to be resolved before it can start"
ensure_label "$CONFLICT_UNRESOLVED_LABEL" "b60205" "The copilot loop could not resolve this PR's merge conflicts"
ensure_label "$CHECKS_UNRESOLVED_LABEL" "b60205" "The copilot loop could not fix this PR's failing checks"

# --- Workspace isolation -----------------------------------------------------
# Every issue (and every PR conflict fix) runs in its own branch, prepared here.
# The default branch (main/master) is NEVER checked out for the work: the branch
# is created directly from a start commit-ish (normally origin/<default>).
#
# Two modes, selected by USE_WORKTREES:
#   1 -> a dedicated git worktree per branch, so the shared checkout is untouched
#        (the default: every task works in a different folder, and it is required
#        when the repo is used with git worktrees, where the default branch may
#        already be checked out elsewhere and cannot be switched to).
#   0 -> the branch is checked out in REPO_DIR itself (opt in with --no-worktrees).
# Both set WORKSPACE_DIR to the directory Copilot and git should operate in.
WORKSPACE_DIR=""

# Map a branch name to its worktree directory (slashes flattened to dashes).
# >>> workspace helpers >>>
_worktree_path() {
  printf '%s/%s' "$WORKTREE_BASE" "$(printf '%s' "$1" | tr '/' '-')"
}

# _worktree_lock_state <branch>
# Classify the lock on the worktree that has <branch> checked out, so cleanup
# can tell its own (reclaimable) worktree from one a *different* live run still
# owns (#106):
#   unlocked  -> not locked
#   pid:<N>   -> locked by a copilot-loop run whose pid is <N> (see the reason
#                prepare_workspace writes)
#   locked    -> locked without our pid marker (e.g. a manual `git worktree lock`)
# Matches on the branch ref rather than the path so it stays correct when git
# reports a resolved path (e.g. macOS /var -> /private/var); the lock reason is
# emitted on the `locked` line, unquoted for our plain reason.
_worktree_lock_state() {
  local branch="$1" line target=0 pid
  [ -n "$branch" ] || { printf 'unlocked'; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) target=0 ;;
      "branch refs/heads/$branch") target=1 ;;
      locked|"locked "*)
        if [ "$target" = 1 ]; then
          pid="$(printf '%s\n' "$line" | sed -n 's/.*pid \([0-9][0-9]*\).*/\1/p')"
          if [ -n "$pid" ]; then printf 'pid:%s' "$pid"; else printf 'locked'; fi
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  printf 'unlocked'
}

# prepare_workspace <branch> <start-ref>
# Create (or reset) <branch> at <start-ref> and set WORKSPACE_DIR. Returns 1 if
# the branch/worktree could not be created.
prepare_workspace() {
  local branch="$1" start="$2"
  cleanup_workspace "$branch"
  if [ "$USE_WORKTREES" = 1 ]; then
    local wt; wt="$(_worktree_path "$branch")"
    mkdir -p "$WORKTREE_BASE" 2>/dev/null || true
    if ! git worktree add --force -B "$branch" "$wt" "$start" >/dev/null 2>&1; then
      return 1
    fi
    # Lock the worktree for as long as this run owns it so a concurrent cleanup
    # pass in another bot (sweep_merged_branches / git worktree prune) can never
    # remove the folder out from under a live Copilot session — the race that
    # left sessions with a dead working directory. cleanup_workspace unlocks it.
    git worktree lock --reason "copilot-loop: $branch in progress (pid $$)" "$wt" >/dev/null 2>&1 || true
    WORKSPACE_DIR="$wt"
  else
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    if ! git -C "$REPO_DIR" switch -C "$branch" "$start" >/dev/null 2>&1; then
      return 1
    fi
    WORKSPACE_DIR="$REPO_DIR"
  fi
}

# cleanup_workspace <branch>
# Tear down the workspace for <branch> and delete the local branch. Never checks
# out the default branch; in-place mode parks on a detached HEAD so the branch
# can be deleted.
cleanup_workspace() {
  local branch="$1"
  if [ "$USE_WORKTREES" = 1 ]; then
    local wt; wt="$(_worktree_path "$branch")"
    # Never tear down a worktree a *different* live run still owns: removing it
    # would delete an active Copilot session's working directory — the #106
    # race. Our own lock (pid $$) and a crashed run's stale lock (a pid no
    # longer alive) are safe to reclaim; a foreign live lock, or one placed by
    # hand (no pid marker), is left strictly alone so the session survives.
    local lock_state; lock_state="$(_worktree_lock_state "$branch")"
    case "$lock_state" in
      "pid:$$") : ;;                                   # our own lock -> reclaim
      pid:*)
        if kill -0 "${lock_state#pid:}" 2>/dev/null; then
          WORKSPACE_DIR=""
          return 0                                     # another live run owns it
        fi
        ;;                                             # dead pid -> reclaim
      locked)
        WORKSPACE_DIR=""
        return 0                                       # locked by hand -> leave it
        ;;
    esac
    # Unlock first: prepare_workspace locked it while the run was live, and a
    # locked worktree cannot be removed with a single --force.
    git worktree unlock "$wt" >/dev/null 2>&1 || true
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
  else
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" switch --detach >/dev/null 2>&1 || true
  fi
  git branch -D "$branch" >/dev/null 2>&1 || true
  WORKSPACE_DIR=""
}
# <<< workspace helpers <<<

# --- Core: enable auto-merge on a freshly opened PR --------------------------
# When AUTO_MERGE is on, ask GitHub to merge the PR without manual review.
# Prefer GitHub's native auto-merge (it waits for any required status checks);
# when the repository does not allow auto-merge, fall back to merging right now.
# Best effort: a failure here never fails the issue, it just leaves the PR open.
try_auto_merge() {
  local pr="$1" num="$2" log_file="$3"
  [ "$AUTO_MERGE" = 1 ] || return 0
  if gh pr merge "$pr" --auto "--$MERGE_METHOD" >>"$log_file" 2>&1; then
    log "issue #$num: auto-merge enabled (method=$MERGE_METHOD) on $pr"
    return 0
  fi
  # Auto-merge is likely not enabled on the repository; merge immediately.
  if gh pr merge "$pr" "--$MERGE_METHOD" >>"$log_file" 2>&1; then
    log "issue #$num: merged immediately (method=$MERGE_METHOD) $pr"
    return 0
  fi
  log "issue #$num: WARNING could not auto-merge $pr; left open for manual merge"
  return 0
}

# --- Core: branch & worktree cleanup ----------------------------------------
# Once an issue's PR is merged its work branch and worktree are dead weight. The
# helpers below remove them safely: only ever the loop's own branches
# ("$BRANCH_PREFIX"*, never the default branch), and never a branch that still
# has commits which are neither merged into the default branch nor pushed to its
# own remote branch (so un-pushed work is always preserved).
#
# branch_is_ours is pure (string logic only) and, with the rest of this block, is
# covered by tests/cleanup-branches.test.sh between the markers — keep them intact.
# >>> cleanup helpers >>>
# branch_is_ours <branch>
# True (0) only for a non-empty branch that is one of the loop's own work
# branches (matches "$BRANCH_PREFIX"*) and is not the default branch. Guards
# every destructive cleanup so it can never delete main/master or a branch a
# human created.
branch_is_ours() {
  local branch="$1"
  [ -n "$branch" ] || return 1
  [ "$branch" != "$DEFAULT_BRANCH" ] || return 1
  case "$branch" in
    "$BRANCH_PREFIX"?*) return 0 ;;
    *) return 1 ;;
  esac
}

# _worktree_dir_for_branch <branch>
# Echo the path of the linked worktree that currently has <branch> checked out,
# or nothing if none does. Reads `git worktree list` so the worktree is found
# wherever it lives, not only at the loop's own _worktree_path.
_worktree_dir_for_branch() {
  local branch="$1"
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    /^worktree /  { wt = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == b) { print wt; exit } }'
}

# _worktree_is_locked <path>
# True (0) when the worktree at <path> is currently locked, i.e. a live
# copilot-loop run owns it (see prepare_workspace). The sweep uses this to never
# remove or delete a worktree/branch that a running Copilot session still needs.
_worktree_is_locked() {
  local target="$1" line wt=""
  [ -n "$target" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      locked|"locked "*) [ "$wt" = "$target" ] && return 0 ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}

# branch_has_unpushed_work <branch> <base-ref>
# True (0) when <branch> has commits that are neither contained in <base-ref>
# (merged) nor in its own pushed remote ref (origin/<branch>) — i.e. deleting it
# would lose un-pushed work. Errs on the side of caution: any failure to tell is
# treated as "has un-pushed work" so the branch is preserved.
branch_has_unpushed_work() {
  local branch="$1" base="$2" n
  if git rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    n="$(git rev-list --count "$branch" --not "$base" "origin/$branch" 2>/dev/null || echo 1)"
  else
    n="$(git rev-list --count "$branch" --not "$base" 2>/dev/null || echo 1)"
  fi
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -gt 0 ]
}

# remove_local_branch <branch>
# Remove <branch>'s worktree (if any) and delete the local branch. Safe no-op for
# a branch that is not the loop's own; never checks out the default branch.
remove_local_branch() {
  local branch="$1" wt
  branch_is_ours "$branch" || return 0
  wt="$(_worktree_dir_for_branch "$branch")"
  if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
    # Defence-in-depth (#106): a locked worktree belongs to a live Copilot
    # session. Never remove it — nor delete its branch — even when this is
    # reached directly or the lock was taken after the sweep's own guard ran.
    log "cleanup: keeping $branch (worktree in use)"
    return 0
  fi
  if [ -n "$wt" ]; then
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  git worktree prune >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true
}

# delete_remote_branch <branch>
# Delete <branch> on origin when remote-branch cleanup is enabled. Safe no-op for
# a foreign/default branch or when the remote branch is already gone.
delete_remote_branch() {
  local branch="$1"
  [ "$DELETE_REMOTE_BRANCH" = 1 ] || return 0
  branch_is_ours "$branch" || return 0
  git push origin --delete "$branch" >/dev/null 2>&1 || true
}

# _branch_is_merged <ref> <base-ref> <merged-list> [name]
# True (0) when <ref>'s work is merged: <ref> is an ancestor of <base-ref> (the
# merge-commit method), or its branch <name> appears in <merged-list> (a merged
# PR, covering squash/rebase merges whose commits are not ancestors of the base).
# <name> defaults to <ref>.
_branch_is_merged() {
  local ref="$1" base="$2" merged_list="$3" name="${4:-$1}"
  if git merge-base --is-ancestor "$ref" "$base" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$merged_list" | grep -qxF -- "$name"
}

# sweep_merged_branches
# Periodic safety net: remove local branches/worktrees whose PR has merged, and
# delete the remote branches that linger after a merge. Only ever touches the
# loop's own branches and never one with un-pushed work. Best effort — every
# operation is guarded so a hiccup never interrupts the loop. Assumes the current
# directory is inside the repository (true in the main loop).
sweep_merged_branches() {
  [ "$CLEANUP_MERGED" = 1 ] || return 0

  # Refresh remote-tracking refs and drop ones already deleted upstream so the
  # merge checks below see the true remote state.
  git fetch --prune origin >/dev/null 2>&1 || true

  local base="origin/${DEFAULT_BRANCH}"
  git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="$DEFAULT_BRANCH"

  # One API call for the set of merged issue-branch names so squash/rebase merges
  # (whose commits are not ancestors of the base) are recognised too.
  local merged_prs
  merged_prs="$(gh pr list --state merged --base "$DEFAULT_BRANCH" --limit 200 \
                  --json headRefName --jq '.[].headRefName' 2>/dev/null)"

  local removed=0 b wt
  # Local branches: remove merged ones together with their worktree.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    branch_is_ours "$b" || continue
    _branch_is_merged "$b" "$base" "$merged_prs" || continue
    if branch_has_unpushed_work "$b" "$base"; then
      log "cleanup: keeping $b (has un-pushed work)"
      continue
    fi
    # Never pull a worktree out from under a live run: a locked worktree means a
    # Copilot session still owns it. Leave it — a later pass sweeps it once the
    # run finishes and cleanup_workspace unlocks it.
    wt="$(_worktree_dir_for_branch "$b")"
    if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
      log "cleanup: keeping $b (worktree in use)"
      continue
    fi
    remove_local_branch "$b"
    delete_remote_branch "$b"
    log "cleanup: removed merged branch $b"
    removed=$(( removed + 1 ))
  done < <(git for-each-ref --format='%(refname:short)' "refs/heads/${BRANCH_PREFIX}" 2>/dev/null)

  # Remote branches: delete ones whose PR merged but that still linger on origin
  # (the local branch was often already removed inline when its PR was opened).
  if [ "$DELETE_REMOTE_BRANCH" = 1 ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      branch_is_ours "$b" || continue
      _branch_is_merged "origin/$b" "$base" "$merged_prs" "$b" || continue
      # A live run may still push to this remote branch; if its local worktree is
      # locked (in use), leave the remote alone until the run finishes.
      wt="$(_worktree_dir_for_branch "$b")"
      if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
        log "cleanup: keeping remote $b (worktree in use)"
        continue
      fi
      delete_remote_branch "$b"
      log "cleanup: deleted merged remote branch $b"
      removed=$(( removed + 1 ))
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/origin/${BRANCH_PREFIX}" 2>/dev/null)
  fi

  [ "$removed" -gt 0 ] && log "cleanup: swept $removed merged branch(es)"
  return 0
}
# <<< cleanup helpers <<<

# --- Core: process a single issue -------------------------------------------
# Returns 0 on success (PR opened), 1 on failure.
process_issue() {
  local num="$1"
  local title body slug branch commit_msg commit_text commit_out pr_body log_file ahead pr_url
  local question_file comments comments_block qa_block

  # One API round-trip for everything we need from the issue (title, body, and
  # the comment thread) instead of three separate `gh issue view` calls. Fields
  # are NUL-separated so multi-line bodies and comments survive intact.
  { IFS= read -r -d '' title; IFS= read -r -d '' body; IFS= read -r -d '' comments; } < <(
    gh issue view "$num" --json title,body,comments \
      --jq '[.title, (.body // ""), ([.comments[] | "--- @" + (.author.login // "ghost") + " wrote:\n" + (.body // "")] | join("\n"))] | join("\u0000")' 2>/dev/null)
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="issue"
  branch="${BRANCH_PREFIX}${num}-${slug}"
  commit_msg="Resolve #${num}: ${title}"
  pr_body="Closes #${num}"$'\n\n'"Automated by copilot-loop."
  log_file="$LOG_DIR/issue-${num}-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-issue log so the TUI's output
  # panel shows the branch creation and the rest of the loop's narration, not
  # just Copilot's transcript (#126). Cleared at the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  log "issue #$num on $REPO_SLUG: $title"

  # Note: the issue has already been claimed atomically under the GitHub lock by
  # claim_next_ready_issue() / claim_next_reply_issue() in the main loop
  # (in-progress added; the trigger, needs-info, or copilot-failed label
  # removed). We don't re-claim here to avoid redundant API calls.

  # Base the issue branch on the latest default branch WITHOUT checking the
  # default branch out (it may be checked out in another worktree, and the issue
  # requires we never work on main/master). Fetch first so origin/<default> is
  # current, then create the branch/worktree straight from it.
  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  local start="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$start" >/dev/null 2>&1 || start="FETCH_HEAD"
  if ! prepare_workspace "$branch" "$start"; then
    _fail_issue "$num" "$log_file" "could not create work branch $branch"
    return 1
  fi

  # Copilot writes here when it needs to ask the user something instead of
  # coding. Kept inside the per-issue workspace (never the shared checkout) under
  # its gitignored control dir; the ask-path returns before any commit, so it is
  # never included in a PR. A fresh worktree carries no stale copy, but clear it
  # defensively.
  question_file="$WORKSPACE_DIR/.copilot-loop/issue-${num}.question"
  mkdir -p "$(dirname "$question_file")" 2>/dev/null || true
  rm -f "$question_file"

  # Surface the freshly created branch before Copilot starts: log it and set the
  # terminal tab/window title (and tmux window name) to the branch name.
  log "issue #$num: working on branch $branch"
  set_terminal_title "$branch"

  # Include the existing comment thread (fetched above) so any earlier
  # question/answer exchange is available to Copilot as context.
  comments_block=""
  [ -n "$comments" ] && comments_block=$'\n\nConversation so far (most recent last):\n'"$comments"

  # Quality assurance: unless disabled, append an instruction asking Copilot to
  # add user-perspective tests for the work. Wrapped in blank lines so it reads
  # as its own paragraph; empty (no extra blank line) when QA is off.
  qa_block=""
  [ "$QUALITY_ASSURANCE" = 1 ] && qa_block=$'\n'"$(qa_instruction "$QUALITY_ASSURANCE")"$'\n'

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository to resolve a GitHub issue.

Issue #${num}: ${title}

${body}${comments_block}

Implement the necessary code changes in the current working directory to fully
resolve this issue. Run any build or test commands needed to verify your work.
Do NOT run git commit, git push, create branches, or open pull requests — those
steps are handled automatically outside this session. Only edit files and verify.
${qa_block}
If you are blocked and need more information or a decision from the user, do NOT
guess. Write your question(s) for the user to this file and stop without making
code changes:
  ${question_file}
Whatever you write there is posted as a comment on the issue; once the user
replies you will be run again with their answer included above. Only do this
when you genuinely cannot proceed without their input.
EOF
)"

  # Run Copilot non-interactively, pinned to the issue's workspace: -C makes that
  # worktree Copilot's working directory and --add-dir keeps file access
  # restricted to it (we deliberately do not pass --allow-all-paths), so Copilot
  # only ever edits the created folder and never the shared checkout. The
  # question file lives inside that workspace, so no other directory is granted.
  # Choose the coding model. When triage is enabled, classify the issue with the
  # cheap TRIAGE_MODEL and map the class to a coding model via TRIAGE_MAP; on any
  # failure, or a class with no mapping, fall back to the global COPILOT_MODEL so
  # triage can only ever lower cost, never break or block the run.
  local coding_model="$COPILOT_MODEL" triage_class mapped_model
  if [ -n "$TRIAGE_MODEL" ]; then
    log "issue #$num: triaging with $TRIAGE_MODEL"
    triage_class="$(triage_issue "$num" "$title" "$body" "$log_file")"
    if [ -n "$triage_class" ]; then
      mapped_model="$(parse_triage_map "$TRIAGE_MAP" "$triage_class")"
      if [ -n "$mapped_model" ]; then
        coding_model="$mapped_model"
        log "issue #$num: triaged as '$triage_class' -> model '$mapped_model'"
      else
        log "issue #$num: triaged as '$triage_class' -> default model ${COPILOT_MODEL:-auto}"
      fi
    else
      log "issue #$num: triage inconclusive -> default model ${COPILOT_MODEL:-auto}"
    fi
  fi

  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  [ -n "$coding_model" ] && copilot_args+=(--model "$coding_model")

  log "issue #$num: running copilot (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    _fail_issue "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
    return 1
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  local copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "issue #$num: copilot exited with code $copilot_rc"

  # Track what this prompt cost on the issue (AI Credits + Tokens Copilot
  # printed), before any early return, so every run is accounted for.
  _report_usage issue "$num" "$log_file" "$coding_model"

  # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt: fail
  # the issue so the retry / copilot-failed path applies and it is recorded in the
  # issue log, instead of committing whatever partial work was left behind.
  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    _fail_issue "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
    return 1
  fi

  # Copilot asked for more information instead of coding: relay the question to
  # the user and wait for their reply (handled, so return success without a PR).
  if [ -s "$question_file" ]; then
    _ask_issue "$num" "$question_file"
    return 0
  fi

  # Stage everything Copilot produced. It is told not to commit, but if it did
  # anyway `add -A` is a harmless no-op for already-committed files.
  git -C "$WORKSPACE_DIR" add -A

  # Ensure the work is committed *before* we ever try to open a PR. A commit can
  # fail in ways easy to miss when the output is discarded (no git identity, a
  # rejecting pre-commit hook, ...), which only later surfaces as the confusing
  # "No commits between main and <branch>" error from `gh pr create`. So commit
  # explicitly, capture the output, and fail the issue loudly if it does not
  # succeed rather than pressing on with nothing committed.
  if ! git -C "$WORKSPACE_DIR" diff --cached --quiet; then
    commit_text="$(build_commit_message "$num" "$title")"
    if ! commit_out="$(git -C "$WORKSPACE_DIR" commit -m "$commit_text" 2>&1)"; then
      printf '%s\n' "$commit_out" >>"$log_file"
      _fail_issue "$num" "$log_file" "git commit failed" "$commit_out"
      return 1
    fi
    printf '%s\n' "$commit_out" >>"$log_file"
  fi

  # Refresh our view of the default branch so we can sync against any work that
  # landed on it while Copilot was running.
  git -C "$WORKSPACE_DIR" fetch origin "$DEFAULT_BRANCH" >>"$log_file" 2>&1 || true

  ahead="$(git -C "$WORKSPACE_DIR" rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null \
          || git -C "$WORKSPACE_DIR" rev-list --count "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"

  if [ "${ahead:-0}" -gt 0 ]; then
    # Sync onto the latest default branch before pushing so the PR merges
    # cleanly and does not fall behind commits that landed during the run.
    # Prefer the remote-tracking ref, but fall back to FETCH_HEAD if it is
    # missing (e.g. a worktree with no fetch refspec) so we never rebase onto a
    # ref that does not exist.
    local sync_target="origin/${DEFAULT_BRANCH}" rebase_out reason detail
    git -C "$WORKSPACE_DIR" rev-parse --verify --quiet "$sync_target" >/dev/null 2>&1 || sync_target="FETCH_HEAD"
    if ! rebase_out="$(git -C "$WORKSPACE_DIR" rebase "$sync_target" 2>&1)"; then
      printf '%s\n' "$rebase_out" >>"$log_file"
      git -C "$WORKSPACE_DIR" rebase --abort >/dev/null 2>&1 || true
      # Report the actual git error, and only call it a "conflict" when it is
      # one — an invalid upstream or a lock error is not a merge conflict.
      detail="$(printf '%s' "$rebase_out" | grep -iE 'fatal|error|conflict' | tail -n1)"
      if printf '%s' "$rebase_out" | grep -qi 'conflict'; then
        reason="failed to sync with ${DEFAULT_BRANCH} (rebase conflict)"
      elif [ -n "$detail" ]; then
        reason="failed to sync with ${DEFAULT_BRANCH}: ${detail}"
      else
        reason="failed to sync with ${DEFAULT_BRANCH}"
      fi
      _fail_issue "$num" "$log_file" "$reason" "$rebase_out"
      return 1
    fi
    # The rebase may have dropped our commits entirely (their work already
    # landed on the default branch, or the commit turned out empty). Re-count
    # what is unique to the branch *after* syncing so we never push an empty
    # branch and then hit "No commits between main and <branch>" at PR creation.
    ahead="$(git -C "$WORKSPACE_DIR" rev-list --count "${sync_target}..HEAD" 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -le 0 ]; then
      _fail_issue "$num" "$log_file" "no commits to open a PR with after syncing with ${DEFAULT_BRANCH}"
      return 1
    fi
    log "issue #$num: $ahead commit(s), pushing branch $branch"
    if ! git -C "$WORKSPACE_DIR" push -u origin "$branch" >>"$log_file" 2>&1; then
      _fail_issue "$num" "$log_file" "git push failed"
      return 1
    fi
    pr_url="$(gh pr create --base "$DEFAULT_BRANCH" --head "$branch" \
                --title "$commit_msg" --body "$pr_body" 2>>"$log_file")"
    if [ -z "$pr_url" ]; then
      _fail_issue "$num" "$log_file" "gh pr create failed"
      return 1
    fi
    try_auto_merge "$pr_url" "$num" "$log_file"
    gh issue edit "$num" --add-label "$DONE_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
    log "issue #$num: DONE -> $pr_url"
    # If the PR already merged (auto-merge did an immediate merge) the remote
    # branch is dead weight; drop it now when configured. PRs that merge later
    # (GitHub native auto-merge, or a human merge) are handled by the periodic
    # sweep in the main loop instead.
    if [ "$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" = "MERGED" ]; then
      delete_remote_branch "$branch"
    fi
    cleanup_workspace "$branch"
    return 0
  fi

  _fail_issue "$num" "$log_file" "copilot produced no changes (rc=$copilot_rc)"
  return 1
}

# Handle a failed issue: comment with the error details (or a log tail as a
# fallback), mark it "copilot-failed", and clean up the branch. Failures are not
# retried automatically — the issue stays failed until a later user reply resumes
# it for a fresh attempt (see claim_next_reply_issue).
_fail_issue() {
  local num="$1" log_file="$2" reason="$3" details="${4:-}"
  # Prefer explicit details (the exact failing command's output) over the raw
  # log tail, which is mostly Copilot chatter and buries the real cause.
  local block
  if [ -n "$details" ]; then
    block="$details"
  else
    block="$(tail -n 20 "$log_file" 2>/dev/null)"
  fi

  log "issue #$num: FAILED - $reason"

  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh issue comment "$num" --body "$(printf 'copilot-loop failed: %s\n\n```\n%s\n```\n\n%s' \
    "$reason" "$block" "$FAILURE_MARKER")" >/dev/null 2>&1 || true

  # Stop here: mark the issue failed instead of re-queuing it, so a repeatedly
  # failing issue can never be retried in an endless loop.
  gh issue edit "$num" --add-label "$FAILED_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
  cleanup_workspace "$branch"
}

# --- Issue files: create GitHub issues from markdown in issues/ --------------
# Each *.md file in ISSUES_DIR becomes one GitHub issue: the first H1 line is
# the title and everything after it is the body. A file is claimed by renaming
# "<name>.md" -> "<name>_pushing.md" before the issue is created, then deleted
# once the issue exists. By default created issues get the trigger label so the
# loop below picks them up; a "Label:" directive in the body overrides this (see
# issue_labels), including "Label: none" to file an unlabelled backlog issue that
# the loop leaves alone. If ISSUES_DIR is missing it is created with a
# TEMPLATE.md example, which is never turned into an issue.
#
# issue_labels is pure and covered by tests/issue-labels.test.sh (extracted
# between the markers), so keep the marker comments intact.
# >>> issue-label helpers >>>
# Decide the label(s) for an issue created from a markdown file. Reads an
# optional "Label:"/"Labels:" directive (first matching line wins, the key is
# case-insensitive) from the body and echoes the labels to apply as a
# comma-separated list. With no directive it echoes the given default (the
# trigger label) so existing files keep entering the queue. A value of "none",
# "no-label", "no_label", "nolabel", "-", or empty means "create with no label"
# and echoes nothing. Label values are kept verbatim because GitHub label names
# are case-sensitive.
# Usage: issue_labels <body> <default-label>
issue_labels() {
  local body="$1" default="$2" line val
  line="$(printf '%s\n' "$body" | grep -m1 -iE '^[[:space:]]*labels?[[:space:]]*:' 2>/dev/null)"
  if [ -z "$line" ]; then
    printf '%s\n' "$default"
    return
  fi
  val="$(printf '%s\n' "$line" \
         | sed -E 's/^[[:space:]]*[Ll][Aa][Bb][Ee][Ll][Ss]?[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//')"
  case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
    ''|none|no-label|no_label|nolabel|-) return ;;
    *) printf '%s\n' "$val" ;;
  esac
}
# <<< issue-label helpers <<<

process_issue_files() {
  if [ ! -d "$ISSUES_DIR" ]; then
    mkdir -p "$ISSUES_DIR" || { log "issue files: could not create $ISSUES_DIR"; return; }
    cat >"$ISSUES_DIR/TEMPLATE.md" <<'EOF'
# Title

Describe the task here. The first "# " heading becomes the issue title and
everything below it becomes the issue body.

Copy this file to a new name ending in .md and edit it; the copilot loop opens
a GitHub issue from it (labelled "ready") and then deletes the file.

Add a line like "Label: bug" to override the label, or "Label: none" to file the
issue with no label at all (an unlabelled backlog item the loop leaves alone).
List several with "Labels: bug, enhancement".

Add a line like "Wait for: #1" to hold this issue until issue #1 is closed
(resolved and merged). List several ("Wait for: #1, #2") and use "Blocked by:"
or "Depends on:" if you prefer. While it waits the issue is labelled "pending".
EOF
    log "issue files: created $ISSUES_DIR with TEMPLATE.md"
    return
  fi

  local f base pushing title body
  for f in "$ISSUES_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"

    # Never turn the template into an issue.
    [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = "template.md" ] && continue

    # Claim the file by renaming it, unless a previous run already claimed it.
    case "$base" in
      *_pushing.md) pushing="$f" ;;
      *)
        pushing="${f%.md}_pushing.md"
        if ! mv "$f" "$pushing" 2>/dev/null; then
          log "issue files: could not claim $base"
          continue
        fi
        log "issue files: claimed $base -> $(basename "$pushing")"
        ;;
    esac

    # Title: first H1 heading; fall back to the file name.
    title="$(grep -m1 -E '^#[[:space:]]+' "$pushing" | sed -E 's/^#[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$title" ]; then
      title="$(basename "$pushing" .md)"
      title="${title%_pushing}"
    fi

    # Body: everything after the first H1; the whole file if there is no H1.
    if grep -qE '^#[[:space:]]+' "$pushing"; then
      body="$(awk 'seen{print} /^#[[:space:]]+/{seen=1}' "$pushing")"
    else
      body="$(cat "$pushing")"
    fi
    # Drop leading blank lines from the body.
    body="$(printf '%s\n' "$body" | sed -e '/./,$!d')"

    # Labels: honour an optional "Label:"/"Labels:" directive, defaulting to the
    # trigger label so existing files still enter the queue. An empty result
    # means the issue is created with no label at all. Custom labels are ensured
    # up front so gh does not fail on a not-yet-existing label.
    local labels l
    local -a label_args=()
    labels="$(issue_labels "$body" "$TRIGGER_LABEL")"
    if [ -n "$labels" ]; then
      local OLDIFS="$IFS"; IFS=','
      for l in $labels; do
        l="$(printf '%s' "$l" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$l" ] || continue
        ensure_label "$l" "ededed" "Applied by copilot-loop from an issue file"
        label_args+=(--label "$l")
      done
      IFS="$OLDIFS"
    fi

    local created=0
    if [ "${#label_args[@]}" -gt 0 ]; then
      gh issue create --title "$title" --body "$body" "${label_args[@]}" >/dev/null 2>&1 && created=1
    else
      gh issue create --title "$title" --body "$body" >/dev/null 2>&1 && created=1
    fi
    if [ "$created" -eq 1 ]; then
      rm -f "$pushing"
      log "issue files: created issue \"$title\" and removed $(basename "$pushing")"
    else
      log "issue files: FAILED to create issue for \"$title\" (kept $(basename "$pushing"))"
    fi
  done
}

# Mark a PR conflict-resolution attempt failed: comment a log tail, label the PR
# so it is not retried forever, and tear down the workspace.
_fail_pr() {
  local num="$1" log_file="$2" reason="$3" tail_out
  log "PR #$num: FAILED to resolve conflicts - $reason"
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh pr comment "$num" --body "$(printf 'copilot-loop could not resolve merge conflicts: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  cleanup_workspace "$head"
}

# Mark a PR failing-checks fix attempt failed: comment a log tail, label the PR
# so it is not retried forever, and tear down the workspace. Mirrors _fail_pr.
_fail_pr_checks() {
  local num="$1" log_file="$2" reason="$3" tail_out
  log "PR #$num: FAILED to fix failing checks - $reason"
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh pr comment "$num" --body "$(printf 'copilot-loop could not fix the failing checks: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh pr edit "$num" --add-label "$CHECKS_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  cleanup_workspace "$head"
}

# Copilot needs more information: post its question to the issue, mark it
# "needs-info", and leave it for the user to answer. Discards any work in
# progress so the branch is clean for the eventual resume.
_ask_issue() {
  local num="$1" qf="$2" question
  question="$(cat "$qf" 2>/dev/null)"
  log "issue #$num: needs more info, asking the user on the issue"
  gh issue comment "$num" \
    --body "$(printf '**copilot-loop needs more information to continue:**\n\n%s\n\n%s' \
      "$question" "$QUESTION_MARKER")" >/dev/null 2>&1 || true
  gh issue edit "$num" --add-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  rm -f "$qf"
  cleanup_workspace "$branch"
}

# --- Issue dependencies: "Wait for: #N" --------------------------------------
# An issue can declare that it must not be started until one or more other
# issues are finished by putting a line like "Wait for: #1" in its body. The
# loop then keeps that issue in the queue until every issue it names is CLOSED.
# A PR that closes the blocker, once merged, closes the issue, so CLOSED is
# exactly "resolved and merged". "Blocked by:" and "Depends on:" are accepted
# as synonyms, several "#N" may be listed on one line, and matching is
# case-insensitive. While an issue is held back this way it is labelled
# "pending" so the wait is visible in GitHub; the label is removed once every
# dependency closes (or the issue is claimed for work).
#
# The two functions below are covered by tests/wait-for.test.sh, which extracts
# them between the markers, so keep the marker comments intact.
# >>> wait-for helpers >>>
# Echo, one per line (ascending, de-duplicated), the issue numbers a body
# declares it is waiting for. Empty output means no declared dependencies.
issue_wait_for() {
  local body="$1"
  printf '%s\n' "$body" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -nE 's/^.*(wait[[:space:]]+for|blocked[[:space:]]+by|depends[[:space:]]+on)[[:space:]]*:?[[:space:]]*//p' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | sort -n -u
}

# Echo, one per line, the still-open issues that block the given issue: those it
# declares it is waiting for that are not yet CLOSED. Self-references and issue
# numbers that cannot be looked up are ignored so the queue can never wedge on a
# stale or bad reference. Empty output means nothing is blocking.
# Usage: issue_open_blockers <self-number> <body>
issue_open_blockers() {
  local self="$1" body="$2" dep state
  for dep in $(issue_wait_for "$body"); do
    [ "$dep" = "$self" ] && continue
    state="$(gh issue view "$dep" --json state --jq '.state' 2>/dev/null)"
    [ "$state" = "OPEN" ] && printf '%s\n' "$dep"
  done
}
# <<< wait-for helpers <<<

# Format a whitespace-separated list of issue numbers as "#1, #2" for logs.
_fmt_blockers() {
  local b out=""
  for b in $1; do
    if [ -n "$out" ]; then out="$out, #$b"; else out="#$b"; fi
  done
  printf '%s' "$out"
}

# --- Pending label: mark issues waiting on a dependency ----------------------
# An issue held back by an open dependency ("Wait for: #N") is labelled
# "pending" so the wait is visible in GitHub without reading the body. The
# label is reconciled every loop pass and removed as soon as every dependency
# has closed (or the issue is claimed for work).
#
# pending_action is pure and covered by tests/pending-label.test.sh (extracted
# between the markers), so keep the marker comments intact.
# >>> pending-label helpers >>>
# Decide what to do with the pending label for one issue. Inputs: <blockers>
# (non-empty when the issue is waiting on at least one open dependency) and
# <has_pending> ("true" when it already carries the label). Echoes "add" when
# it should gain the label, "remove" when it should lose it, and nothing when
# it is already in the right state.
pending_action() {
  local blockers="$1" has_pending="$2"
  if [ -n "$blockers" ] && [ "$has_pending" != "true" ]; then
    printf 'add\n'
  elif [ -z "$blockers" ] && [ "$has_pending" = "true" ]; then
    printf 'remove\n'
  fi
}
# <<< pending-label helpers <<<

# Reconcile the pending label across the whole open working set (issues carrying
# the trigger, needs-info or failed label) so it always reflects reality: mark
# an issue "pending" while it waits for an open dependency and unmark it once
# nothing blocks it. Only issues whose state actually changed are edited, and gh
# failures never abort the loop. Relies on issue_open_blockers and pending_action.
reconcile_pending_labels() {
  local nums n body blockers has_pending
  nums="$( { gh issue list --state open --label "$TRIGGER_LABEL"    --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$NEEDS_INFO_LABEL" --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$FAILED_LABEL"     --limit 1000 --json number --jq '.[].number' 2>/dev/null; } \
           | sort -n -u )"
  for n in $nums; do
    body="$(gh issue view "$n" --json body --jq '.body' 2>/dev/null)"
    blockers="$(issue_open_blockers "$n" "$body")"
    has_pending="$(gh issue view "$n" --json labels \
                    --jq 'any(.labels[]; .name == "'"$PENDING_LABEL"'")' 2>/dev/null)"
    case "$(pending_action "$blockers" "$has_pending")" in
      add)
        gh issue edit "$n" --add-label "$PENDING_LABEL" >/dev/null 2>&1 || true
        log "issue #$n: waiting for $(_fmt_blockers "$blockers") to close; marked $PENDING_LABEL" ;;
      remove)
        gh issue edit "$n" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
        log "issue #$n: dependencies resolved; removed $PENDING_LABEL" ;;
    esac
  done
}

# Atomically find and claim the next ready issue, protected by GitHub lock.
# Returns the issue number on success, empty string if none available.
# This prevents multiple instances from selecting the same issue.
claim_next_ready_issue() {
  local n body blockers issue=""
  acquire_github_lock || return 1

  # Ready issues oldest first (lowest number == earliest created). Fetch each
  # issue's body in the same list call (NUL-separated number/body pairs) so we no
  # longer spend one `gh issue view` per queued issue. Walk them in order and
  # claim the first that is not blocked by an unresolved dependency (see
  # issue_open_blockers). A blocked issue keeps its trigger label so it is
  # reconsidered on a later pass once its blockers close.
  while IFS= read -r -d '' n && IFS= read -r -d '' body; do
    blockers="$(issue_open_blockers "$n" "$body")"
    if [ -n "$blockers" ]; then
      log "issue #$n: blocked, waiting for $(_fmt_blockers "$blockers") to close; skipping" >&2
      continue
    fi
    # Claim it immediately: add in-progress, remove trigger labels.
    # Do this WHILE HOLDING THE LOCK so no other instance can select it.
    issue="$n"
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$TRIGGER_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
    break
  # Emit one joined string, not a stream: gh/jq append a newline after every
  # streamed result, and with NUL-delimited records that newline leaks into the
  # front of the next number field ("\n12"), corrupting the branch name and
  # failing every issue after the first. join("") keeps the stream NUL-only.
  done < <(gh issue list --state open --label "$TRIGGER_LABEL" --limit 1000 \
             --json number,body \
             --jq 'sort_by(.number) | [.[] | (.number|tostring) + "\u0000" + (.body // "") + "\u0000"] | join("")' 2>/dev/null)

  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}

# Log the open issues currently carrying the trigger label (the ready queue),
# oldest first, so the operator can see the backlog before the next issue is
# claimed. Informational only and silent when the queue is empty (the later
# "no ready issues" message covers that case); safe to call without the lock.
log_ready_issues() {
  local lines count
  lines="$(gh issue list --state open --label "$TRIGGER_LABEL" \
             --limit 1000 --json number,title \
             --jq 'sort_by(.number) | .[] | "#\(.number) \(.title)"' 2>/dev/null)"
  [ -n "$lines" ] || return 0
  count="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
  log "ready issues ($count):"
  printf '%s\n' "$lines" | while IFS= read -r line; do
    log "  $line"
  done
}

# Atomically find and claim the next reply issue, protected by GitHub lock.
# Handles both "needs-info" (a pending question) and "copilot-failed" (a failed
# issue) whose latest comment came from a human. Returns the issue number on
# success, empty string if none available.
claim_next_reply_issue() {
  [ -n "$BOT_LOGIN" ] || return 1
  
  local nums n last_author body blockers issue=""
  acquire_github_lock || return 1
  
  # Both labels mean "blocked, waiting on the user"; a human reply resumes them.
  # Sorted ascending (by number == creation order) so oldest replied issue first.
  nums="$( { gh issue list --state open --label "$NEEDS_INFO_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$FAILED_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null; } \
           | sort -n -u )"
  for n in $nums; do
    # One view call per candidate for both the last comment's author and the
    # body (NUL-separated) instead of two separate `gh issue view` calls.
    { IFS= read -r -d '' last_author; IFS= read -r -d '' body; } < <(
      gh issue view "$n" --json comments,body \
        --jq '[(.comments[-1].author.login // ""), (.body // "")] | join("\u0000")' 2>/dev/null)
    if [ -z "$last_author" ] || [ "$last_author" = "$BOT_LOGIN" ]; then continue; fi
    # Honour the same dependency gate as fresh issues: do not resume an issue
    # while an issue it declares it is waiting for is still open.
    blockers="$(issue_open_blockers "$n" "$body")"
    if [ -n "$blockers" ]; then
      log "issue #$n: replied but blocked, waiting for $(_fmt_blockers "$blockers") to close; skipping" >&2
      continue
    fi
    # Found one; claim it before releasing the lock
    issue="$n"
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$FAILED_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
    break
  done
  
  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}

# --- Core: resolve merge conflicts on a single PR ---------------------------
# Merges the PR's base branch into its head branch; if that conflicts, hands the
# conflicted files to Copilot to resolve, then commits and pushes so the PR
# becomes mergeable again. Returns 0 on success, 1 on failure.
resolve_pr_conflicts() {
  local num="$1"
  local head base title log_file conflicts copilot_rc

  # One API round-trip for the PR's head branch, base branch and title (all
  # single-line) instead of three separate `gh pr view` calls.
  { IFS= read -r -d '' head; IFS= read -r -d '' base; IFS= read -r -d '' title; } < <(
    gh pr view "$num" --json headRefName,baseRefName,title \
      --jq '[.headRefName, .baseRefName, .title] | join("\u0000")' 2>/dev/null)
  [ -n "$base" ] || base="$DEFAULT_BRANCH"
  log_file="$LOG_DIR/pr-${num}-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-PR log so the TUI's output panel
  # shows the loop's narration alongside Copilot's transcript (#126). Cleared at
  # the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  if [ -z "$head" ]; then
    log "PR #$num: could not determine head branch, skipping"
    gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
    gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    return 1
  fi

  log "PR #$num has conflicts with $base: $title"

  # Base a fresh workspace on the PR head branch, without ever checking out the
  # default branch. Then merge the base branch into it so any conflicts surface
  # here for Copilot to resolve.
  git -C "$REPO_DIR" fetch origin >>"$log_file" 2>&1 || true
  if ! prepare_workspace "$head" "origin/$head"; then
    _fail_pr "$num" "$log_file" "could not check out PR head branch '$head'"
    return 1
  fi

  # Surface the PR branch on the terminal tab/window title before Copilot starts.
  log "PR #$num: working on branch $head"
  set_terminal_title "$head"

  # Merge the base branch. A clean merge means the conflict was already resolved
  # upstream; otherwise git leaves conflict markers for Copilot to fix.
  if git -C "$WORKSPACE_DIR" merge --no-edit "origin/$base" >>"$log_file" 2>&1; then
    log "PR #$num: merged $base with no conflicts to resolve"
  else
    conflicts="$(git -C "$WORKSPACE_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
    log "PR #$num: resolving conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')"

    local prompt
    prompt="$(cat <<EOF
You are working in a git repository. Merging branch "${base}" into branch
"${head}" (pull request #${num}) produced conflicts that must be resolved.

These files contain git conflict markers (<<<<<<<, =======, >>>>>>>):
${conflicts}

Resolve every conflict so the result is correct and preserves the intent of both
branches, then remove all conflict markers. Run any build or test commands needed
to verify your work. Do NOT run git commit, git merge, git push, or create
branches — those steps are handled automatically outside this session. Only edit
files to resolve the conflicts and verify.
EOF
)"
    local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
    [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

    log "PR #$num: running copilot to resolve conflicts (log: $log_file)"
    if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
      _fail_pr "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
      return 1
    fi
    run_copilot "$log_file" "${copilot_args[@]}"
    copilot_rc=$COPILOT_RC
    cd "$REPO_DIR" 2>/dev/null || true
    log "PR #$num: copilot exited with code $copilot_rc"

    # Track what this conflict-resolution prompt cost on the PR.
    _report_usage pr "$num" "$log_file" "$COPILOT_MODEL"

    # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt.
    if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
      _fail_pr "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
      return 1
    fi

    # Bail out if Copilot left conflict markers behind in any conflicted file.
    local f unresolved=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$WORKSPACE_DIR/$f" ] && grep -qE '^(<{7}|>{7})' "$WORKSPACE_DIR/$f" && unresolved="$unresolved $f"
    done <<< "$conflicts"
    if [ -n "$unresolved" ]; then
      _fail_pr "$num" "$log_file" "conflict markers still present in:$unresolved"
      return 1
    fi

    git -C "$WORKSPACE_DIR" add -A
    git -C "$WORKSPACE_DIR" commit --no-edit >/dev/null 2>&1 \
      || git -C "$WORKSPACE_DIR" commit -m "Merge $base into $head to resolve conflicts (#$num)" >/dev/null 2>&1
  fi

  if ! git -C "$WORKSPACE_DIR" push origin "HEAD:$head" >>"$log_file" 2>&1; then
    _fail_pr "$num" "$log_file" "git push failed"
    return 1
  fi

  gh pr comment "$num" \
    --body "copilot-loop resolved the merge conflicts with \`$base\`." >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  log "PR #$num: conflicts resolved and pushed"
  cleanup_workspace "$head"
  return 0
}

# Echo, comma-joined, the names of a PR's failing CI checks (an empty string when
# none). A check is failing when it is a completed CheckRun with a failing
# conclusion or a StatusContext in a failing state — the same predicate
# next_failing_checks_pr selects on.
pr_failing_check_names() {
  local num="$1"
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell expansion — keep single quotes
  gh pr view "$num" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]? as $c
      | select(
          ($c.__typename == "CheckRun" and (["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c.conclusion)))
          or ($c.__typename == "StatusContext" and (["FAILURE","ERROR"] | index($c.state)))
        )
      | ($c.name // $c.context // "check")
    ] | unique | join(", ")' 2>/dev/null
}

# --- Core: fix a single PR's failing CI checks ------------------------------
# Checks out the PR head branch and hands Copilot the list of failing checks to
# investigate and fix (verifying locally), then commits and pushes so CI re-runs.
# If Copilot makes no changes it cannot fix them, so the PR is labelled
# "checks-unresolved" rather than pushed empty and re-grabbed forever. Returns 0
# on success, 1 on failure.
resolve_pr_check_failures() {
  local num="$1"
  local head base title log_file failing copilot_rc

  # One API round-trip for the PR's head branch, base branch and title.
  { IFS= read -r -d '' head; IFS= read -r -d '' base; IFS= read -r -d '' title; } < <(
    gh pr view "$num" --json headRefName,baseRefName,title \
      --jq '[.headRefName, .baseRefName, .title] | join("\u0000")' 2>/dev/null)
  [ -n "$base" ] || base="$DEFAULT_BRANCH"
  log_file="$LOG_DIR/pr-${num}-checks-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-PR log so the TUI's output panel
  # shows the loop's narration alongside Copilot's transcript (#126). Cleared at
  # the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  if [ -z "$head" ]; then
    log "PR #$num: could not determine head branch, skipping"
    gh pr edit "$num" --add-label "$CHECKS_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
    gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    return 1
  fi

  failing="$(pr_failing_check_names "$num")"
  log "PR #$num has failing checks (${failing:-unknown}): $title"

  # Base a fresh workspace on the PR head branch, without ever checking out the
  # default branch, so Copilot fixes the failures on the PR's own branch.
  git -C "$REPO_DIR" fetch origin >>"$log_file" 2>&1 || true
  if ! prepare_workspace "$head" "origin/$head"; then
    _fail_pr_checks "$num" "$log_file" "could not check out PR head branch '$head'"
    return 1
  fi

  # Surface the PR branch on the terminal tab/window title before Copilot starts.
  log "PR #$num: working on branch $head"
  set_terminal_title "$head"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository on branch "${head}" (pull request #${num}).
Its continuous-integration checks are failing: ${failing:-unknown}.

Investigate why these checks fail and fix the code so they pass. Run the relevant
build, test, or lint commands locally to reproduce each failure and confirm your
fix. Do NOT run git commit, git push, or create branches — those steps are handled
automatically outside this session. Only edit files and verify.
EOF
)"
  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  log "PR #$num: running copilot to fix failing checks (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    _fail_pr_checks "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
    return 1
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "PR #$num: copilot exited with code $copilot_rc"

  # Track what this fix prompt cost on the PR.
  _report_usage pr "$num" "$log_file" "$COPILOT_MODEL"

  # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt.
  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    _fail_pr_checks "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
    return 1
  fi

  # No changes means Copilot could not fix the checks. Give up (label so it is not
  # retried forever) instead of pushing an empty commit and re-grabbing next pass.
  if [ -z "$(git -C "$WORKSPACE_DIR" status --porcelain 2>/dev/null)" ]; then
    _fail_pr_checks "$num" "$log_file" "copilot made no changes to fix the failing checks"
    return 1
  fi

  git -C "$WORKSPACE_DIR" add -A
  if ! git -C "$WORKSPACE_DIR" commit -m "Fix failing checks on $head (#$num)" >/dev/null 2>&1; then
    _fail_pr_checks "$num" "$log_file" "git commit failed"
    return 1
  fi

  if ! git -C "$WORKSPACE_DIR" push origin "HEAD:$head" >>"$log_file" 2>&1; then
    _fail_pr_checks "$num" "$log_file" "git push failed"
    return 1
  fi

  gh pr comment "$num" \
    --body "copilot-loop pushed a fix for the failing checks (${failing:-unknown})." >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  log "PR #$num: pushed a fix for failing checks"
  cleanup_workspace "$head"
  return 0
}

# >>> mergeability helpers >>>
# GitHub computes a PR's mergeable state asynchronously: right after a PR is
# opened, pushed to, or its base branch moves, `mergeable` is reported as UNKNOWN
# until a background job finishes. next_conflicted_pr only matches CONFLICTING, so
# a PR that is really in conflict but not yet evaluated would be skipped and the
# loop would start a ready issue with the conflict still open. Waiting here for
# GitHub to finish computing makes the "resolve conflicts before picking up new
# work" guarantee reliable instead of racing the evaluation.

# Echo the numbers (one per line) of open PRs targeting the default branch whose
# mergeability GitHub has not finished computing (UNKNOWN). Empty output means
# every open PR has been evaluated.
unknown_mergeability_prs() {
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable \
    --jq '.[] | select(.mergeable == "UNKNOWN") | .number' 2>/dev/null
}

# Block (bounded) until no open PR is left with UNKNOWN mergeability, so the
# conflict check that follows sees accurate state. Each pass nudges GitHub to
# (re)compute every still-unknown PR by viewing it — the documented way to force
# the background evaluation. MERGEABILITY_WAIT_ATTEMPTS=0 disables the wait and a
# PR stuck UNKNOWN never blocks the loop past the attempt budget.
ensure_pr_mergeability_known() {
  local attempts="$MERGEABILITY_WAIT_ATTEMPTS" delay="$MERGEABILITY_WAIT_SECONDS"
  local i unknown count n
  [ "$attempts" -gt 0 ] 2>/dev/null || return 0
  for (( i=1; i<=attempts; i++ )); do
    unknown="$(unknown_mergeability_prs)"
    [ -n "$unknown" ] || return 0
    count="$(printf '%s\n' "$unknown" | grep -c .)"
    log "waiting for GitHub to compute mergeability of $count open PR(s) before the conflict check (attempt $i/$attempts)"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      gh pr view "$n" --json mergeable >/dev/null 2>&1 || true
    done <<< "$unknown"
    [ "$i" -lt "$attempts" ] && sleep "$delay"
  done
  return 0
}
# <<< mergeability helpers <<<

# >>> conflict-pr helpers >>>
# Echo the number of the lowest-numbered open PR targeting the default branch
# whose merge is CONFLICTING, skipping any already marked unresolved or already
# claimed (in-progress) by another instance. Returns 1 (no output) when no PR
# needs conflict resolution.
next_conflicted_pr() {
  local jq_filter
  jq_filter='[.[] | select(.mergeable == "CONFLICTING")'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CONFLICT_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$INPROGRESS_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | .number] | sort | .[0] // empty'
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable,labels --jq "$jq_filter" 2>/dev/null
}

# Atomically select and claim the next conflicted PR, protected by the GitHub
# lock, so two instances never resolve the same PR (which would collide on the
# shared worktree path and race each other's pushes). Marks the PR in-progress
# while holding the lock; the resolve/fail paths clear that label. Echoes the PR
# number on success, nothing when there is no PR to work.
claim_next_conflicted_pr() {
  local pr=""
  acquire_github_lock || return 1
  pr="$(next_conflicted_pr)"
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  fi
  release_github_lock
  [ -n "$pr" ] && printf '%s\n' "$pr"
  [ -n "$pr" ]
}
# <<< conflict-pr helpers <<<

# >>> failing-checks-pr helpers >>>
# Echo the number of the lowest-numbered open PR targeting the default branch
# whose CI checks are failing, skipping any that is conflicting (handled by the
# conflict path first), already marked unresolved (conflict or checks), or already
# claimed (in-progress) by another instance. A check is failing when it is a
# completed CheckRun with a failing conclusion or a StatusContext in a failing
# state — pending/successful/skipped checks are ignored so a PR whose CI is still
# running is left alone. Returns 1 (no output) when no PR needs a check fix.
next_failing_checks_pr() {
  local jq_filter
  jq_filter='[.[] | select(.mergeable != "CONFLICTING")'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CHECKS_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CONFLICT_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$INPROGRESS_LABEL"'")) | not)'
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell expansion — keep single quotes
  jq_filter="$jq_filter"' | select([.statusCheckRollup[]? as $c | select(($c.__typename == "CheckRun" and (["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c.conclusion))) or ($c.__typename == "StatusContext" and (["FAILURE","ERROR"] | index($c.state))))] | length > 0)'
  jq_filter="$jq_filter"' | .number] | sort | .[0] // empty'
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable,labels,statusCheckRollup --jq "$jq_filter" 2>/dev/null
}

# Atomically select and claim the next PR with failing checks, protected by the
# GitHub lock, so two instances never fix the same PR (which would collide on the
# shared worktree path and race each other's pushes). Marks the PR in-progress
# while holding the lock; the resolve/fail paths clear that label. Echoes the PR
# number on success, nothing when there is no PR to work.
claim_next_failing_pr() {
  local pr=""
  acquire_github_lock || return 1
  pr="$(next_failing_checks_pr)"
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  fi
  release_github_lock
  [ -n "$pr" ] && printf '%s\n' "$pr"
  [ -n "$pr" ]
}
# <<< failing-checks-pr helpers <<<

# --- Self-update: pull the loop code and restart when it changed --------------
# Before tackling each iteration, refresh this script from the default branch so
# the loop always runs the latest code. When the upstream copy differs from the
# committed baseline, fast-forward the checkout (or refresh just this file when
# the default branch is not checked out) and re-exec. No-op when self-update is
# off, the script is untracked, or nothing changed upstream. Never clobbers local
# uncommitted edits to the script.
self_update() {
  [ "$SELF_UPDATE" = 1 ] || return 0
  [ -n "$SCRIPT_REL" ] || return 0

  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || return 0
  local upstream="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$upstream" >/dev/null 2>&1 || return 0

  # Has the script changed upstream? Compare the committed baseline (the local
  # default branch, or HEAD when it is absent) with the upstream copy, so local
  # uncommitted edits to the script never trigger a restart on their own.
  local local_ref="refs/heads/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 || local_ref="HEAD"
  local base_hash new_hash
  base_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${local_ref}:${SCRIPT_REL}" 2>/dev/null || true)"
  new_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${upstream}:${SCRIPT_REL}" 2>/dev/null || true)"
  [ -n "$new_hash" ] || return 0
  [ "$new_hash" != "$base_hash" ] || return 0

  log "loop code changed on $DEFAULT_BRANCH upstream; updating and restarting"

  local cur_branch updated=0
  cur_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ "$cur_branch" = "$DEFAULT_BRANCH" ]; then
    # On the default branch: fast-forward the whole checkout. git refuses (safely)
    # when local changes would be overwritten, leaving the running code intact.
    git -C "$REPO_DIR" merge --ff-only "$upstream" >/dev/null 2>&1 && updated=1
  fi

  if [ "$updated" != 1 ]; then
    # Default branch not checked out (e.g. detached in --no-worktrees mode) or the
    # fast-forward was refused: refresh just this script, but never clobber local
    # uncommitted edits to it.
    local work_hash head_hash
    work_hash="$(git hash-object "$SCRIPT_PATH" 2>/dev/null || true)"
    head_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "HEAD:${SCRIPT_REL}" 2>/dev/null || true)"
    if [ -n "$head_hash" ] && [ -n "$work_hash" ] && [ "$work_hash" != "$head_hash" ]; then
      log "local changes to $SCRIPT_REL; skipping self-update"
      return 0
    fi
    local tmp="${SCRIPT_PATH}.selfupdate.$$"
    if ! git -C "$REPO_DIR" show "${upstream}:${SCRIPT_REL}" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    chmod +x "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$SCRIPT_PATH" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    # Advance the local default branch pointer when it fast-forwards, so the next
    # iteration sees the baseline as current instead of re-detecting the change.
    if [ "$local_ref" = "refs/heads/${DEFAULT_BRANCH}" ] \
       && git -C "$REPO_DIR" merge-base --is-ancestor "refs/heads/${DEFAULT_BRANCH}" "$upstream" 2>/dev/null; then
      git -C "$REPO_DIR" branch -f "$DEFAULT_BRANCH" "$upstream" >/dev/null 2>&1 || true
    fi
  fi

  release_github_lock
  log "restarting loop with updated code"
  exec "$SCRIPT_PATH" ${SELF_ARGS[@]+"${SELF_ARGS[@]}"}
}

# --- Sync: bring the local default branch up to date with the remote ---------
# Before starting any new work, sync the local default branch with
# origin/<default> so the loop's baseline matches the remote. A clean update is a
# fast-forward; when the local default branch has diverged (it carries commits
# that conflict with what landed on the remote) the merge is handed to Copilot to
# resolve so the loop can move forward instead of stalling on a stale branch. The
# resolved merge is kept local only — the loop never pushes the default branch
# (pull requests do that). Best effort: any inability to sync is logged and the
# loop carries on, and an identical divergence Copilot already failed to resolve
# is skipped (marker) so it is not re-run every pass.
#
# classify_sync_state is pure and, with sync_default_branch, is covered by
# tests/sync-default-branch.test.sh between the markers — keep them intact.
# >>> sync-default helpers >>>
# classify_sync_state <upstream_is_ancestor_of_local> <local_is_ancestor_of_upstream>
# Classify how the local default branch relates to its upstream from the two
# `git merge-base --is-ancestor` outcomes (each "yes" when the ancestor test
# passed, anything else means no):
#   insync   - upstream already contained locally (equal, or local ahead): nothing to pull
#   ff       - local strictly behind upstream with no divergence: fast-forward
#   diverged - each side has unique commits: a real merge that may conflict
# Pure string logic so it can be unit tested without git.
classify_sync_state() {
  case "$1" in yes) printf 'insync'; return ;; esac
  case "$2" in yes) printf 'ff';     return ;; esac
  printf 'diverged'
}

sync_default_branch() {
  [ "$SYNC_REMOTE" = 1 ] || return 0

  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || return 0
  local upstream="origin/${DEFAULT_BRANCH}" local_ref="refs/heads/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$upstream"  >/dev/null 2>&1 || return 0
  # Nothing to sync when there is no local default branch (e.g. a detached or
  # bare-worktree layout) — new work still bases off the fresh origin/<default>.
  git -C "$REPO_DIR" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 || return 0

  local upstream_anc=no local_anc=no state
  git -C "$REPO_DIR" merge-base --is-ancestor "$upstream" "$local_ref" >/dev/null 2>&1 && upstream_anc=yes
  git -C "$REPO_DIR" merge-base --is-ancestor "$local_ref" "$upstream" >/dev/null 2>&1 && local_anc=yes
  state="$(classify_sync_state "$upstream_anc" "$local_anc")"
  [ "$state" = insync ] && return 0

  local cur_branch
  cur_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

  if [ "$state" = ff ]; then
    # No divergence: fast-forward the checkout when the default branch is checked
    # out here, otherwise just advance the local ref (safe, no working-tree move).
    if [ "$cur_branch" = "$DEFAULT_BRANCH" ]; then
      git -C "$REPO_DIR" merge --ff-only "$upstream" >/dev/null 2>&1 \
        && log "synced $DEFAULT_BRANCH with origin (fast-forward)"
    else
      git -C "$REPO_DIR" branch -f "$DEFAULT_BRANCH" "$upstream" >/dev/null 2>&1 \
        && log "synced $DEFAULT_BRANCH with origin (fast-forward)"
    fi
    return 0
  fi

  # Diverged. Resolving means merging in the default branch's working tree, so we
  # only do it when the default branch is the checkout the loop owns (REPO_DIR);
  # when it is checked out elsewhere we must not touch that tree.
  if [ "$cur_branch" != "$DEFAULT_BRANCH" ]; then
    log "$DEFAULT_BRANCH has diverged from origin but is not checked out here; skipping sync"
    return 0
  fi

  # Skip a divergence we already handed to Copilot and could not resolve, until
  # either side moves, so an unresolvable conflict is not re-run every pass.
  local local_sha upstream_sha marker
  local_sha="$(git -C "$REPO_DIR" rev-parse "$local_ref" 2>/dev/null)"
  upstream_sha="$(git -C "$REPO_DIR" rev-parse "$upstream" 2>/dev/null)"
  marker="$WORK_DIR/sync-unresolved"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "${local_sha} ${upstream_sha}" ]; then
    return 0
  fi

  log "$DEFAULT_BRANCH has diverged from origin; syncing"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local log_file
  log_file="$LOG_DIR/sync-$(date '+%Y%m%d-%H%M%S').log"

  # A clean merge means there was nothing to resolve; a failed one leaves conflict
  # markers for Copilot (or failed for another reason, handled below).
  if git -C "$REPO_DIR" merge --no-edit "$upstream" >>"$log_file" 2>&1; then
    rm -f "$marker"
    log "synced $DEFAULT_BRANCH with origin (merged, no conflicts)"
    return 0
  fi

  local conflicts
  conflicts="$(git -C "$REPO_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
  if [ -z "$conflicts" ]; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "could not sync $DEFAULT_BRANCH with origin; leaving it unchanged"
    return 0
  fi
  log "resolving $DEFAULT_BRANCH sync conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository. Merging the remote branch
"origin/${DEFAULT_BRANCH}" into the local "${DEFAULT_BRANCH}" branch produced
conflicts that must be resolved before the automation can continue.

These files contain git conflict markers (<<<<<<<, =======, >>>>>>>):
${conflicts}

Resolve every conflict so the result is correct and preserves the intent of both
sides, then remove all conflict markers. Run any build or test commands needed to
verify your work. Do NOT run git commit, git merge, git push, or create
branches — those steps are handled automatically outside this session. Only edit
files to resolve the conflicts and verify.
EOF
)"
  local -a copilot_args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  if ! cd "$REPO_DIR" 2>/dev/null; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "could not enter $REPO_DIR to resolve $DEFAULT_BRANCH sync conflicts; leaving it unchanged"
    return 0
  fi
  log "running copilot to resolve $DEFAULT_BRANCH sync conflicts (log: $log_file)"
  run_copilot "$log_file" "${copilot_args[@]}"
  log "copilot exited with code $COPILOT_RC while resolving $DEFAULT_BRANCH sync"

  # Bail if Copilot left conflict markers behind; record the divergence so we do
  # not re-run it on the identical local/upstream pair next pass.
  local f unresolved=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_DIR/$f" ] && grep -qE '^(<{7}|>{7})' "$REPO_DIR/$f" && unresolved="$unresolved $f"
  done <<< "$conflicts"
  if [ -n "$unresolved" ]; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    printf '%s %s\n' "$local_sha" "$upstream_sha" >"$marker" 2>/dev/null || true
    log "could not resolve $DEFAULT_BRANCH sync conflicts (markers left in:$unresolved); leaving it unchanged"
    return 0
  fi

  # Stage exactly the resolved conflict files (non-conflicted merge changes are
  # already staged) so untracked files in the checkout are never swept into the
  # merge commit, then complete the merge locally without pushing.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$REPO_DIR" add -- "$f" >/dev/null 2>&1 || true
  done <<< "$conflicts"
  if git -C "$REPO_DIR" commit --no-edit >/dev/null 2>&1 \
     || git -C "$REPO_DIR" commit -m "Merge origin/${DEFAULT_BRANCH} into ${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    rm -f "$marker"
    log "resolved $DEFAULT_BRANCH sync conflicts with origin (kept local, not pushed)"
  else
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "failed to commit resolved $DEFAULT_BRANCH sync; leaving it unchanged"
  fi
  return 0
}
# <<< sync-default helpers <<<

# --- Main loop ---------------------------------------------------------------
while true; do
  # Each iteration's setup and queue-scanning logs belong to the loop itself, not
  # to any one run, so drop the per-run mirror before the next run claims it
  # (#126). process_issue / resolve_pr_* re-arm it once they know their log file.
  CURRENT_RUN_LOG=""

  # Keep the loop current before starting any new work: pull the default branch
  # and re-exec if this script changed upstream.
  self_update

  # Sync the local default branch with the remote so new work starts from the
  # latest baseline; a diverged merge conflict is handed to Copilot to resolve.
  sync_default_branch

  process_issue_files

  # Reclaim disk and keep git tidy: sweep branches and worktrees whose PR has
  # merged (local and, when enabled, remote). Safe — only the loop's own merged
  # branches are removed, never the default branch or un-pushed work.
  sweep_merged_branches

  # Before starting any new task, make sure no open PR is left with merge
  # conflicts; claim one atomically if found and re-check before doing anything
  # else. Claiming under the lock stops two instances resolving the same PR.
  # First let GitHub finish computing PR mergeability so this check sees accurate
  # state instead of skipping a still-UNKNOWN PR (which would let the loop start a
  # ready issue with a conflict still open).
  ensure_pr_mergeability_known
  conflicted_pr="$(claim_next_conflicted_pr || true)"
  if [ -n "$conflicted_pr" ]; then
    log "PR #$conflicted_pr has conflicts, resolving before starting new tasks"
    resolve_pr_conflicts "$conflicted_pr" || true
    continue
  fi

  # Still before starting new work: fix any open PR whose CI checks are failing.
  # Claim one atomically (under the lock, so instances never fix the same PR) and
  # hand its failing checks to Copilot, then re-check on the next pass. Conflicts
  # are handled first above, so a conflicting PR is never grabbed here.
  failing_pr="$(claim_next_failing_pr || true)"
  if [ -n "$failing_pr" ]; then
    log "PR #$failing_pr has failing checks, fixing before starting new tasks"
    resolve_pr_check_failures "$failing_pr" || true
    continue
  fi

  # Keep the "pending" label in sync with each open issue's dependency state
  # before picking work, so an issue waiting on another ("Wait for: #N") is
  # visibly marked and one whose blockers have closed is unmarked.
  reconcile_pending_labels

  # Prefer resuming an issue where the user has answered a pending question.
  # Atomically select and claim to prevent race conditions with other instances.
  next_issue="$(claim_next_reply_issue || true)"
  if [ -n "$next_issue" ]; then
    log "issue #$next_issue: user replied, resuming"
    process_issue "$next_issue" || true
    continue
  fi

  # Show the ready queue before pulling the next issue off it, so the operator
  # can see the backlog that is about to be worked.
  log_ready_issues

  # Pick the oldest ready issue and claim it atomically.
  # This prevents multiple instances from selecting the same issue.
  next_issue="$(claim_next_ready_issue || true)"

  if [ -z "$next_issue" ]; then
    if [ -t 0 ]; then
      log "no ready issues; sleeping ${SLEEP_MINUTES}m (press 'f' to start now)"
    else
      log "no ready issues; sleeping ${SLEEP_MINUTES}m"
    fi
    if ! interruptible_sleep "$((SLEEP_MINUTES * 60))"; then
      log "'f' pressed; waking to look for work"
    fi
    continue
  fi

  process_issue "$next_issue" || true
done
