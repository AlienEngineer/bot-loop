#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Tests for the branch/worktree cleanup helpers in copilot-loop.sh. The functions
# under test are extracted verbatim from the script (between the "cleanup helpers"
# markers) and sourced here, then exercised two ways:
#   * branch_is_ours as pure unit tests (the safety gate that decides which
#     branches cleanup is ever allowed to touch);
#   * sweep_merged_branches as an integration test against a REAL throwaway git
#     repo with `gh` mocked, so the merged-branch sweep is verified end to end
#     (local branch + worktree removal, remote-branch deletion, and the safety
#     rules) without touching GitHub.
#
# Run: tests/cleanup-branches.test.sh
#
# Vars below (DEFAULT_BRANCH, BRANCH_PREFIX, REPO_DIR, CLEANUP_MERGED,
# DELETE_REMOTE_BRANCH) and the log/gh/loc/rem functions are consumed indirectly
# by the eval'd helper block and the assert_* dispatchers, which shellcheck
# cannot trace — silence its unused/uninvoked false positives.
# shellcheck disable=SC2034,SC2329
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> cleanup helpers >>>/,/# <<< cleanup helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract cleanup helpers (markers missing?)"; exit 1; }
eval "$block"

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

# --- Unit: branch_is_ours (the safety gate) ----------------------------------
# branch_is_ours reads $DEFAULT_BRANCH and $BRANCH_PREFIX, mirroring the script.
DEFAULT_BRANCH="main"
BRANCH_PREFIX="copilot/"

assert_true  "ours: numbered work branch"   branch_is_ours "copilot/12-fix-thing"
assert_true  "ours: nested slug"            branch_is_ours "copilot/9-a-b-c"
assert_false "not ours: default branch"     branch_is_ours "main"
assert_false "not ours: empty"              branch_is_ours ""
assert_false "not ours: human branch"       branch_is_ours "feature/x"
assert_false "not ours: prefix only"        branch_is_ours "copilot/"
assert_false "not ours: prefix substring"   branch_is_ours "copilothing"

# A different default branch is likewise never ours even with the prefix shape.
DEFAULT_BRANCH="copilot/keep"
assert_false "not ours: default even if prefixed" branch_is_ours "copilot/keep"
DEFAULT_BRANCH="main"

# --- Integration: sweep_merged_branches --------------------------------------
# Build a real repo with a bare origin and several branches in different states,
# mock `gh pr list`, run the sweep, and assert exactly the merged, safe, own
# branches (and their worktrees/remote refs) were removed.
log() { :; }                 # silence the sweep's progress logging
CLEANUP_MERGED=1
DELETE_REMOTE_BRANCH=1

# gh mock: the only call the sweep makes is the merged-PR head-branch listing.
gh() {
  case "$*" in
    *"pr list"*"--state merged"*)
      printf '%s\n' "copilot/1-merged" "copilot/3-squash" "copilot/5-wt" "copilot/6-remote" "copilot/9-locked"
      ;;
    *) : ;;
  esac
}

root="$(mktemp -d)"
origin="$root/origin.git"
clone="$root/clone"
wt5="$root/wt-5"
wt9="$root/wt-9"

git init --bare -q "$origin"
git clone -q "$origin" "$clone" 2>/dev/null
cd "$clone" || exit 1
git config user.email test@example.com
git config user.name  test
git config commit.gpgsign false

git commit --allow-empty -qm init
git branch -M main
git push -q -u origin main

# helper: create branch <name> off main with one commit; push unless $2 = nopush
mk_branch() {
  local name="$1" push="${2:-push}"
  git switch -q -c "$name" main
  echo "$name" > "${name##*/}.txt"
  git add -A && git commit -qm "work on $name"
  [ "$push" = push ] && git push -q -u origin "$name"
  git switch -q main
}
# helper: fast-forward-free merge of <name> into main, then push main
merge_into_main() {
  git switch -q main
  git merge --no-ff -q -m "merge $1" "$1"
  git push -q origin main
}

# (1) merged (ancestor of origin/main), pushed  -> remove local + remote
mk_branch "copilot/1-merged"; merge_into_main "copilot/1-merged"
# (2) open PR: not merged, pushed               -> KEEP local + remote
mk_branch "copilot/2-open"
# (3) "squash merged": in merged list, NOT pushed, commit not in main
#     -> KEEP (branch_has_unpushed_work guard preserves un-pushed work)
mk_branch "copilot/3-squash" nopush
# (4) human branch merged into main             -> KEEP (not ours)
mk_branch "feature/x" nopush; merge_into_main "feature/x"
# (5) merged, pushed, checked out in a worktree -> remove local + worktree + remote
mk_branch "copilot/5-wt"; merge_into_main "copilot/5-wt"
# (6) merged, pushed, local branch already gone -> delete lingering remote only
mk_branch "copilot/6-remote"; merge_into_main "copilot/6-remote"
git branch -qD "copilot/6-remote"
# (9) merged, pushed, checked out in a LOCKED worktree (a live run owns it)
#     -> KEEP local + worktree + remote until the run finishes and unlocks it
mk_branch "copilot/9-locked"; merge_into_main "copilot/9-locked"

