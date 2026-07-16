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
#      trigger label) so file-based tasks enter the queue below.
#   1. Before starting any new task, check open PRs targeting the default branch
#      for merge conflicts. If one is found, merge the base branch into it and
#      let Copilot resolve the conflicts, then push — so PRs stay mergeable.
#   2. Pick the next issue to work on (protected by GitHub lock):
#        a. an issue awaiting a reply ("needs-info") or a failed issue
#           ("copilot-failed") whose latest comment came from a human (the user
#           answered a question or gave more guidance) -> resume it; else
#        b. the oldest open issue with the trigger label (default: "ready").
#      Issues that declare a dependency ("Wait for: #N" in the body) are held
#      back until every issue they name is closed (see "Issue dependencies:
#      Wait for: #N" further down).
#   3. Claim it: add "in-progress", remove the trigger/"needs-info" labels
#      (done atomically by the claiming functions to prevent race conditions).
#   4. Create a fresh branch for the issue, based on the latest default branch.
#      The default branch (main/master) is never checked out for the work; when
#      the repo is used with git worktrees each issue runs in its own worktree so
#      the shared checkout is left untouched.
#   5. Run `copilot -p` (all tools, file access restricted to this repo),
#      passing the issue's comment thread so any prior Q&A is available.
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
#   7. On success label the issue "copilot-done". On failure retry automatically
#      up to MAX_ATTEMPTS times (re-queuing via the trigger label); once the
#      attempts are exhausted label it "copilot-failed". A later user reply on a
#      failed issue resumes it for another attempt.
#   8. If no issues are found, sleep and repeat. While sleeping, press 'f' to
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
#   --commit-model <model>   Cheapest model used to write the commit message
#                            from the staged diff ("off" = fixed message)
#                                                                  (default: gpt-5-mini)
#   --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
#   --quiet                  Do not stream Copilot's output to stdout; write it
#                            only to the per-run log files (the original
#                            behaviour). By default the loop streams Copilot's
#                            output live to stdout as well as the log files.
#   --worktrees / --no-worktrees
#                            Force per-issue git worktrees on/off (default: auto,
#                            on when the repo is used with git worktrees).
#   --auto-merge / --no-auto-merge
#                            Merge each PR automatically instead of leaving it for
#                            review (default: off).
#   --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
#                            (default: merge).
#   -h, --help               Show help and exit.
#
# Environment variables (equivalent to the flags above):
#   TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COMMIT_MODEL,
#   ISSUES_DIR, QUIET, USE_WORKTREES, AUTO_MERGE, MERGE_METHOD
# Plus MAX_ATTEMPTS (env-only, no flag): attempts per issue before giving up
# (default: 2).
# Plus SELF_UPDATE (env-only, no flag): set to 0 to stop the loop pulling the
# default branch and restarting when this script changes upstream (default:
# auto, on when the script is tracked in the repo it operates on).
#
set -uo pipefail

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
# Model used *only* to write the commit message from the staged diff. Kept
# separate from COPILOT_MODEL so the expensive coding model is never spent on a
# commit message: default to the cheapest model available. Set it empty (or
# "off") to skip the model call and use the deterministic fallback message.
COMMIT_MODEL="${COMMIT_MODEL:-}"
ISSUES_DIR="${ISSUES_DIR:-}"
# Stream Copilot's output live to stdout in addition to the per-run log files.
# Set QUIET=1 (or pass --quiet) to keep the original log-file-only behaviour.
QUIET="${QUIET:-}"
# Set SELF_UPDATE=0 to stop the loop pulling and restarting itself when this
# script changes upstream. Left unset it is auto-enabled whenever the script is
# a tracked file inside the repo it operates on.
SELF_UPDATE="${SELF_UPDATE:-}"
# Whether each issue gets its own git worktree instead of switching branches in
# the shared checkout. Empty means auto-detect (see below); 1/0 force it on/off.
# The default branch (main/master) is never checked out for work in either mode.
USE_WORKTREES="${USE_WORKTREES:-}"
# Merge each PR automatically instead of leaving it open for review. Off by
# default; set AUTO_MERGE=1 (or pass --auto-merge) to turn it on.
AUTO_MERGE="${AUTO_MERGE:-}"
# Merge method used when AUTO_MERGE is on: merge, squash or rebase.
MERGE_METHOD="${MERGE_METHOD:-}"

INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
FAILED_LABEL="copilot-failed"
NEEDS_INFO_LABEL="needs-info"
# Marks a PR whose conflicts the loop tried and failed to resolve, so it is not
# retried forever. Remove it by hand to let the loop try again.
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"

# Hidden marker appended to comments the loop posts when asking the user a
# question, so they are easy to recognise in the thread.
QUESTION_MARKER="<!-- copilot-loop:needs-info -->"

# Hidden marker on every failure comment so the loop can count how many times an
# issue has already failed and cap the automatic retries at MAX_ATTEMPTS.
FAILURE_MARKER="<!-- copilot-loop:failed -->"

# --- Helpers -----------------------------------------------------------------
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
  --commit-model <model>   Cheapest model used to write the commit message from
                           the staged diff; "off" uses a fixed message
                                                                  (default: gpt-5-mini)
  --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
  --quiet                  Do not stream Copilot's output to stdout; write it
                           only to the per-run log files (the original
                           behaviour). By default the loop streams Copilot's
                           output live to stdout as well as the log files.
  --worktrees              Give every issue its own git worktree (never touch
                           the shared checkout). Default: auto (on when the repo
                           is used with git worktrees).
  --no-worktrees           Work in the current checkout instead of per-issue
                           worktrees. The default branch is still never checked
                           out for work; the issue branch is created directly.
  --auto-merge             Merge every PR automatically (GitHub auto-merge when
                           the repo allows it, otherwise an immediate merge) so
                           no manual review is needed. Default: off.
  --no-auto-merge          Leave PRs open for manual review (the default).
  --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
                           (default: merge).
  -h, --help               Show this help and exit.

Environment variables (equivalent to the flags above):
  TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COMMIT_MODEL,
  ISSUES_DIR, QUIET, USE_WORKTREES, AUTO_MERGE, MERGE_METHOD
Plus MAX_ATTEMPTS (env-only, no flag): attempts per issue before giving up
(default: 2).
EOF
}

# Run copilot with the given args, always capturing output to $log_file. Unless
# QUIET is set, the output is also streamed live to stdout via tee. Sets the
# global COPILOT_RC to copilot's own exit code (not tee's).
run_copilot() {
  local log_file="$1"; shift
  if [ "$QUIET" = 1 ]; then
    copilot "$@" >>"$log_file" 2>&1
    COPILOT_RC=$?
  else
    copilot "$@" 2>&1 | tee -a "$log_file"
    COPILOT_RC="${PIPESTATUS[0]}"
  fi
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
    --commit-model)    need_arg $# "$1"; COMMIT_MODEL="$2"; shift ;;
    --commit-model=*)  COMMIT_MODEL="${1#*=}" ;;
    --issues-dir)      need_arg $# "$1"; ISSUES_DIR="$2"; shift ;;
    --issues-dir=*)    ISSUES_DIR="${1#*=}" ;;
    --quiet)           QUIET=1 ;;
    --worktrees)       USE_WORKTREES=1 ;;
    --no-worktrees)    USE_WORKTREES=0 ;;
    --auto-merge)      AUTO_MERGE=1 ;;
    --no-auto-merge)   AUTO_MERGE=0 ;;
    --merge-method)    need_arg $# "$1"; MERGE_METHOD="$2"; shift ;;
    --merge-method=*)  MERGE_METHOD="${1#*=}" ;;
    -h|--help)         usage; exit 0 ;;
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
# Cheapest model by default so commit-message generation costs almost nothing.
# An explicit empty value or "off"/"none" disables the model call (fallback msg).
COMMIT_MODEL="${COMMIT_MODEL:-gpt-5-mini}"
case "$COMMIT_MODEL" in off|none|0) COMMIT_MODEL="" ;; esac

