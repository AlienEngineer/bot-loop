#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034,SC2329  # mocks/config are invoked or read indirectly by the eval'd code
#
# Tests for the one-time AGENTS.md bootstrap in copilot-loop.sh. When the loop
# starts against a repo that has no AGENTS.md nor .github/copilot-instructions.md,
# generate_agents_md runs a read-only Copilot pass that writes a short AGENTS.md,
# opens it as its own PR and merges that PR so AGENTS.md actually lands on the
# default branch (#235) — otherwise every future run's fresh checkout would still
# have none. When either file already exists (or a bootstrap PR is already open)
# it does nothing. Generation is failure-safe: a copilot run that writes nothing
# never opens a PR, and a merge that is blocked (branch protection) leaves the PR
# open instead of crashing — neither ever returns non-zero.
#
# The "agents-md helpers", "workspace helpers" and "copilot-timeout helpers"
# blocks are extracted verbatim from the script between their markers and sourced
# here. agents_md_disabled is asserted as a pure unit; generate_agents_md is
# exercised as an integration test against REAL throwaway git repos (a bare origin
# plus a clone), with only log / run_copilot / gh (and the usage helper) mocked —
# `gh pr merge` really fast-forwards the fixture's default branch — so the real
# git and control flow run without touching GitHub or any model.
#
# Run: tests/agents-md.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

for marker in "agents-md helpers" "workspace helpers" "copilot-timeout helpers"; do
  block="$(sed -n "/# >>> ${marker} >>>/,/# <<< ${marker} <<</p" "$script")"
  [ -n "$block" ] || { echo "could not extract '${marker}' (markers missing?)"; exit 1; }
  eval "$block"
done

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

# --- Unit: agents_md_disabled (pure) ----------------------------------------
disabled() { agents_md_disabled "$1" && echo yes || echo no; }
assert_eq "disabled: empty"        "$(disabled '')"             "yes"
assert_eq "disabled: off"          "$(disabled 'off')"          "yes"
assert_eq "disabled: none"         "$(disabled 'none')"         "yes"
assert_eq "disabled: no"           "$(disabled 'no')"           "yes"
assert_eq "disabled: 0"            "$(disabled '0')"            "yes"
assert_eq "disabled: false"        "$(disabled 'false')"        "yes"
assert_eq "enabled: claude-sonnet" "$(disabled 'claude-sonnet')" "no"
assert_eq "enabled: gpt-5-mini"    "$(disabled 'gpt-5-mini')"   "no"

# --- Integration: generate_agents_md against real repos ----------------------
# Config the extracted helpers read from the environment.
DEFAULT_BRANCH="main"
USE_WORKTREES=0
BRANCH_PREFIX="copilot/"
AGENTS_MODEL="mid-model"
COPILOT_TIMEOUT=""     # disabled -> copilot_run_timed_out is always false
COPILOT_RC=0
AUTO_MERGE=0
MERGE_METHOD="merge"   # method land_bootstrap_pr merges the bootstrap PR with
WORKSPACE_DIR=""
CURRENT_RUN_LOG=""
BOOT_BRANCH="${BRANCH_PREFIX}agents-md"
PR_OPEN=0              # how many open bootstrap PRs the gh fixture reports
MERGE_FAIL=0           # when 1 the gh fixture refuses `pr merge` (blocked merge)

root="$(mktemp -d)"
trap 'cd "$here" 2>/dev/null; rm -rf "$root"' EXIT

origin=""; clone=""
CALLS=""            # records each run_copilot invocation
GH_CALLS=""         # records each gh / auto-merge / usage invocation
COPILOT_MODE="write"   # "write" creates AGENTS.md; "empty" writes nothing

# Silence the loop's status lines.
# shellcheck disable=SC2329
log() { :; }

