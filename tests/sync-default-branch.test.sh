#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034,SC2329  # mocks/config are invoked or read indirectly by the eval'd code
#
# Tests for the pre-work remote sync in copilot-loop.sh. Before starting any new
# work each pass the loop syncs the local default branch with origin/<default>
# (see sync_default_branch): a clean update fast-forwards, and when the local
# default branch has diverged and the merge conflicts the conflicts are handed to
# Copilot to resolve so the loop can move forward — kept local, never pushed.
#
# The "sync-default helpers" block is extracted verbatim from the script between
# its markers and sourced here. classify_sync_state is asserted as a pure unit;
# sync_default_branch is exercised as an integration test against REAL throwaway
# git repos (a bare origin plus two clones) with only `log` and `run_copilot`
# mocked, so the actual git and control flow run without touching GitHub.
#
# Run: tests/sync-default-branch.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

sync_block="$(sed -n '/# >>> sync-default helpers >>>/,/# <<< sync-default helpers <<</p' "$script")"
[ -n "$sync_block" ] || { echo "could not extract sync-default helpers (markers missing?)"; exit 1; }
eval "$sync_block"

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

# --- Unit: classify_sync_state (pure) ---------------------------------------
# yes/no come from the two `git merge-base --is-ancestor` checks the caller runs.
assert_eq "classify: upstream already local -> insync" "$(classify_sync_state yes no)"  "insync"
assert_eq "classify: equal (both ancestors) -> insync" "$(classify_sync_state yes yes)" "insync"
assert_eq "classify: local behind only -> ff"          "$(classify_sync_state no yes)"  "ff"
assert_eq "classify: each side unique -> diverged"     "$(classify_sync_state no no)"   "diverged"

# --- Integration: sync_default_branch against real repos ---------------------
# Config the extracted helper reads from the environment.
DEFAULT_BRANCH="main"
SYNC_REMOTE=1
COPILOT_MODEL=""
COPILOT_RC=0

root="$(mktemp -d)"
trap 'cd "$here" 2>/dev/null; rm -rf "$root"' EXIT

origin=""; clone=""; other=""
CALLS=""            # records each run_copilot invocation
RESOLVE_MODE="resolve"   # "resolve" clears the conflict; "leave" keeps the markers

# Silence the loop's status lines.
# shellcheck disable=SC2329
log() { :; }

# Stand in for a Copilot run: record the call, and either resolve the conflicted
# file (removing the markers) or leave it untouched, mirroring what a real
# resolution / non-resolution does to the working tree.
# shellcheck disable=SC2329
run_copilot() {
  printf 'call\n' >>"$CALLS"
  if [ "$RESOLVE_MODE" = "resolve" ]; then
    printf 'resolved\n' >"$REPO_DIR/file.txt"
  fi
  COPILOT_RC=0
}

calls() { local n; n="$(grep -c . "$CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

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
  printf '.copilot-loop/\n' >"$clone/.gitignore"
  git -C "$clone" add file.txt .gitignore
  git -C "$clone" commit -qm init
  git -C "$clone" branch -M main
  git -C "$clone" push -q -u origin main

  git clone -q "$origin" "$other" 2>/dev/null
  git -C "$other" config user.email t@e.com
  git -C "$other" config user.name  t
  git -C "$other" config commit.gpgsign false

  REPO_DIR="$clone"; WORK_DIR="$clone/.copilot-loop"; LOG_DIR="$WORK_DIR/logs"
  CALLS="$root/copilot-calls"; : >"$CALLS"
}

# Publish a commit to origin/main from the second clone (the "remote" moving on).
remote_commit() {
  printf '%s\n' "$1" >"$other/file.txt"
  git -C "$other" add file.txt
  git -C "$other" commit -qm "remote: $1"
  git -C "$other" push -q origin main
}

# Make an un-pushed local commit on the primary clone's main (a local divergence).
local_commit() {
  printf '%s\n' "$1" >"$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" commit -qm "local: $1"
}

