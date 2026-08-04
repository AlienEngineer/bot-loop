#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars used indirectly by eval'd code
#
# Tests for improved branch-creation failure handling (#237):
#   - When worktree creation fails the actual git error is captured and exposed
#     in PREPARE_WORKSPACE_ERROR (not silently discarded).
#   - When an orphaned worktree directory is left behind by a crashed previous
#     run, prepare_workspace auto-recovers (prune + remove dir + retry) without
#     requiring Copilot involvement.
#   - In-place mode (USE_WORKTREES=0) also captures the git error.
#
# User-perspective outcomes verified:
#   - Failed branch creation surfaces a meaningful error, not a blank message.
#   - A stale orphaned worktree directory does not permanently block the bot.
#
# Run: tests/branch-create-error.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

extract() { sed -n "/^$1() {/,/^}/p" "$script"; }
for fn in _worktree_path _worktree_lock_state cleanup_workspace prepare_workspace; do
  block="$(extract "$fn")"
  [ -n "$block" ] || { echo "could not extract $fn() from copilot-loop.sh"; exit 1; }
  eval "$block"
done
# Also pull in the PREPARE_WORKSPACE_ERROR initialisation line that sits just
# above the function definition.
eval "$(grep -m1 '^PREPARE_WORKSPACE_ERROR=' "$script")"

fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"; fail=1; fi
}
assert_not_empty() {
  local desc="$1" val="$2"
  if [ -n "$val" ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s\n       expected non-empty value\n' "$desc"; fail=1; fi
}
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)           printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}

command -v git >/dev/null 2>&1 || { echo "git required for this test"; exit 1; }

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t branchwserr)"
trap 'git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

origin="$tmp/origin.git"
REPO_DIR="$tmp/repo"
git init -q --bare "$origin"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" config user.email t@example.com
git -C "$REPO_DIR" config user.name  test
git -C "$REPO_DIR" config commit.gpgsign false
git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/main
printf 'base\n' >"$REPO_DIR/base.txt"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -qm "base commit"
git -C "$REPO_DIR" remote add origin "$origin"
git -C "$REPO_DIR" push -q -u origin main

USE_WORKTREES=1
DEFAULT_BRANCH="main"
WORKTREE_BASE="$tmp/worktrees"
mkdir -p "$WORKTREE_BASE"
WORKSPACE_DIR=""

# --- Case 1: invalid start ref -> git error is captured, not silently lost ---
# Using a ref that doesn't exist forces git to emit an error we can inspect.
cd "$REPO_DIR"
PREPARE_WORKSPACE_ERROR=""
WORKSPACE_DIR=""
prepare_workspace "copilot/1-test" "refs/heads/nonexistent-ref-xyz" || true

assert_not_empty "invalid-ref: PREPARE_WORKSPACE_ERROR is set on failure" \
  "$PREPARE_WORKSPACE_ERROR"
assert_eq "invalid-ref: WORKSPACE_DIR is empty after failure" \
  "$WORKSPACE_DIR" ""

# --- Case 2: orphaned directory auto-recovery ---
# Simulate a previous run that crashed and left an orphaned directory at the
# expected worktree path. The bot must self-heal: prune + remove + retry succeeds.
branch2="copilot/2-orphan"
wt2="$(_worktree_path "$branch2")"
mkdir -p "$wt2"           # orphaned plain directory (not a git worktree)
printf 'stale file\n' >"$wt2/stale.txt"

PREPARE_WORKSPACE_ERROR=""
WORKSPACE_DIR=""
prepare_workspace "$branch2" "origin/main"

assert_eq "orphan-dir: auto-recovery succeeds (workspace created)" \
  "$([ -n "$WORKSPACE_DIR" ] && echo yes || echo no)" "yes"
assert_eq "orphan-dir: PREPARE_WORKSPACE_ERROR is empty after recovery" \
  "$PREPARE_WORKSPACE_ERROR" ""
assert_eq "orphan-dir: the workspace is a real git checkout" \
  "$(git -C "$WORKSPACE_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" "true"

# --- Case 3: in-place mode (USE_WORKTREES=0) captures git error too ---
USE_WORKTREES=0
PREPARE_WORKSPACE_ERROR=""
WORKSPACE_DIR=""
prepare_workspace "copilot/3-inplace" "refs/heads/nonexistent-ref-xyz" || true

assert_not_empty "inplace-mode: PREPARE_WORKSPACE_ERROR is set on failure" \
  "$PREPARE_WORKSPACE_ERROR"
assert_eq "inplace-mode: WORKSPACE_DIR is empty after failure" \
  "$WORKSPACE_DIR" ""
USE_WORKTREES=1

# --- Case 4: successful worktree creation leaves PREPARE_WORKSPACE_ERROR empty --
PREPARE_WORKSPACE_ERROR=""
WORKSPACE_DIR=""
prepare_workspace "copilot/4-success" "origin/main"

assert_eq "success: PREPARE_WORKSPACE_ERROR is empty" \
  "$PREPARE_WORKSPACE_ERROR" ""
assert_eq "success: WORKSPACE_DIR is set" \
  "$([ -n "$WORKSPACE_DIR" ] && echo yes || echo no)" "yes"

if [ "$fail" -eq 0 ]; then
  echo "All branch-create-error tests passed."
else
  echo "Some branch-create-error tests FAILED."
fi
exit "$fail"