# Stand in for a Copilot run: record the call and, in "write" mode, produce the
# AGENTS.md a real read-only pass would create in the workspace.
# shellcheck disable=SC2329
run_copilot() {
  printf 'call\n' >>"$CALLS"
  local log_file="$1"
  case "$COPILOT_MODE" in
    write)
      printf '# %s\n\nConcise repo context.\n' "$(basename "$WORKSPACE_DIR")" >"$WORKSPACE_DIR/AGENTS.md"
      COPILOT_RC=0 ;;
    empty)
      COPILOT_RC=0 ;;
    unavailable)
      # Mimic the CLI rejecting a pinned --model, then succeeding once the
      # bootstrap retries with --model auto.
      case " $* " in
        *" --model auto "*)
          printf '# %s\n\nConcise repo context.\n' "$(basename "$WORKSPACE_DIR")" >"$WORKSPACE_DIR/AGENTS.md"
          COPILOT_RC=0 ;;
        *)
          printf 'Error: Model "%s" from --model flag is not available.\n' "$AGENTS_MODEL" >>"$log_file"
          COPILOT_RC=1 ;;
      esac ;;
  esac
}

# Record gh calls; hand back a fake PR URL for `gh pr create` so the success path
# proceeds without touching GitHub.
# shellcheck disable=SC2329
gh() {
  printf '%s\n' "$*" >>"$GH_CALLS"
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
    printf 'https://example.test/pr/1\n'
  fi
  # `gh pr list --head <branch> --state open --json number --jq length`: the
  # bootstrap uses this to tell an open PR (skip) from a stale branch (regenerate).
  # PR_OPEN controls how many open PRs the fixture reports.
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' "${PR_OPEN:-0}"
  fi
  # `gh pr merge <pr> [--auto] --<method>`: land_bootstrap_pr merges the bootstrap
  # PR so AGENTS.md reaches the default branch. Emulate a real merge by advancing
  # origin's default branch to the bootstrap branch tip (a fast-forward). MERGE_FAIL
  # simulates a blocked merge (branch protection / failing required checks), which
  # must leave the PR open rather than crash.
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
    [ "${MERGE_FAIL:-0}" = "1" ] && return 1
    local _sha
    _sha="$(git -C "$clone" ls-remote origin "refs/heads/$BOOT_BRANCH" 2>/dev/null | awk '{print $1}')"
    [ -n "$_sha" ] && git -C "$clone" push -q origin "$_sha:refs/heads/$DEFAULT_BRANCH" 2>/dev/null
    return 0
  fi
  return 0
}

# The bootstrap's best-effort cost report: keep it out of the way but observable.
# shellcheck disable=SC2329
_report_usage() { printf 'usage %s\n' "${2:-}" >>"$GH_CALLS"; }

