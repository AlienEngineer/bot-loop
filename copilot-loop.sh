#!/usr/bin/env bash
#
# copilot-loop.sh
#
# Autonomous loop that pulls labelled GitHub issues and hands each one to the
# GitHub Copilot CLI to resolve, then opens a pull request. When no work is
# available it sleeps and checks again.
#
# Flow per iteration:
#   0. Before starting any new task, check open PRs targeting the default branch
#      for merge conflicts. If one is found, merge the base branch into it and
#      let Copilot resolve the conflicts, then push — so PRs stay mergeable.
#   1. Pick the next issue to work on:
#        a. an issue awaiting a reply ("needs-info") whose latest comment came
#           from a human (the user answered a question) -> resume it; else
#        b. the oldest open issue with the trigger label (default: "ready").
#   2. Claim it: add "in-progress", remove the trigger/"needs-info" labels.
#   3. Create a fresh branch off the default branch.
#   4. Run `copilot -p` (all tools, file access restricted to this repo),
#      passing the issue's comment thread so any prior Q&A is available.
#   5a. If Copilot needs more information it writes a question file; post the
#       question as an issue comment, label the issue "needs-info", and wait for
#       the user to reply (no PR opened, not counted as a failure).
#   5b. Otherwise commit, sync the branch with the latest default branch, then
#       push and open a PR that closes the issue.
#   6. Label the issue "copilot-done" (success) or "copilot-failed" (failure).
#   7. If no issues are found, sleep and repeat.
#
# Requirements: git, gh (authenticated), copilot.
#
# Usage:
#   ./copilot-loop.sh [--quiet]
#
# Options:
#   --quiet   Do not stream Copilot's output to stdout; write it only to the
#             per-run log files (the original behaviour). By default the loop
#             streams Copilot's output live to stdout as well as the log files.
#
# Configuration (override via environment variables):
#   TRIGGER_LABEL   Label that marks an issue as ready   (default: ready)
#   SLEEP_MINUTES   Idle sleep when no work is found      (default: 5)
#   REPO_DIR        Repository to operate in              (default: current git repo)
#   COPILOT_MODEL   Model passed to copilot --model       (default: unset/auto)
#   QUIET           Same as --quiet when set to 1          (default: 0)
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
# Stream Copilot's output live to stdout in addition to the per-run log files.
# Set QUIET=1 (or pass --quiet) to keep the original log-file-only behaviour.
QUIET="${QUIET:-0}"

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

usage() {
  cat <<'EOF'
Usage: ./copilot-loop.sh [--quiet]

Autonomous loop that resolves labelled GitHub issues with the Copilot CLI.

Options:
  --quiet     Do not stream Copilot's output to stdout; write it only to the
              per-run log files (the original behaviour). By default the loop
              streams Copilot's output live to stdout as well as the log files.
  -h, --help  Show this help and exit.

Configuration via environment variables:
  TRIGGER_LABEL   Label that marks an issue as ready   (default: ready)
  SLEEP_MINUTES   Idle sleep when no work is found      (default: 5)
  REPO_DIR        Repository to operate in              (default: current git repo)
  COPILOT_MODEL   Model passed to copilot --model       (default: unset/auto)
  QUIET           Same as --quiet when set to 1          (default: 0)
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

# --- Argument parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)   QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         die "unknown argument: $1 (use --help)" ;;
  esac
  shift
done

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

  # Claim the issue up-front so it is never picked up twice, even on a crash.
  # (Separate calls so removing an absent label can't skip the add.)
  gh issue edit "$num" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$num" --remove-label "$TRIGGER_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$num" --remove-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true

  # Start from a clean, up-to-date default branch.
  git switch "$DEFAULT_BRANCH" >/dev/null 2>&1
  git pull --ff-only origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
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
    if ! git rebase "origin/${DEFAULT_BRANCH}" >>"$log_file" 2>&1; then
      git rebase --abort >/dev/null 2>&1 || true
      _fail_issue "$num" "$log_file" "failed to sync with ${DEFAULT_BRANCH} (rebase conflict)"
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

# Echo the number of an issue that is waiting on the user ("needs-info") and has
# since received a reply — i.e. its most recent comment was written by someone
# other than this bot. Returns 1 (no output) when there is nothing to resume.
next_reply_issue() {
  [ -n "$BOT_LOGIN" ] || return 1
  local nums n last_author
  # Sorted ascending (by number == creation order) so the oldest replied issue
  # resumes first. High --limit avoids dropping old issues to gh's default cap.
  nums="$(gh issue list --state open --label "$NEEDS_INFO_LABEL" \
            --limit 1000 --json number --jq 'sort_by(.number)[].number' 2>/dev/null)"
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
  # Before starting any new task, make sure no open PR is left with merge
  # conflicts; resolve one if found and re-check before doing anything else.
  conflicted_pr="$(next_conflicted_pr || true)"
  if [ -n "$conflicted_pr" ]; then
    log "PR #$conflicted_pr has conflicts, resolving before starting new tasks"
    resolve_pr_conflicts "$conflicted_pr" || true
    continue
  fi

  # Prefer resuming an issue where the user has answered a pending question.
  next_issue="$(next_reply_issue || true)"
  if [ -n "$next_issue" ]; then
    log "issue #$next_issue: user replied, resuming"
    process_issue "$next_issue" || true
    continue
  fi

  # Pick the oldest ready issue (lowest number == earliest created) so work is
  # done in creation order. gh lists newest-first, so sort here rather than
  # relying on list order; a high --limit avoids truncating away old issues.
  next_issue="$(gh issue list --state open --label "$TRIGGER_LABEL" \
                  --limit 1000 --json number --jq 'min_by(.number).number // empty' 2>/dev/null)"

  if [ -z "$next_issue" ]; then
    log "no ready issues; sleeping ${SLEEP_MINUTES}m"
    sleep "$((SLEEP_MINUTES * 60))"
    continue
  fi

  process_issue "$next_issue" || true
done