# --- in sync: no-op, no Copilot ---------------------------------------------
setup_repo
before="$(git -C "$clone" rev-parse main)"
sync_default_branch
assert_eq "insync: main unchanged"        "$(git -C "$clone" rev-parse main)" "$before"
assert_eq "insync: copilot not run"        "$(calls)" "0"

# --- behind origin: fast-forward, no Copilot --------------------------------
setup_repo
remote_commit "ahead"
sync_default_branch
assert_eq "ff: main advanced to origin/main" \
  "$(git -C "$clone" rev-parse main)" "$(git -C "$clone" rev-parse origin/main)"
assert_eq "ff: main matches the published remote commit" \
  "$(git -C "$clone" rev-parse main)" "$(git -C "$other" rev-parse main)"
assert_eq "ff: copilot not run"             "$(calls)" "0"
assert_eq "ff: not a merge commit (one parent)" \
  "$(git -C "$clone" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "2"

# --- diverged, Copilot resolves: merged locally, not pushed -----------------
setup_repo
RESOLVE_MODE="resolve"
remote_commit "remote-side"
remote_sha="$(git -C "$other" rev-parse HEAD)"
local_commit "local-side"
local_sha="$(git -C "$clone" rev-parse main)"
sync_default_branch
assert_eq "diverged/resolve: copilot run once"        "$(calls)" "1"
assert_eq "diverged/resolve: conflict file resolved"  "$(cat "$clone/file.txt")" "resolved"
assert_eq "diverged/resolve: HEAD is a merge commit (two parents)" \
  "$(git -C "$clone" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" "3"
assert_eq "diverged/resolve: both sides are merged in" \
  "$( { git -C "$clone" merge-base --is-ancestor "$local_sha" HEAD && git -C "$clone" merge-base --is-ancestor "$remote_sha" HEAD; } && echo yes || echo no)" "yes"
assert_eq "diverged/resolve: origin NOT pushed (still remote-side)" \
  "$(git -C "$clone" rev-parse origin/main)" "$remote_sha"
assert_eq "diverged/resolve: no leftover unresolved marker" \
  "$([ -f "$WORK_DIR/sync-unresolved" ] && echo yes || echo no)" "no"
assert_eq "diverged/resolve: working tree clean" \
  "$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" "0"

# --- diverged, Copilot cannot resolve: aborted, marked, then skipped --------
setup_repo
RESOLVE_MODE="leave"
remote_commit "remote-side"
remote_sha="$(git -C "$other" rev-parse HEAD)"
local_commit "local-side"
local_sha="$(git -C "$clone" rev-parse main)"
sync_default_branch
assert_eq "diverged/leave: copilot run once"          "$(calls)" "1"
assert_eq "diverged/leave: merge aborted, main unchanged" \
  "$(git -C "$clone" rev-parse main)" "$local_sha"
assert_eq "diverged/leave: working tree clean (no markers left)" \
  "$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" "0"
assert_eq "diverged/leave: unresolved marker written" \
  "$(cat "$WORK_DIR/sync-unresolved" 2>/dev/null)" "$local_sha $remote_sha"

# Second pass on the identical divergence must be skipped (no new Copilot run).
sync_default_branch
assert_eq "diverged/leave: identical divergence skipped (still one call)" "$(calls)" "1"
assert_eq "diverged/leave: main still unchanged after skip" \
  "$(git -C "$clone" rev-parse main)" "$local_sha"

# --- diverged but default branch not checked out here: skip, no Copilot ------
setup_repo
remote_commit "remote-side"
local_commit "local-side"
local_sha="$(git -C "$clone" rev-parse main)"
git_q "$clone" checkout --detach
sync_default_branch
assert_eq "not-checked-out: copilot not run"          "$(calls)" "0"
assert_eq "not-checked-out: main branch untouched" \
  "$(git -C "$clone" rev-parse main)" "$local_sha"

if [ "$fail" -eq 0 ]; then
  echo "All sync-default-branch tests passed."
else
  echo "Some sync-default-branch tests FAILED."
fi
exit "$fail"