copilot_calls() { local n; n="$(grep -c . "$CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
pr_creates()    { local n; n="$(grep -c '^pr create' "$GH_CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
pr_merges()     { local n; n="$(grep -c '^pr merge' "$GH_CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
# Observe origin through the clone's transport: this environment sets
# safe.bareRepository=explicit, so `git -C <bare>` is refused. ls-remote and the
# remote-tracking refs work over the (local) transport just like a real remote.
origin_branch() { [ -n "$(git -C "$clone" ls-remote --heads origin "$1" 2>/dev/null)" ] && echo yes || echo no; }
origin_file()   { git -C "$clone" fetch -q origin "$1" 2>/dev/null; git -C "$clone" show "origin/$1:$2" 2>/dev/null; }
local_branch()  { git -C "$clone" show-ref --verify --quiet "refs/heads/$1" && echo yes || echo no; }

# Build a fresh bare origin + clone (REPO_DIR, on main) with a committed baseline
# that has NO AGENTS.md. LOG_DIR lives OUTSIDE the repo so cleanup_workspace's
# `git clean -fd` never wipes the run logs.
setup_repo() {
  cd "$here" 2>/dev/null || true
  rm -rf "$root"; mkdir -p "$root"
  origin="$root/origin.git"; clone="$root/clone"

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

  REPO_DIR="$clone"
  LOG_DIR="$root/logs"; mkdir -p "$LOG_DIR"
  CALLS="$root/copilot-calls"; : >"$CALLS"
  GH_CALLS="$root/gh-calls";   : >"$GH_CALLS"
  COPILOT_MODE="write"
  WORKSPACE_DIR=""
  PR_OPEN=0
  MERGE_FAIL=0
  cd "$clone" 2>/dev/null || true
}

# Commit a file on main and publish it, so the baseline "already has" that file.
commit_on_main() {
  local path="$1"
  mkdir -p "$clone/$(dirname "$path")" 2>/dev/null || true
  printf 'existing\n' >"$clone/$path"
  git -C "$clone" add "$path"
  git -C "$clone" commit -qm "add $path"
  git -C "$clone" push -q origin main
}

# --- missing: generates AGENTS.md and opens a PR -----------------------------
setup_repo
generate_agents_md; rc=$?
assert_eq "missing: returns success"            "$rc" "0"
assert_eq "missing: copilot run once"           "$(copilot_calls)" "1"
assert_eq "missing: bootstrap branch on origin" "$(origin_branch "$BOOT_BRANCH")" "yes"
assert_eq "missing: AGENTS.md committed to the branch" \
  "$(origin_file "$BOOT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "1"
assert_eq "missing: a PR was opened"            "$(pr_creates)" "1"
assert_eq "missing: the bootstrap PR was merged" "$(pr_merges)" "1"
assert_eq "missing: AGENTS.md landed on the default branch" \
  "$(origin_file "$DEFAULT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "1"
assert_eq "missing: local bootstrap branch cleaned up" "$(local_branch "$BOOT_BRANCH")" "no"
assert_eq "missing: working tree clean after run" \
  "$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" "0"

# --- #235: merge blocked -> PR left open, work not lost, never blocks ---------
# A protected default branch (required reviews/checks) can refuse the merge. The
# bootstrap must stay failure-safe: keep the branch + PR (so a human can merge)
# and never crash the loop, even though AGENTS.md has not reached the default
# branch yet.
setup_repo
MERGE_FAIL=1
generate_agents_md; rc=$?
MERGE_FAIL=0
assert_eq "merge blocked: returns success (never blocks)" "$rc" "0"
assert_eq "merge blocked: copilot still ran"              "$(copilot_calls)" "1"
assert_eq "merge blocked: a PR was still opened"          "$(pr_creates)" "1"
assert_eq "merge blocked: AGENTS.md kept on the bootstrap branch" \
  "$(origin_file "$BOOT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "1"
assert_eq "merge blocked: AGENTS.md NOT forced onto the default branch" \
  "$(origin_file "$DEFAULT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "0"

# --- already has AGENTS.md: no-op -------------------------------------------
setup_repo
commit_on_main "AGENTS.md"
generate_agents_md; rc=$?
assert_eq "has AGENTS.md: returns success"       "$rc" "0"
assert_eq "has AGENTS.md: copilot NOT run"        "$(copilot_calls)" "0"
assert_eq "has AGENTS.md: no PR opened"           "$(pr_creates)" "0"
assert_eq "has AGENTS.md: no bootstrap branch on origin" \
  "$(origin_branch "$BOOT_BRANCH")" "no"

# --- already has .github/copilot-instructions.md: no-op ----------------------
setup_repo
commit_on_main ".github/copilot-instructions.md"
generate_agents_md; rc=$?
assert_eq "has instructions: returns success"    "$rc" "0"
assert_eq "has instructions: copilot NOT run"     "$(copilot_calls)" "0"
assert_eq "has instructions: no PR opened"        "$(pr_creates)" "0"

# --- failure-safe: copilot writes nothing -> no PR, no error -----------------
setup_repo
COPILOT_MODE="empty"
generate_agents_md; rc=$?
assert_eq "empty gen: returns success (not blocking)" "$rc" "0"
assert_eq "empty gen: copilot run once"               "$(copilot_calls)" "1"
assert_eq "empty gen: no PR opened"                   "$(pr_creates)" "0"
assert_eq "empty gen: no bootstrap branch on origin"  "$(origin_branch "$BOOT_BRANCH")" "no"
assert_eq "empty gen: working tree clean"             "$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" "0"

# --- resilient: pinned model unavailable -> retry with auto, then open PR ----
setup_repo
COPILOT_MODE="unavailable"
generate_agents_md; rc=$?
COPILOT_MODE="write"
assert_eq "bad model: returns success"                "$rc" "0"
assert_eq "bad model: copilot run twice (pinned + auto)" "$(copilot_calls)" "2"
assert_eq "bad model: AGENTS.md committed to the branch" \
  "$(origin_file "$BOOT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "1"
assert_eq "bad model: a PR was opened"                "$(pr_creates)" "1"

# --- idempotent: bootstrap branch on origin WITH an open PR -> skip -----------
# A PR still waiting to merge must not be duplicated.
setup_repo
git -C "$clone" push -q origin "main:refs/heads/${BOOT_BRANCH}"   # earlier run's branch
PR_OPEN=1                                                          # ...and its PR is still open
generate_agents_md; rc=$?
assert_eq "open PR: returns success"          "$rc" "0"
assert_eq "open PR: copilot NOT run"          "$(copilot_calls)" "0"
assert_eq "open PR: no new PR opened"         "$(pr_creates)" "0"
assert_eq "open PR: bootstrap branch kept on origin" "$(origin_branch "$BOOT_BRANCH")" "yes"

# --- #227: stale bootstrap branch on origin, NO open PR -> regenerate ---------
# The branch lingers (its PR was closed unmerged, or an earlier `gh pr create`
# failed) but AGENTS.md is still missing, so the loop must create it, not skip
# forever. This is the "not created when missing" regression.
setup_repo
git -C "$clone" push -q origin "main:refs/heads/${BOOT_BRANCH}"   # lingering branch
PR_OPEN=0                                                          # ...but no open PR
generate_agents_md; rc=$?
assert_eq "stale branch: returns success"     "$rc" "0"
assert_eq "stale branch: copilot run once"    "$(copilot_calls)" "1"
assert_eq "stale branch: AGENTS.md committed to the branch" \
  "$(origin_file "$BOOT_BRANCH" AGENTS.md | grep -c 'Concise repo context')" "1"
assert_eq "stale branch: a PR was opened"     "$(pr_creates)" "1"
assert_eq "stale branch: local bootstrap branch cleaned up" "$(local_branch "$BOOT_BRANCH")" "no"

# --- disabled: AGENTS_MODEL off -> skip entirely -----------------------------
setup_repo
AGENTS_MODEL=""     # what --agents-model off / AGENTS_MODEL=off normalises to
generate_agents_md; rc=$?
AGENTS_MODEL="mid-model"
assert_eq "disabled: returns success"            "$rc" "0"
assert_eq "disabled: copilot NOT run"             "$(copilot_calls)" "0"
assert_eq "disabled: no PR opened"                "$(pr_creates)" "0"

# --- Docs: the flag/env var are surfaced to users ----------------------------
assert_eq "help documents --agents-model" \
  "$(bash "$script" --help 2>/dev/null | grep -c -- '--agents-model')" "1"
assert_eq "help lists AGENTS_MODEL env var" \
  "$(bash "$script" --help 2>/dev/null | grep -c 'AGENTS_MODEL')" "1"
assert_eq "README documents AGENTS_MODEL" \
  "$([ "$(grep -c 'AGENTS_MODEL' "$here/../README.md")" -gt 0 ] && echo yes || echo no)" "yes"

if [ "$fail" -eq 0 ]; then
  echo "All agents-md tests passed."
else
  echo "Some agents-md tests FAILED."
fi
exit "$fail"
