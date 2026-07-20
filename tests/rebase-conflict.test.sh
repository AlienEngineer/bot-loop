#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034,SC2329  # mocks/config are invoked or read indirectly by the eval'd code
#
# Tests for the pre-PR rebase conflict resolution in copilot-loop.sh (issue #193).
# After Copilot's work is committed, process_issue rebases the issue branch onto
# the freshly-fetched default branch before pushing. When that rebase conflicts,
# the loop must NOT fail the issue and stop — it hands the conflicted files to
# Copilot, continues the rebase, and carries on so the branch can be pushed.
#
# The "rebase-conflict helpers" block is extracted verbatim from the script
# between its markers and sourced here. resolve_rebase_conflicts is exercised as
# an integration test against REAL throwaway git repos (a bare origin, a clone,
# and a worktree in mid-rebase) with only log/_report_usage/copilot_run_timed_out
# and run_copilot mocked, so the actual git and control flow run without touching
# GitHub or Copilot.
#
# Run: tests/rebase-conflict.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

rebase_block="$(sed -n '/# >>> rebase-conflict helpers >>>/,/# <<< rebase-conflict helpers <<</p' "$script")"
[ -n "$rebase_block" ] || { echo "could not extract rebase-conflict helpers (markers missing?)"; exit 1; }
eval "$rebase_block"

fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"
    fail=1
  fi
}

# --- Config/mocks the extracted helpers read from the environment ------------
COPILOT_MODEL=""
COPILOT_TIMEOUT=""
COPILOT_RC=0

# Silence the loop's status lines and cost reporting.
# shellcheck disable=SC2329
log() { :; }
# shellcheck disable=SC2329
_report_usage() { :; }
# No timeout in force, so a run is never treated as timed out.
# shellcheck disable=SC2329
copilot_run_timed_out() { return 1; }

root="$(mktemp -d)"
trap 'cd "$here" 2>/dev/null; rm -rf "$root"' EXIT

origin=""; clone=""; other=""; wt=""; log_file=""
CALLS=""            # records each run_copilot invocation
RESOLVE_MODE="resolve"   # resolve | leave | match-upstream

# Stand in for a Copilot run: record the call, then act on the conflicted file to
# mirror a real resolution. "resolve" writes distinct content per call (so each
# rebased commit stays non-empty), "leave" keeps the conflict markers untouched,
# and "match-upstream" writes exactly what landed upstream (making the commit
# empty so the rebase skips it).
# shellcheck disable=SC2329
run_copilot() {
  printf 'call\n' >>"$CALLS"
  local n; n="$(grep -c . "$CALLS" 2>/dev/null)"
  case "$RESOLVE_MODE" in
    resolve)        printf 'resolved-%s\n' "$n" >"$WORKSPACE_DIR/file.txt" ;;
    match-upstream) printf 'remote\n'            >"$WORKSPACE_DIR/file.txt" ;;
    leave)          : ;;  # leave markers in place
  esac
  COPILOT_RC=0
}