# Park the checkout on a detached HEAD so no branch is "current" (mirrors the
# loop between iterations) and add the worktree for branch 5.
git switch -q --detach main
git worktree add -q "$wt5" "copilot/5-wt"
# Branch 9's worktree stands in for an in-progress run: locked so the sweep must
# leave it (and its branch/remote) alone.
git worktree add -q "$wt9" "copilot/9-locked"
git worktree lock "$wt9" >/dev/null 2>&1 || true

REPO_DIR="$clone"
sweep_merged_branches

# --- assertions --------------------------------------------------------------
loc()  { git -C "$clone" show-ref --verify --quiet "refs/heads/$1"; }        # 0 = exists
rem()  { git ls-remote --heads "$origin" "refs/heads/$1" | grep -q .; }      # 0 = exists

assert_false "1: merged local branch removed"     loc "copilot/1-merged"
assert_false "1: merged remote branch deleted"    rem "copilot/1-merged"

assert_true  "2: open local branch kept"          loc "copilot/2-open"
assert_true  "2: open remote branch kept"         rem "copilot/2-open"

assert_true  "3: un-pushed branch preserved"      loc "copilot/3-squash"

assert_true  "4: human merged branch untouched"   loc "feature/x"
assert_true  "default branch never removed"       loc "main"
assert_true  "default remote never removed"       rem "main"

assert_false "5: merged worktree branch removed"  loc "copilot/5-wt"
assert_false "5: merged worktree remote deleted"  rem "copilot/5-wt"
assert_eq    "5: worktree directory removed"      "$([ -d "$wt5" ] && echo yes || echo no)" "no"

assert_false "6: lingering merged remote deleted" rem "copilot/6-remote"

assert_true  "9: in-use (locked) worktree branch kept"  loc "copilot/9-locked"
assert_true  "9: in-use (locked) worktree remote kept"  rem "copilot/9-locked"
assert_eq    "9: in-use worktree directory kept"        "$([ -d "$wt9" ] && echo yes || echo no)" "yes"

# --- Integration: cleanup disabled is a no-op --------------------------------
mk_branch "copilot/7-merged"; merge_into_main "copilot/7-merged"
git switch -q --detach main
CLEANUP_MERGED=0
sweep_merged_branches
assert_true  "disabled: local branch kept"        loc "copilot/7-merged"
assert_true  "disabled: remote branch kept"       rem "copilot/7-merged"
CLEANUP_MERGED=1

# --- Integration: remote deletion opt-out ------------------------------------
mk_branch "copilot/8-merged"; merge_into_main "copilot/8-merged"
git switch -q --detach main
DELETE_REMOTE_BRANCH=0
gh() { case "$*" in *"pr list"*"--state merged"*) printf '%s\n' "copilot/8-merged" ;; *) : ;; esac; }
sweep_merged_branches
assert_false "opt-out: merged local branch removed"  loc "copilot/8-merged"
assert_true  "opt-out: remote branch preserved"      rem "copilot/8-merged"
DELETE_REMOTE_BRANCH=1

# --- Defence-in-depth: remove_local_branch refuses an in-use worktree ---------
# The sweep already skips locked worktrees before calling remove_local_branch,
# but the destructive primitive must be safe on its own too: a concurrent run
# can lock a worktree in the window between the sweep's check and this call
# (#106). A direct call must leave a locked worktree (and its branch) intact,
# yet still remove an unlocked one.
wt10="$root/wt-10"
wt11="$root/wt-11"
git worktree add -q "$wt10" -b "copilot/10-inuse" main
git worktree lock "$wt10" >/dev/null 2>&1 || true
remove_local_branch "copilot/10-inuse"
assert_true  "10: locked worktree branch kept (direct call)"      loc "copilot/10-inuse"
assert_eq    "10: locked worktree directory kept (direct call)"   "$([ -d "$wt10" ] && echo yes || echo no)" "yes"

git worktree add -q "$wt11" -b "copilot/11-idle" main
remove_local_branch "copilot/11-idle"
assert_false "11: unlocked worktree branch removed (direct call)" loc "copilot/11-idle"
assert_eq    "11: unlocked worktree directory removed (direct call)" "$([ -d "$wt11" ] && echo yes || echo no)" "no"

# --- cleanup -----------------------------------------------------------------
cd "$here" || exit 1
git -C "$clone" worktree unlock "$wt9"  >/dev/null 2>&1 || true
git -C "$clone" worktree unlock "$wt10" >/dev/null 2>&1 || true
git -C "$clone" worktree prune >/dev/null 2>&1 || true
rm -rf "$root"

if [ "$fail" -eq 0 ]; then
  echo "All cleanup-branches tests passed."
else
  echo "Some cleanup-branches tests FAILED."
fi
exit "$fail"
