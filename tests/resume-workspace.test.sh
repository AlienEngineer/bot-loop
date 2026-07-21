#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd code under test
#
# Tests for prepare_workspace_resume (#233): when an interrupted run is resumed,
# its partial work must survive. The loop must reopen the run's existing
# worktree/branch instead of resetting the branch to origin/<default> (which is
# what a fresh run does and which would throw the partial work away).
#
# User-perspective outcomes verified against a real git repo:
#   - worktree survived the kill  -> reuse it as-is, partial work intact;
#   - worktree gone but branch left -> check the branch out again at its own tip,
#     committed partial work intact (NOT reset to origin/default);
#   - nothing left to reuse        -> fall back to a fresh branch from
#     origin/<default> (context still lives in the resumed Copilot session).
#
# Run: tests/resume-workspace.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

extract() { sed -n "/^$1() {/,/^}/p" "$script"; }
for fn in _worktree_path prepare_workspace_resume; do
  block="$(extract "$fn")"
  [ -n "$block" ] || { echo "could not extract $fn() from copilot-loop.sh"; exit 1; }
  eval "$block"
done

fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"; fail=1; fi
}
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)           printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}

command -v git >/dev/null 2>&1 || { echo "git required for this test"; exit 1; }

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t resumews)"
trap 'git -C "$REPO_DIR" worktree prune >/dev/null 2>&1; rm -rf "$tmp"' EXIT

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

# Stub the fresh-workspace fallback so the "nothing to reuse" path is observable
# and, if a reuse case ever regresses into it, the failure is a clear sentinel
# instead of git running against the wrong repo. It records the branch/start ref.
prepare_workspace() { WORKSPACE_DIR="FALLBACK:$1:$2"; return 0; }

# --- Case A: the worktree survived -> reuse it, partial work intact -----------
branchA="copilot/7-alpha"
wtA="$(_worktree_path "$branchA")"
git -C "$REPO_DIR" worktree add -q "$wtA" -b "$branchA" >/dev/null 2>&1
printf 'partial A\n' >"$wtA/partial.txt"
git -C "$wtA" add -A
git -C "$wtA" commit -qm "partial work A"

WORKSPACE_DIR=""
prepare_workspace_resume "$branchA"
assert_eq "case A: a workspace was selected" \
  "$([ -n "$WORKSPACE_DIR" ] && echo yes || echo no)" "yes"
assert_eq "case A: reuses the SAME surviving worktree" \
  "$(git -C "$WORKSPACE_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  "$(git -C "$wtA" rev-parse --show-toplevel 2>/dev/null)"
assert_contains "case A: partial work is intact (not reset to origin/main)" \
  "$(git -C "$WORKSPACE_DIR" log --oneline 2>/dev/null)" "partial work A"

# --- Case B: worktree lost but branch survived -> re-check-out at its own tip --
branchB="copilot/8-beta"
wtB="$(_worktree_path "$branchB")"
git -C "$REPO_DIR" worktree add -q "$wtB" -b "$branchB" >/dev/null 2>&1
printf 'partial B\n' >"$wtB/partial.txt"
git -C "$wtB" add -A
git -C "$wtB" commit -qm "partial work B"
# Simulate the loss of the worktree folder while keeping the branch (as a crashed
# run or an interrupted cleanup would leave things).
git -C "$REPO_DIR" worktree remove --force "$wtB" >/dev/null 2>&1
git -C "$REPO_DIR" worktree prune >/dev/null 2>&1
assert_eq "case B: worktree folder is gone" "$([ -d "$wtB" ] && echo exists || echo gone)" "gone"
assert_eq "case B: branch still exists" \
  "$(git -C "$REPO_DIR" rev-parse --verify --quiet "refs/heads/$branchB" >/dev/null 2>&1 && echo yes || echo no)" "yes"

WORKSPACE_DIR=""
prepare_workspace_resume "$branchB"
assert_eq "case B: a workspace was selected" \
  "$([ -n "$WORKSPACE_DIR" ] && echo yes || echo no)" "yes"
assert_contains "case B: committed partial work preserved from the branch tip" \
  "$(git -C "$WORKSPACE_DIR" log --oneline 2>/dev/null)" "partial work B"

# --- Case C: nothing to reuse -> fall back to a fresh branch from origin/main --
# Uses the prepare_workspace stub defined above to observe the fallback (branch +
# start ref) without recreating the whole fresh-workspace machinery.
branchC="copilot/9-gamma"   # never created, no worktree, no branch
WORKSPACE_DIR=""
prepare_workspace_resume "$branchC"
assert_contains "case C: falls back to a fresh workspace for the branch" \
  "$WORKSPACE_DIR" "FALLBACK:copilot/9-gamma"
assert_contains "case C: fresh fallback starts from origin/<default>" \
  "$WORKSPACE_DIR" "origin/main"

if [ "$fail" -eq 0 ]; then
  echo "All resume-workspace tests passed."
else
  echo "Some resume-workspace tests FAILED."
fi
exit "$fail"