calls() { local n; n="$(grep -c . "$CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# Build a fresh bare origin + primary clone (REPO_DIR, on main) + a second clone
# used to publish "remote" commits, all sharing a committed baseline.
setup_repo() {
  cd "$here" 2>/dev/null || true
  rm -rf "$root"; mkdir -p "$root"
  origin="$root/origin.git"; clone="$root/clone"; other="$root/other"

  git init --bare -q "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  git -C "$clone" config user.email t@e.com
  git -C "$clone" config user.name  t
  git -C "$clone" config commit.gpgsign false
  printf 'base\n' >"$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" commit -qm init
  git -C "$clone" branch -M main
  git -C "$clone" push -q -u origin main

  git clone -q -b main "$origin" "$other" 2>/dev/null
  git -C "$other" config user.email t@e.com
  git -C "$other" config user.name  t
  git -C "$other" config commit.gpgsign false

  REPO_DIR="$clone"
  CALLS="$root/copilot-calls"; : >"$CALLS"
  log_file="$root/run.log"; : >"$log_file"
}

# Publish a commit to origin/main from the second clone (the "remote" moving on).
remote_commit() {
  printf '%s\n' "$1" >"$other/file.txt"
  git -C "$other" add file.txt
  git -C "$other" commit -qm "remote: $1"
  git -C "$other" push -q origin main
}

# Create the issue branch as a worktree off main with one committed change, so it
# stands in for "Copilot's committed work" that now needs to sync with the remote.
make_issue_branch() {
  wt="$root/wt"
  git -C "$clone" worktree add -q -b feat "$wt" main 2>/dev/null
  local prev="$clone/file.txt" c
  for c in "$@"; do
    printf '%s\n' "$c" >"$wt/file.txt"
    git -C "$wt" add file.txt
    git -C "$wt" commit -qm "feat: $c"
  done
  WORKSPACE_DIR="$wt"
}

# Start the pre-PR rebase exactly as process_issue does; leaves the worktree in a
# conflicted, mid-rebase state for the resolver to take over.
start_rebase() {
  git -C "$wt" fetch -q origin main 2>/dev/null || true
  git -C "$wt" rebase origin/main >/dev/null 2>&1 || true
}

rebase_in_progress() {
  local d p
  for d in rebase-merge rebase-apply; do
    p="$(git -C "$wt" rev-parse --git-path "$d" 2>/dev/null)"
    [ -n "$p" ] || continue
    case "$p" in /*) : ;; *) p="$wt/$p" ;; esac
    [ -d "$p" ] && return 0
  done
  return 1
}

# --- Conflict resolved: rebase completes, history stays linear ---------------
setup_repo
RESOLVE_MODE="resolve"
remote_commit "remote"          # origin/main: base -> remote
make_issue_branch "feature"     # feat:        base -> feature (conflicts)
start_rebase
upstream_sha="$(git -C "$wt" rev-parse origin/main)"

resolve_rebase_conflicts 42 "$log_file" "origin/main"; rc=$?

assert_eq "resolved: resolver reports success (rc 0)" "$rc" "0"
assert_eq "resolved: copilot run once"                "$(calls)" "1"
assert_eq "resolved: no unmerged paths remain" \
  "$(git -C "$wt" diff --name-only --diff-filter=U | wc -l | tr -d ' ')" "0"
assert_eq "resolved: rebase finished (not in progress)" \
  "$(rebase_in_progress && echo yes || echo no)" "no"
assert_eq "resolved: working tree clean" \
  "$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')" "0"
assert_eq "resolved: file holds Copilot's resolution" "$(cat "$wt/file.txt")" "resolved-1"
assert_eq "resolved: branch is one commit ahead of upstream" \
  "$(git -C "$wt" rev-list --count origin/main..HEAD)" "1"
assert_eq "resolved: history is linear (single parent, no merge commit)" \
  "$(git -C "$wt" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "2"
assert_eq "resolved: rebased onto the latest upstream" \
  "$(git -C "$wt" rev-parse HEAD~1)" "$upstream_sha"

# --- Copilot leaves markers: resolver fails so the caller can abort -----------
setup_repo
RESOLVE_MODE="leave"
remote_commit "remote"
make_issue_branch "feature"
start_rebase

resolve_rebase_conflicts 43 "$log_file" "origin/main"; rc=$?
assert_eq "unresolved: resolver reports failure (rc 1)" "$rc" "1"
assert_eq "unresolved: copilot run once"                "$(calls)" "1"
assert_eq "unresolved: conflict markers still present" \
  "$(grep -cE '^(<{7}|>{7})' "$wt/file.txt")" "2"
git -C "$wt" rebase --abort >/dev/null 2>&1 || true

# --- Multi-commit conflict: resolver loops until the rebase is done -----------
setup_repo
RESOLVE_MODE="resolve"
remote_commit "remote"
make_issue_branch "A" "B"       # two feat commits, each conflicts on replay
start_rebase

resolve_rebase_conflicts 44 "$log_file" "origin/main"; rc=$?
assert_eq "multi: resolver reports success (rc 0)"    "$rc" "0"
assert_eq "multi: copilot run once per conflicted commit" "$(calls)" "2"
assert_eq "multi: rebase finished (not in progress)" \
  "$(rebase_in_progress && echo yes || echo no)" "no"
assert_eq "multi: both feat commits replayed onto upstream" \
  "$(git -C "$wt" rev-list --count origin/main..HEAD)" "2"
assert_eq "multi: final file holds the last resolution" "$(cat "$wt/file.txt")" "resolved-2"

# --- Resolution matches upstream: empty commit is skipped, rebase completes ---
setup_repo
RESOLVE_MODE="match-upstream"
remote_commit "remote"
make_issue_branch "feature"
start_rebase

resolve_rebase_conflicts 45 "$log_file" "origin/main"; rc=$?
assert_eq "empty: resolver reports success (rc 0)"   "$rc" "0"
assert_eq "empty: rebase finished (not in progress)" \
  "$(rebase_in_progress && echo yes || echo no)" "no"
assert_eq "empty: empty commit dropped (branch matches upstream)" \
  "$(git -C "$wt" rev-list --count origin/main..HEAD)" "0"
assert_eq "empty: working tree clean" \
  "$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')" "0"

if [ "$fail" -eq 0 ]; then
  echo "All rebase-conflict tests passed."
else
  echo "Some rebase-conflict tests FAILED."
fi
exit "$fail"
