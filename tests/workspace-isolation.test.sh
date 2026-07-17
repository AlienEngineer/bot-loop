#!/usr/bin/env bash
#
# Tests for per-issue workspace isolation in copilot-loop.sh (issue #93: every
# task must run in its own git worktree — a different folder). Two blocks are
# extracted verbatim from the script (between marker comments) and sourced here:
#   * the USE_WORKTREES default-resolution `case` ("worktree-default helpers"),
#     asserted as a pure unit test so an unset value defaults to worktrees ON;
#   * the workspace helpers (prepare_workspace/cleanup_workspace), exercised as
#     an integration test against a REAL throwaway git repo so we prove each
#     issue lands in a separate worktree directory and is torn down cleanly,
#     without touching GitHub.
#
# Run: tests/workspace-isolation.test.sh
#
# Vars below (WORKTREE_BASE, REPO_DIR, USE_WORKTREES, WORKSPACE_DIR) are consumed
# by the eval'd blocks, which shellcheck cannot trace — silence its false
# positives for unused/uninvoked names.
# shellcheck disable=SC2034,SC2329
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

default_block="$(sed -n '/# >>> worktree-default helpers >>>/,/# <<< worktree-default helpers <<</p' "$script")"
[ -n "$default_block" ] || { echo "could not extract worktree-default helpers (markers missing?)"; exit 1; }

helpers_block="$(sed -n '/# >>> workspace helpers >>>/,/# <<< workspace helpers <<</p' "$script")"
[ -n "$helpers_block" ] || { echo "could not extract workspace helpers (markers missing?)"; exit 1; }
eval "$helpers_block"

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
assert_true()  { local d="$1"; shift; if "$@"; then printf 'ok   - %s\n' "$d"; else printf 'FAIL - %s (expected success)\n' "$d"; fail=1; fi; }
assert_false() { local d="$1"; shift; if "$@"; then printf 'FAIL - %s (expected failure)\n' "$d"; fail=1; else printf 'ok   - %s\n' "$d"; fi; }

# --- Unit: USE_WORKTREES default resolution ----------------------------------
# The `case` mutates $USE_WORKTREES in place; run it for each input and report
# the resolved value. Unset/empty must default to 1 so every task gets its own
# worktree (the whole point of the issue).
resolve() { USE_WORKTREES="$1"; eval "$default_block"; printf '%s' "$USE_WORKTREES"; }

assert_eq "default: unset -> on"   "$(resolve "")"      "1"
assert_eq "default: 1 stays on"    "$(resolve "1")"     "1"
assert_eq "default: true -> on"    "$(resolve "true")"  "1"
assert_eq "default: yes -> on"     "$(resolve "yes")"   "1"
assert_eq "default: on -> on"      "$(resolve "on")"    "1"
assert_eq "default: 0 -> off"      "$(resolve "0")"     "0"
assert_eq "default: false -> off"  "$(resolve "false")" "0"
assert_eq "default: no -> off"     "$(resolve "no")"    "0"
assert_eq "default: off -> off"    "$(resolve "off")"   "0"

# --- Integration: prepare_workspace / cleanup_workspace ----------------------
# Build a real repo with a bare origin and a pushed main, then prove the two
# isolation modes end to end.
root="$(mktemp -d)"
origin="$root/origin.git"
clone="$root/clone"

git init --bare -q "$origin"
git clone -q "$origin" "$clone" 2>/dev/null
cd "$clone" || exit 1
git config user.email test@example.com
git config user.name  test
git config commit.gpgsign false

git commit --allow-empty -qm init
git branch -M main
git push -q -u origin main

REPO_DIR="$clone"
WORKTREE_BASE="$root/copilot-loop-worktrees"