# Auto-merge each PR instead of leaving it for review. Normalise the various
# truthy/falsy spellings to 1/0; anything unset or unrecognised means off.
case "$AUTO_MERGE" in
  1|true|yes|on)  AUTO_MERGE=1 ;;
  *)              AUTO_MERGE=0 ;;
esac
# Merge method used by auto-merge. Default to a merge commit; reject anything
# other than the three methods gh understands so a typo fails loudly at startup.
MERGE_METHOD="${MERGE_METHOD:-merge}"
case "$MERGE_METHOD" in
  merge|squash|rebase) ;;
  *) die "invalid --merge-method: $MERGE_METHOD (use merge, squash or rebase)" ;;
esac

# Total attempts (initial + automatic retries) before an issue is marked failed.
# Env-only (no flag). Normalise to a positive integer so a bad override can never
# disable the cap.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) MAX_ATTEMPTS=2 ;; esac
[ "$MAX_ATTEMPTS" -ge 1 ] || MAX_ATTEMPTS=1

WORK_DIR="$REPO_DIR/.copilot-loop"
LOG_DIR="$WORK_DIR/logs"
LOCK_DIR="$WORK_DIR/lock"

# --- Preflight ---------------------------------------------------------------
for bin in git gh copilot; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

cd "$REPO_DIR" || die "cannot cd into REPO_DIR: $REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO_DIR"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

mkdir -p "$LOG_DIR"

# Lock file for GitHub operations (issue fetching/claiming).
# Multiple instances can run concurrently but must synchronize around GitHub API calls.
GITHUB_LOCK_FILE="$WORK_DIR/github.lock"

# Acquire a lock by creating a lock file. Waits until available.
# Caller must ensure lock is released with release_github_lock().
acquire_github_lock() {
  local max_wait=30 waited=0
  while ! mkdir "$GITHUB_LOCK_FILE" 2>/dev/null; do
    if [ $waited -ge $max_wait ]; then
      log "WARNING: GitHub lock timeout after ${max_wait}s, proceeding anyway"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
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

# Decide whether to isolate each issue in its own git worktree. Auto-detect when
# not forced: use worktrees if we are running inside a linked worktree, or if the
# repository already has more than one worktree. This keeps the shared checkout
# untouched and guarantees the default branch is never used for the work. Each
# issue still gets its own branch in either mode.
case "$USE_WORKTREES" in
  1|true|yes|on)  USE_WORKTREES=1 ;;
  0|false|no|off) USE_WORKTREES=0 ;;
  *)
    USE_WORKTREES=0
    if [ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]; then
      USE_WORKTREES=1
    elif [ "$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')" -gt 1 ]; then
      USE_WORKTREES=1
    fi
    ;;
esac
# Where per-issue worktrees are created (only used when USE_WORKTREES=1). A
# sibling of REPO_DIR so it never lands inside the tracked working tree.
WORKTREE_BASE="$(dirname "$REPO_DIR")/copilot-loop-worktrees"

# Our own login, used to tell the user's replies apart from the loop's own
# comments when deciding whether a "needs-info" issue is ready to resume.
BOT_LOGIN="$(gh api user --jq '.login' 2>/dev/null)"
[ -n "$BOT_LOGIN" ] || log "WARNING: could not determine gh login; reply detection disabled"

log "starting copilot-loop"
log "============================================================"
log "  GitHub repo: $REPO_SLUG"
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

ensure_label "$TRIGGER_LABEL"    "0e8a16" "Ready for the copilot loop to pick up"
ensure_label "$INPROGRESS_LABEL" "fbca04" "Currently being worked by the copilot loop"
ensure_label "$DONE_LABEL"       "1d76db" "A PR was opened by the copilot loop"
ensure_label "$FAILED_LABEL"     "b60205" "The copilot loop failed to produce changes"
ensure_label "$NEEDS_INFO_LABEL" "d93f0b" "Waiting for the issue author to answer a question"
ensure_label "$CONFLICT_UNRESOLVED_LABEL" "b60205" "The copilot loop could not resolve this PR's merge conflicts"

