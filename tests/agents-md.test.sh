#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034,SC2329  # mocks/config are invoked or read indirectly by the eval'd code
#
# Tests for the one-time AGENTS.md bootstrap in copilot-loop.sh. When the loop
# starts against a repo that has no AGENTS.md nor .github/copilot-instructions.md,
# generate_agents_md runs a read-only Copilot pass that writes a short AGENTS.md
# and opens it as its own PR; when either file already exists (or a bootstrap PR
# is already open) it does nothing. Generation is failure-safe: a copilot run that
# writes nothing never opens a PR and never returns non-zero.
#
# The "agents-md helpers", "workspace helpers" and "copilot-timeout helpers"
# blocks are extracted verbatim from the script between their markers and sourced
# here. agents_md_disabled is asserted as a pure unit; generate_agents_md is
# exercised as an integration test against REAL throwaway git repos (a bare origin
# plus a clone), with only log / run_copilot / gh (and the auto-merge/usage
# helpers) mocked, so the real git and control flow run without touching GitHub or
# any model.
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
WORKSPACE_DIR=""
CURRENT_RUN_LOG=""
BOOT_BRANCH="${BRANCH_PREFIX}agents-md"

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
  return 0
}

# The bootstrap's best-effort extras: keep them out of the way but observable.
# shellcheck disable=SC2329
_report_usage() { printf 'usage %s\n' "${2:-}" >>"$GH_CALLS"; }
# shellcheck disable=SC2329
try_auto_merge() { printf 'automerge %s\n' "${1:-}" >>"$GH_CALLS"; }

copilot_calls() { local n; n="$(grep -c . "$CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
pr_creates()    { local n; n="$(grep -c '^pr create' "$GH_CALLS" 2>/dev/null)"; printf '%s' "${n:-0}"; }
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
assert_eq "missing: local bootstrap branch cleaned up" "$(local_branch "$BOOT_BRANCH")" "no"
assert_eq "missing: working tree clean after run" \
  "$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" "0"

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

# --- idempotent: bootstrap branch already on origin (PR open) -> skip --------
setup_repo
git -C "$clone" push -q origin "main:refs/heads/${BOOT_BRANCH}"   # simulate an earlier run's open PR
generate_agents_md; rc=$?
assert_eq "existing PR: returns success"         "$rc" "0"
assert_eq "existing PR: copilot NOT run"          "$(copilot_calls)" "0"
assert_eq "existing PR: no new PR opened"         "$(pr_creates)" "0"

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
