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
#   3. Claim it: add "in-progress", remove the trigger/"needs-info" labels
#      (done atomically by the claiming functions to prevent race conditions).
#   4. Create a fresh branch off the default branch.
#   5. Run `copilot -p` (all tools, file access restricted to this repo),
#      passing the issue's comment thread so any prior Q&A is available.
#   6a. If Copilot needs more information it writes a question file; post the
#       question as an issue comment, label the issue "needs-info", and wait for
#       the user to reply (no PR opened, not counted as a failure).
#   6b. Otherwise commit, sync the branch with the latest default branch, then
#       push and open a PR that closes the issue.
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
#   --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
#   --quiet                  Do not stream Copilot's output to stdout; write it
#                            only to the per-run log files (the original
#                            behaviour). By default the loop streams Copilot's
#                            output live to stdout as well as the log files.
#   -h, --help               Show help and exit.
#
# Environment variables (equivalent to the flags above):
#   TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, ISSUES_DIR, QUIET
# Plus MAX_ATTEMPTS (env-only, no flag): attempts per issue before giving up
# (default: 2).
#
set -uo pipefail

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
ISSUES_DIR="${ISSUES_DIR:-}"
# Stream Copilot's output live to stdout in addition to the per-run log files.
# Set QUIET=1 (or pass --quiet) to keep the original log-file-only behaviour.
QUIET="${QUIET:-}"

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
  --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
  --quiet                  Do not stream Copilot's output to stdout; write it
                           only to the per-run log files (the original
                           behaviour). By default the loop streams Copilot's
                           output live to stdout as well as the log files.
  -h, --help               Show this help and exit.

Environment variables (equivalent to the flags above):
  TRIGGER_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, ISSUES_DIR, QUIET
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
    --issues-dir)      need_arg $# "$1"; ISSUES_DIR="$2"; shift ;;
    --issues-dir=*)    ISSUES_DIR="${1#*=}" ;;
    --quiet)           QUIET=1 ;;
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
if [ "$QUIET" = 1 ]; then
  log "copilot output: log files only (--quiet); stdout hidden"
else
  log "copilot output: streamed to stdout and log files (pass --quiet to hide)"
fi

ensure_label "$TRIGGER_LABEL"    "0e8a16" "Ready for the copilot loop to pick up"
ensure_label "$INPROGRESS_LABEL" "fbca04" "Currently being worked by the copilot loop"
ensure_label "$DONE_LABEL"       "1d76db" "A PR was opened by the copilot loop"
ensure_label "$FAILED_LABEL"     "b60205" "The copilot loop failed to produce changes"
ensure_label "$NEEDS_INFO_LABEL" "d93f0b" "Waiting for the issue author to answer a question"
ensure_label "$CONFLICT_UNRESOLVED_LABEL" "b60205" "The copilot loop could not resolve this PR's merge conflicts"