# --- Workspace isolation -----------------------------------------------------
# Every issue (and every PR conflict fix) runs in its own branch, prepared here.
# The default branch (main/master) is NEVER checked out for the work: the branch
# is created directly from a start commit-ish (normally origin/<default>).
#
# Two modes, selected by USE_WORKTREES:
#   1 -> a dedicated git worktree per branch, so the shared checkout is untouched
#        (required when the repo is used with git worktrees, where the default
#        branch may already be checked out elsewhere and cannot be switched to).
#   0 -> the branch is checked out in REPO_DIR itself.
# Both set WORKSPACE_DIR to the directory Copilot and git should operate in.
WORKSPACE_DIR=""

# Map a branch name to its worktree directory (slashes flattened to dashes).
_worktree_path() {
  printf '%s/%s' "$WORKTREE_BASE" "$(printf '%s' "$1" | tr '/' '-')"
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

# --- Core: process a single issue -------------------------------------------
# Returns 0 on success (PR opened), 1 on failure.
process_issue() {
  local num="$1"
  local title body slug branch commit_msg commit_text commit_out pr_body log_file ahead pr_url
  local question_file comments comments_block

  title="$(gh issue view "$num" --json title --jq '.title')"
  body="$(gh issue view "$num" --json body --jq '.body')"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="issue"
  branch="copilot/${num}-${slug}"
  commit_msg="Resolve #${num}: ${title}"
  pr_body="Closes #${num}"$'\n\n'"Automated by copilot-loop."
  log_file="$LOG_DIR/issue-${num}-$(date '+%Y%m%d-%H%M%S').log"
  # Copilot writes here when it needs to ask the user something. Lives in the
  # gitignored work dir so it is never committed; clear any stale copy.
  question_file="$WORK_DIR/issue-${num}.question"
  rm -f "$question_file"

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

  # Build the prompt for Copilot. Include the existing comment thread so any
  # earlier question/answer exchange is available as context.
  comments="$(gh issue view "$num" --json comments \
              --jq '.comments[] | "--- @" + .author.login + " wrote:\n" + .body' 2>/dev/null)"
  comments_block=""
  [ -n "$comments" ] && comments_block=$'\n\nConversation so far (most recent last):\n'"$comments"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository to resolve a GitHub issue.

Issue #${num}: ${title}

${body}${comments_block}

Implement the necessary code changes in the current working directory to fully
resolve this issue. Run any build or test commands needed to verify your work.
Do NOT run git commit, git push, create branches, or open pull requests — those
steps are handled automatically outside this session. Only edit files and verify.

If you are blocked and need more information or a decision from the user, do NOT
guess. Write your question(s) for the user to this file and stop without making
code changes:
  ${question_file}
Whatever you write there is posted as a comment on the issue; once the user
replies you will be run again with their answer included above. Only do this
when you genuinely cannot proceed without their input.
EOF
)"

  # Run Copilot non-interactively from the issue's workspace. All tools allowed
  # and file access stays restricted to that checkout (we deliberately do not
  # pass --allow-all-paths); WORK_DIR is additionally allowed so Copilot can
  # write the question file there when its workspace is a separate worktree.
  local -a copilot_args=(-p "$prompt" --allow-all-tools --add-dir "$WORK_DIR" --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  log "issue #$num: running copilot (log: $log_file)"
  cd "$WORKSPACE_DIR" 2>/dev/null || true
  run_copilot "$log_file" "${copilot_args[@]}"
  local copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "issue #$num: copilot exited with code $copilot_rc"

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
    cleanup_workspace "$branch"
    return 0
  fi

  _fail_issue "$num" "$log_file" "copilot produced no changes (rc=$copilot_rc)"
  return 1
}

# Count how many times this issue has already failed, by counting the hidden
# FAILURE_MARKER stamped on each failure comment. Always echoes a number.
_count_failures() {
  local num="$1" n
  n="$(gh issue view "$num" --json comments \
        --jq '[.comments[] | select(.body != null and (.body | contains("'"$FAILURE_MARKER"'")))] | length' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Handle a failed issue: comment with the error details (or a log tail as a
# fallback) and clean up the branch. While under the MAX_ATTEMPTS cap the issue
# is re-queued (trigger label re-added) for another automatic try; once the
# attempts are exhausted it is marked "copilot-failed". A later user reply
# resumes such an issue for a fresh attempt (see next_reply_issue).
_fail_issue() {
  local num="$1" log_file="$2" reason="$3" details="${4:-}"
  # Prefer explicit details (the exact failing command's output) over the raw
  # log tail, which is mostly Copilot chatter and buries the real cause.
  local block prior attempts note
  if [ -n "$details" ]; then
    block="$details"
  else
    block="$(tail -n 20 "$log_file" 2>/dev/null)"
  fi

  # This failure is attempt N; each earlier failure left a FAILURE_MARKER.
  prior="$(_count_failures "$num")"
  attempts=$(( prior + 1 ))
  if [ "$attempts" -lt "$MAX_ATTEMPTS" ]; then note="will retry"; else note="giving up"; fi
  log "issue #$num: FAILED (attempt $attempts/$MAX_ATTEMPTS, $note) - $reason"

  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh issue comment "$num" --body "$(printf 'copilot-loop failed (attempt %d/%d, %s): %s\n\n```\n%s\n```\n\n%s' \
    "$attempts" "$MAX_ATTEMPTS" "$note" "$reason" "$block" "$FAILURE_MARKER")" >/dev/null 2>&1 || true

  if [ "$attempts" -lt "$MAX_ATTEMPTS" ]; then
    # Hand the issue back to the queue for another automatic attempt.
    gh issue edit "$num" --add-label "$TRIGGER_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
  else
    gh issue edit "$num" --add-label "$FAILED_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
  fi
  cleanup_workspace "$branch"
}

# --- Issue files: create GitHub issues from markdown in issues/ --------------
# Each *.md file in ISSUES_DIR becomes one GitHub issue: the first H1 line is
# the title and everything after it is the body. A file is claimed by renaming
# "<name>.md" -> "<name>_pushing.md" before the issue is created, then deleted
# once the issue exists. Created issues always get the trigger label so the
# loop below picks them up. If ISSUES_DIR is missing it is created with a
# TEMPLATE.md example, which is never turned into an issue.
process_issue_files() {
  if [ ! -d "$ISSUES_DIR" ]; then
    mkdir -p "$ISSUES_DIR" || { log "issue files: could not create $ISSUES_DIR"; return; }
    cat >"$ISSUES_DIR/TEMPLATE.md" <<'EOF'
# Title

Describe the task here. The first "# " heading becomes the issue title and
everything below it becomes the issue body.

Copy this file to a new name ending in .md and edit it; the copilot loop opens
a GitHub issue from it (labelled "ready") and then deletes the file.

Add a line like "Wait for: #1" to hold this issue until issue #1 is closed
(resolved and merged). List several ("Wait for: #1, #2") and use "Blocked by:"
or "Depends on:" if you prefer.
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

    if gh issue create --title "$title" --body "$body" --label "$TRIGGER_LABEL" >/dev/null 2>&1; then
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
# case-insensitive.
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

# Atomically find and claim the next ready issue, protected by GitHub lock.
# Returns the issue number on success, empty string if none available.
# This prevents multiple instances from selecting the same issue.
claim_next_ready_issue() {
  local nums n body blockers issue=""
  acquire_github_lock || return 1

  # Ready issues oldest first (lowest number == earliest created). Walk them in
  # order and claim the first that is not blocked by an unresolved dependency
  # (see issue_open_blockers). A blocked issue keeps its trigger label so it is
  # reconsidered on a later pass once its blockers close.
  nums="$(gh issue list --state open --label "$TRIGGER_LABEL" \
            --limit 1000 --json number --jq 'sort_by(.number) | .[].number' 2>/dev/null)"
  for n in $nums; do
    body="$(gh issue view "$n" --json body --jq '.body' 2>/dev/null)"
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
    break
  done

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
# Handles both "needs-info" (a pending question) and "copilot-failed" (retries
# exhausted) issues whose latest comment came from a human. Returns the issue
# number on success, empty string if none available.
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
    last_author="$(gh issue view "$n" --json comments \
                    --jq '.comments[-1].author.login // empty' 2>/dev/null)"
    [ -n "$last_author" ] && [ "$last_author" != "$BOT_LOGIN" ] || continue
    # Honour the same dependency gate as fresh issues: do not resume an issue
    # while an issue it declares it is waiting for is still open.
    body="$(gh issue view "$n" --json body --jq '.body' 2>/dev/null)"
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
    break
  done
  
  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}

# Echo the number of an issue that is waiting on the user — either "needs-info"
# (a pending question) or "copilot-failed" (retries exhausted) — and has since
# received a reply, i.e. its most recent comment was written by someone other
# than this bot. Oldest first. Returns 1 (no output) when nothing to resume.
# NOTE: This function is now used only for display/checking; actual claiming is
# done atomically by claim_next_reply_issue().
next_reply_issue() {
  [ -n "$BOT_LOGIN" ] || return 1
  local nums n last_author
  # Both labels mean "blocked, waiting on the user"; a human reply resumes them.
  # Sorted ascending (by number == creation order) so the oldest replied issue
  # resumes first. High --limit avoids dropping old issues to gh's default cap.
  nums="$( { gh issue list --state open --label "$NEEDS_INFO_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$FAILED_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null; } \
           | sort -n -u )"
  for n in $nums; do
    last_author="$(gh issue view "$n" --json comments \
                    --jq '.comments[-1].author.login // empty' 2>/dev/null)"
    if [ -n "$last_author" ] && [ "$last_author" != "$BOT_LOGIN" ]; then
      printf '%s\n' "$n"
      return 0
    fi
  done
  return 1
}

# --- Core: resolve merge conflicts on a single PR ---------------------------
# Merges the PR's base branch into its head branch; if that conflicts, hands the
# conflicted files to Copilot to resolve, then commits and pushes so the PR
# becomes mergeable again. Returns 0 on success, 1 on failure.
resolve_pr_conflicts() {
  local num="$1"
  local head base title log_file conflicts copilot_rc

  head="$(gh pr view "$num" --json headRefName --jq '.headRefName' 2>/dev/null)"
  base="$(gh pr view "$num" --json baseRefName --jq '.baseRefName' 2>/dev/null)"
  title="$(gh pr view "$num" --json title --jq '.title' 2>/dev/null)"
  [ -n "$base" ] || base="$DEFAULT_BRANCH"
  log_file="$LOG_DIR/pr-${num}-$(date '+%Y%m%d-%H%M%S').log"

  if [ -z "$head" ]; then
    log "PR #$num: could not determine head branch, skipping"
    gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
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
    local -a copilot_args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
    [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

    log "PR #$num: running copilot to resolve conflicts (log: $log_file)"
    cd "$WORKSPACE_DIR" 2>/dev/null || true
    run_copilot "$log_file" "${copilot_args[@]}"
    copilot_rc=$COPILOT_RC
    cd "$REPO_DIR" 2>/dev/null || true
    log "PR #$num: copilot exited with code $copilot_rc"

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
  log "PR #$num: conflicts resolved and pushed"
  cleanup_workspace "$head"
  return 0
}

# Echo the number of the lowest-numbered open PR targeting the default branch
# whose merge is CONFLICTING, skipping any already marked unresolved. Returns 1
# (no output) when no PR needs conflict resolution.
next_conflicted_pr() {
  local jq_filter
  jq_filter='[.[] | select(.mergeable == "CONFLICTING")'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CONFLICT_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | .number] | sort | .[0] // empty'
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable,labels --jq "$jq_filter" 2>/dev/null
}

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

# --- Main loop ---------------------------------------------------------------
while true; do
  # Keep the loop current before starting any new work: pull the default branch
  # and re-exec if this script changed upstream.
  self_update

  process_issue_files

  # Before starting any new task, make sure no open PR is left with merge
  # conflicts; resolve one if found and re-check before doing anything else.
  conflicted_pr="$(next_conflicted_pr || true)"
  if [ -n "$conflicted_pr" ]; then
    log "PR #$conflicted_pr has conflicts, resolving before starting new tasks"
    resolve_pr_conflicts "$conflicted_pr" || true
    continue
  fi

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
