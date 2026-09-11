#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329  # extracted functions and stubs are invoked indirectly
#
# Regression test for the PR check-fix prompt crash on Bash 3.2. The prompt
# builders are extracted from copilot-loop.sh, and the real check-fix resolver
# runs with GitHub, workspace, Copilot, and reporting helpers mocked. This
# exercises the user-visible path far enough to capture the prompt passed to
# Copilot without contacting GitHub or changing a repository.
#
# Run: tests/pr-check-fix-prompt.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

prompt_block="$(sed -n '/# >>> pr-prompt helpers >>>/,/# <<< pr-prompt helpers <<</p' "$script")"
[ -n "$prompt_block" ] || { echo "could not extract PR prompt helpers"; exit 1; }
checks_block="$(sed -n '/^pr_failing_check_names() {/,/^# >>> mergeability helpers >>>/p' "$script")"
[ -n "$checks_block" ] || { echo "could not extract PR check resolver"; exit 1; }
pr_prompt_section="$(sed -n '/# >>> pr-prompt helpers >>>/,/^# >>> mergeability helpers >>>/p' "$script")"
[ -n "$pr_prompt_section" ] || { echo "could not extract PR prompt call sites"; exit 1; }

eval "$prompt_block"
eval "$checks_block"

fail=0
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)           printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}
assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'FAIL - %s\n       [%s] unexpectedly contains [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
    *)           printf 'ok   - %s\n' "$desc" ;;
  esac
}
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"
    fail=1
  fi
}

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t pr-check-fix-prompt)"
trap 'rm -rf "$tmp"' EXIT

# --- Config consumed by the extracted resolver ------------------------------
DEFAULT_BRANCH="main"
CHECKS_UNRESOLVED_LABEL="checks-unresolved"
INPROGRESS_LABEL="in-progress"
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
COPILOT_MODEL=""
COPILOT_EFFORT=""
COPILOT_TIMEOUT=""
LOG_DIR="$tmp/logs"
REPO_DIR="$tmp/repo"
WORKSPACE_DIR="$tmp/workspace"
PROMPT_FILE="$tmp/copilot-prompt"
FAILING_CHECKS="rust-tui"
COPILOT_RC=1
mkdir -p "$LOG_DIR" "$REPO_DIR" "$WORKSPACE_DIR"

# --- Stubs for helpers called by resolve_pr_check_failures -------------------
log() { :; }
prepare_workspace() { return 0; }
cleanup_workspace() { :; }
set_terminal_title() { :; }
_report_usage() { :; }
copilot_run_timed_out() { return 1; }
_fail_pr_checks() { return 1; }

run_copilot() {
  [ "${2:-}" = "-p" ] && printf '%s' "${3:-}" >"$PROMPT_FILE"
  COPILOT_RC=0
}

# Mock PR metadata and failing-check discovery. The resolver's metadata call
# uses NUL-delimited fields, while pr_failing_check_names only needs the
# configured check-name output.
gh() {
  local sub="${1:-} ${2:-}"
  shift 2
  case "$sub" in
    "pr view")
      local json=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--json" ]; then
          json="${2:-}"
          shift 2
        else
          shift
        fi
      done
      if [ "$json" = "statusCheckRollup" ]; then
        [ -n "$FAILING_CHECKS" ] && printf '%s\n' "$FAILING_CHECKS"
      else
        printf 'copilot/339-fix\0main\0PR 339\0'
      fi
      ;;
    "pr edit"|"pr comment")
      :
      ;;
    *)
      return 0
      ;;
  esac
}

# --- The shared builders retain the existing prompt content ------------------
conflict_prompt="$(build_pr_conflict_prompt main copilot/339-fix 339 'src/lib.rs')"
assert_contains "conflict builder names the PR branch" "$conflict_prompt" "copilot/339-fix"
assert_contains "conflict builder includes conflict files" "$conflict_prompt" "src/lib.rs"
assert_contains "conflict builder preserves no-commit instructions" "$conflict_prompt" "Do NOT run git commit, git merge, git push, or create"

review_prompt="$(build_pr_review_prompt copilot/339-fix 339 src/lib.rs 42 '@@ -1,2 +1,2 @@' 'please fix this')"
assert_contains "review builder names the PR number" "$review_prompt" "pull request #339"
assert_contains "review builder includes the review thread" "$review_prompt" "please fix this"
assert_contains "review builder preserves verification instructions" "$review_prompt" "run the existing tests to verify nothing broke"

# --- A failing check reaches Copilot instead of crashing ---------------------
: >"$PROMPT_FILE"
resolve_pr_check_failures 339 >/dev/null 2>&1
resolver_rc=$?
check_prompt="$(cat "$PROMPT_FILE")"
assert_eq "check resolver reaches the controlled no-change path" "$resolver_rc" "1"
assert_contains "check prompt names the PR branch" "$check_prompt" "copilot/339-fix"
assert_contains "check prompt names the PR number" "$check_prompt" "pull request #339"
assert_contains "check prompt includes the failing check" "$check_prompt" "rust-tui"
assert_contains "check prompt includes local verification instructions" "$check_prompt" "build, test, or lint commands locally"
assert_contains "check prompt preserves no-commit instructions" "$check_prompt" "Do NOT run git commit, git push, or create branches"

# Empty check output keeps the resolver alive and uses the documented fallback.
FAILING_CHECKS=""
: >"$PROMPT_FILE"
resolve_pr_check_failures 339 >/dev/null 2>&1
fallback_prompt="$(cat "$PROMPT_FILE")"
assert_contains "check prompt uses unknown when no checks are named" "$fallback_prompt" "checks are failing: unknown"

# Keep this regression covered on modern Bash too, where the old nested heredoc
# can happen to parse successfully.
assert_not_contains "affected PR prompt code has no nested heredoc command substitution" \
  "$pr_prompt_section" 'prompt="$(cat <<EOF'

if [ "$fail" -eq 0 ]; then
  echo "All PR check-fix prompt tests passed."
else
  echo "Some PR check-fix prompt tests FAILED."
fi
exit "$fail"