# --- Core: process a single issue -------------------------------------------
# Returns 0 on success (PR opened), 1 on failure.
process_issue() {
  local num="$1"
  local title body slug branch commit_msg pr_body log_file ahead pr_url
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

  # Start from a clean, up-to-date default branch. Drop any leftover changes
  # from a previous run so nothing blocks the switch or update.
  git reset --hard >/dev/null 2>&1 || true
  git clean -fd >/dev/null 2>&1 || true
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  # Pull the latest changes and resolve any conflicts. The local default branch
  # is a throwaway mirror (all work happens on copilot/* branches), so if it has
  # drifted and cannot fast-forward we hard-reset onto the remote rather than
  # silently working from a stale tree.
  git fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  if ! git merge --ff-only "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    git reset --hard "origin/${DEFAULT_BRANCH}" >/dev/null 2>&1 \
      || git reset --hard FETCH_HEAD >/dev/null 2>&1 || true
  fi
  # Fresh branch (reset if a stale one lingers from a previous failed run).
  git switch -c "$branch" >/dev/null 2>&1 || git switch -C "$branch" >/dev/null 2>&1

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

  # Run Copilot non-interactively. All tools allowed, but file access stays
  # restricted to this repo (we deliberately do not pass --allow-all-paths).
  local -a copilot_args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  log "issue #$num: running copilot (log: $log_file)"
  run_copilot "$log_file" "${copilot_args[@]}"
  local copilot_rc=$COPILOT_RC
  log "issue #$num: copilot exited with code $copilot_rc"

  # Copilot asked for more information instead of coding: relay the question to
  # the user and wait for their reply (handled, so return success without a PR).
  if [ -s "$question_file" ]; then
    _ask_issue "$num" "$question_file"
    return 0
  fi

  # Commit whatever changed (in case Copilot did not commit itself).
  git add -A
  git diff --cached --quiet || git commit -m "$commit_msg" >/dev/null 2>&1

  # Refresh our view of the default branch so we can sync against any work that
  # landed on it while Copilot was running.
  git fetch origin "$DEFAULT_BRANCH" >>"$log_file" 2>&1 || true

  ahead="$(git rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null \
          || git rev-list --count "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"

  if [ "${ahead:-0}" -gt 0 ]; then
    # Sync onto the latest default branch before pushing so the PR merges
    # cleanly and does not fall behind commits that landed during the run.
    # Prefer the remote-tracking ref, but fall back to FETCH_HEAD if it is
    # missing (e.g. a worktree with no fetch refspec) so we never rebase onto a
    # ref that does not exist.
    local sync_target="origin/${DEFAULT_BRANCH}" rebase_out reason detail
    git rev-parse --verify --quiet "$sync_target" >/dev/null 2>&1 || sync_target="FETCH_HEAD"
    if ! rebase_out="$(git rebase "$sync_target" 2>&1)"; then
      printf '%s\n' "$rebase_out" >>"$log_file"
      git rebase --abort >/dev/null 2>&1 || true
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
    log "issue #$num: $ahead commit(s), pushing branch $branch"
    if ! git push -u origin "$branch" >>"$log_file" 2>&1; then
      _fail_issue "$num" "$log_file" "git push failed"
      return 1
    fi
    pr_url="$(gh pr create --base "$DEFAULT_BRANCH" --head "$branch" \
                --title "$commit_msg" --body "$pr_body" 2>>"$log_file")"
    if [ -z "$pr_url" ]; then
      _fail_issue "$num" "$log_file" "gh pr create failed"
      return 1
    fi
    gh issue edit "$num" --add-label "$DONE_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
    log "issue #$num: DONE -> $pr_url"
    git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
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
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git branch -D "$branch" >/dev/null 2>&1 || true
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
# so it is not retried forever, and restore a clean working tree on the default
# branch.
_fail_pr() {
  local num="$1" log_file="$2" reason="$3" tail_out
  log "PR #$num: FAILED to resolve conflicts - $reason"
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh pr comment "$num" --body "$(printf 'copilot-loop could not resolve merge conflicts: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  git reset --hard >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
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
  git reset --hard >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git branch -D "$branch" >/dev/null 2>&1 || true
}

# Atomically find and claim the next ready issue, protected by GitHub lock.
# Returns the issue number on success, empty string if none available.
# This prevents multiple instances from selecting the same issue.
claim_next_ready_issue() {
  local issue
  acquire_github_lock || return 1
  
  # Pick the oldest ready issue (lowest number == earliest created).
  issue="$(gh issue list --state open --label "$TRIGGER_LABEL" \
             --limit 1000 --json number --jq 'min_by(.number).number // empty' 2>/dev/null)"
  
  if [ -n "$issue" ]; then
    # Claim it immediately: add in-progress, remove trigger labels.
    # Do this WHILE HOLDING THE LOCK so no other instance can select it.
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$TRIGGER_LABEL" >/dev/null 2>&1 || true
    printf '%s\n' "$issue"
  fi
  
  release_github_lock
  [ -n "$issue" ]
}

# Atomically find and claim the next reply issue, protected by GitHub lock.
# Handles both "needs-info" (a pending question) and "copilot-failed" (retries
# exhausted) issues whose latest comment came from a human. Returns the issue
# number on success, empty string if none available.
claim_next_reply_issue() {
  [ -n "$BOT_LOGIN" ] || return 1
  
  local nums n last_author issue=""
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
    if [ -n "$last_author" ] && [ "$last_author" != "$BOT_LOGIN" ]; then
      # Found one; claim it before releasing the lock
      issue="$n"
      gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
      gh issue edit "$issue" --remove-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true
      gh issue edit "$issue" --remove-label "$FAILED_LABEL" >/dev/null 2>&1 || true
      break
    fi
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

  # Get an up-to-date view of both branches and check out the PR head fresh.
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git fetch origin >>"$log_file" 2>&1 || true
  if ! git switch -C "$head" "origin/$head" >>"$log_file" 2>&1; then
    _fail_pr "$num" "$log_file" "could not check out PR head branch '$head'"
    return 1
  fi

  # Merge the base branch. A clean merge means the conflict was already resolved
  # upstream; otherwise git leaves conflict markers for Copilot to fix.
  if git merge --no-edit "origin/$base" >>"$log_file" 2>&1; then
    log "PR #$num: merged $base with no conflicts to resolve"
  else
    conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null)"
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
    run_copilot "$log_file" "${copilot_args[@]}"
    copilot_rc=$COPILOT_RC
    log "PR #$num: copilot exited with code $copilot_rc"

    # Bail out if Copilot left conflict markers behind in any conflicted file.
    local f unresolved=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] && grep -qE '^(<{7}|>{7})' "$f" && unresolved="$unresolved $f"
    done <<< "$conflicts"
    if [ -n "$unresolved" ]; then
      _fail_pr "$num" "$log_file" "conflict markers still present in:$unresolved"
      return 1
    fi

    git add -A
    git commit --no-edit >/dev/null 2>&1 \
      || git commit -m "Merge $base into $head to resolve conflicts (#$num)" >/dev/null 2>&1
  fi

  if ! git push origin "HEAD:$head" >>"$log_file" 2>&1; then
    _fail_pr "$num" "$log_file" "git push failed"
    return 1
  fi

  gh pr comment "$num" \
    --body "copilot-loop resolved the merge conflicts with \`$base\`." >/dev/null 2>&1 || true
  log "PR #$num: conflicts resolved and pushed"
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git branch -D "$head" >/dev/null 2>&1 || true
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

# --- Main loop ---------------------------------------------------------------
while true; do
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
