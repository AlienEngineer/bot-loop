#!/usr/bin/env bash
#
# copilot-loop.sh
#
# Autonomous loop that pulls labelled GitHub issues and hands each one to the
# GitHub Copilot CLI to resolve, then opens a pull request. When no work is
# available it sleeps and checks again.
#
# Flow per iteration:
#   1. Find the oldest open issue with the trigger label (default: "ready").
#   2. Claim it: remove trigger label, add "in-progress" (prevents re-pickup).
#   3. Create a fresh branch off the default branch.
#   4. Run `copilot -p` (all tools, but file access restricted to this repo).
#   5. Commit + push the changes and open a PR that closes the issue.
#   6. Label the issue "copilot-done" (success) or "copilot-failed" (failure).
#   7. If no issues are found, sleep and repeat.
#
# Requirements: git, gh (authenticated), copilot.
#
# Usage:
#   ./copilot-loop.sh
#
# Configuration (override via environment variables):
#   TRIGGER_LABEL   Label that marks an issue as ready   (default: ready)
#   SLEEP_MINUTES   Idle sleep when no work is found      (default: 5)
#   REPO_DIR        Repository to operate in              (default: current git repo)
#   COPILOT_MODEL   Model passed to copilot --model       (default: unset/auto)
#
set -uo pipefail

# --- Configuration -----------------------------------------------------------
# Operate on the current directory's repository by default, not the script's
# install location (it may be a symlink on PATH). Resolve to the git top-level
# so running from a subdirectory still targets the whole repo.
REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TRIGGER_LABEL="${TRIGGER_LABEL:-ready}"
SLEEP_MINUTES="${SLEEP_MINUTES:-5}"
COPILOT_MODEL="${COPILOT_MODEL:-}"

INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
FAILED_LABEL="copilot-failed"

WORK_DIR="$REPO_DIR/.copilot-loop"
LOG_DIR="$WORK_DIR/logs"
LOCK_DIR="$WORK_DIR/lock"

# --- Helpers -----------------------------------------------------------------
log() {
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "FATAL: $*"
  exit 1
}

# Ensure a label exists (ignore "already exists" errors).
ensure_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" >/dev/null 2>&1 || true
}

# --- Preflight ---------------------------------------------------------------
for bin in git gh copilot; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

cd "$REPO_DIR" || die "cannot cd into REPO_DIR: $REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO_DIR"
git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

mkdir -p "$LOG_DIR"

# Single-instance lock.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "another copilot-loop appears to be running (lock: $LOCK_DIR)"
fi
cleanup() {
  rm -rf "$LOCK_DIR"
  log "shutting down"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[ -n "$REPO_SLUG" ] || REPO_SLUG="unknown"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

log "starting copilot-loop"
log "============================================================"
log "  GitHub repo: $REPO_SLUG"
log "  origin url:  $ORIGIN_URL"
log "  local dir:   $REPO_DIR"
log "============================================================"
log "default_branch=$DEFAULT_BRANCH trigger_label=$TRIGGER_LABEL sleep=${SLEEP_MINUTES}m"

ensure_label "$TRIGGER_LABEL"    "0e8a16" "Ready for the copilot loop to pick up"
ensure_label "$INPROGRESS_LABEL" "fbca04" "Currently being worked by the copilot loop"
ensure_label "$DONE_LABEL"       "1d76db" "A PR was opened by the copilot loop"
ensure_label "$FAILED_LABEL"     "b60205" "The copilot loop failed to produce changes"

# --- Core: process a single issue -------------------------------------------
# Returns 0 on success (PR opened), 1 on failure.
process_issue() {
  local num="$1"
  local title body slug branch commit_msg pr_body log_file ahead pr_url

  title="$(gh issue view "$num" --json title --jq '.title')"
  body="$(gh issue view "$num" --json body --jq '.body')"
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="issue"
  branch="copilot/${num}-${slug}"
  commit_msg="Resolve #${num}: ${title}"
  pr_body="Closes #${num}"$'\n\n'"Automated by copilot-loop."
  log_file="$LOG_DIR/issue-${num}-$(date '+%Y%m%d-%H%M%S').log"

  log "issue #$num on $REPO_SLUG: $title"

  # Claim the issue up-front so it is never picked up twice, even on a crash.
  gh issue edit "$num" --add-label "$INPROGRESS_LABEL" --remove-label "$TRIGGER_LABEL" >/dev/null 2>&1

  # Start from a clean, up-to-date default branch.
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git pull --ff-only origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  # Fresh branch (reset if a stale one lingers from a previous failed run).
  git switch -c "$branch" >/dev/null 2>&1 || git switch -C "$branch" >/dev/null 2>&1

  # Build the prompt for Copilot.
  local prompt
  prompt="$(cat <<EOF
You are working in a git repository to resolve a GitHub issue.

Issue #${num}: ${title}

${body}

Implement the necessary code changes in the current working directory to fully
resolve this issue. Run any build or test commands needed to verify your work.
Do NOT run git commit, git push, create branches, or open pull requests — those
steps are handled automatically outside this session. Only edit files and verify.
EOF
)"

  # Run Copilot non-interactively. All tools allowed, but file access stays
  # restricted to this repo (we deliberately do not pass --allow-all-paths).
  local -a copilot_args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  log "issue #$num: running copilot (log: $log_file)"
  copilot "${copilot_args[@]}" >"$log_file" 2>&1
  local copilot_rc=$?
  log "issue #$num: copilot exited with code $copilot_rc"

  # Commit whatever changed (in case Copilot did not commit itself).
  git add -A
  git diff --cached --quiet || git commit -m "$commit_msg" >/dev/null 2>&1

  ahead="$(git rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null \
          || git rev-list --count "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"

  if [ "${ahead:-0}" -gt 0 ]; then
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

# Mark an issue failed, comment with a log tail, and clean up the branch.
_fail_issue() {
  local num="$1" log_file="$2" reason="$3"
  log "issue #$num: FAILED - $reason"
  local tail_out
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh issue comment "$num" --body "$(printf 'copilot-loop failed: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh issue edit "$num" --add-label "$FAILED_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git branch -D "$branch" >/dev/null 2>&1 || true
}

# --- Main loop ---------------------------------------------------------------
while true; do
  next_issue="$(gh issue list --state open --label "$TRIGGER_LABEL" \
                  --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)"

  if [ -z "$next_issue" ]; then
    log "no ready issues; sleeping ${SLEEP_MINUTES}m"
    sleep "$((SLEEP_MINUTES * 60))"
    continue
  fi

  process_issue "$next_issue" || true
done