# (default) worktree mode: each issue lands in its own folder, never REPO_DIR.
USE_WORKTREES=1
WORKSPACE_DIR=""
assert_true  "worktree: prepare_workspace succeeds" prepare_workspace "copilot/1-alpha" "origin/main"
assert_eq    "worktree: WORKSPACE_DIR is the worktree folder" "$WORKSPACE_DIR" "$WORKTREE_BASE/copilot-1-alpha"
assert_eq    "worktree: workspace differs from shared checkout" "$([ "$WORKSPACE_DIR" != "$REPO_DIR" ] && echo yes || echo no)" "yes"
assert_eq    "worktree: folder exists on disk" "$([ -d "$WORKSPACE_DIR" ] && echo yes || echo no)" "yes"
assert_true  "worktree: branch created" git -C "$clone" show-ref --verify --quiet "refs/heads/copilot/1-alpha"
assert_eq    "worktree: branch checked out in that folder" "$(git -C "$WORKSPACE_DIR" rev-parse --abbrev-ref HEAD)" "copilot/1-alpha"
# The worktree is locked while the run owns it, so a concurrent cleanup sweep in
# another bot cannot remove it out from under a live session. Match by branch to
# stay robust against symlinked temp paths (macOS /var -> /private/var).
locked_state() {
  git -C "$clone" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$1" '
    /^worktree /{ target=0 }
    $1=="branch" && $2==b { target=1 }
    /^locked/{ if (target) { print "yes"; exit } }'
}
assert_eq    "worktree: locked while in use" "$(locked_state "copilot/1-alpha")" "yes"

# A second issue gets a second, distinct folder — parallel tasks never collide.
WORKSPACE_DIR=""
assert_true  "worktree: second issue prepared" prepare_workspace "copilot/2-beta" "origin/main"
assert_eq    "worktree: second folder is distinct" "$WORKSPACE_DIR" "$WORKTREE_BASE/copilot-2-beta"

# Teardown removes the worktree folder and the local branch.
cleanup_workspace "copilot/1-alpha"
assert_eq    "worktree: folder removed on cleanup" "$([ -d "$WORKTREE_BASE/copilot-1-alpha" ] && echo yes || echo no)" "no"
assert_false "worktree: branch removed on cleanup" git -C "$clone" show-ref --verify --quiet "refs/heads/copilot/1-alpha"
cleanup_workspace "copilot/2-beta"

# --- #106: cleanup_workspace must not delete a worktree another live run owns -
# prepare_workspace locks each worktree with the owning run's pid. Rewrite the
# lock so it looks held by a *different* copilot-loop process that is still
# alive, then prove cleanup_workspace leaves that worktree (and branch) intact
# instead of pulling it out from under the other session.
WORKSPACE_DIR=""
assert_true "shared: prepared" prepare_workspace "copilot/4-shared" "origin/main"
wt_shared="$WORKTREE_BASE/copilot-4-shared"
sleep 300 & other_pid=$!
git -C "$clone" worktree unlock "$wt_shared" >/dev/null 2>&1 || true
git -C "$clone" worktree lock \
  --reason "copilot-loop: copilot/4-shared in progress (pid $other_pid)" "$wt_shared" >/dev/null 2>&1 || true
cleanup_workspace "copilot/4-shared"
assert_eq   "shared: foreign live-locked worktree survives cleanup" "$([ -d "$wt_shared" ] && echo yes || echo no)" "yes"
assert_true "shared: foreign live-locked branch survives cleanup"   git -C "$clone" show-ref --verify --quiet "refs/heads/copilot/4-shared"

# The other run now "finishes": its process exits, leaving a stale lock whose
# pid is dead. cleanup_workspace reclaims the worktree and branch normally.
kill "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true
cleanup_workspace "copilot/4-shared"
assert_eq    "shared: stale (dead-pid) worktree reclaimed" "$([ -d "$wt_shared" ] && echo yes || echo no)" "no"
assert_false "shared: stale (dead-pid) branch removed"     git -C "$clone" show-ref --verify --quiet "refs/heads/copilot/4-shared"

# (opt-out) in-place mode: the branch is checked out in REPO_DIR, no worktree.
USE_WORKTREES=0
WORKSPACE_DIR=""
assert_true  "in-place: prepare_workspace succeeds" prepare_workspace "copilot/3-gamma" "origin/main"
assert_eq    "in-place: WORKSPACE_DIR is the shared checkout" "$WORKSPACE_DIR" "$REPO_DIR"
assert_eq    "in-place: branch checked out in REPO_DIR" "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" "copilot/3-gamma"
cleanup_workspace "copilot/3-gamma"

# --- cleanup -----------------------------------------------------------------
cd "$here" || exit 1
git -C "$clone" worktree prune >/dev/null 2>&1 || true
rm -rf "$root"

if [ "$fail" -eq 0 ]; then
  echo "All workspace-isolation tests passed."
else
  echo "Some workspace-isolation tests FAILED."
fi
exit "$fail"
