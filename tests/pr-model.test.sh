#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317,SC2329,SC2016
#
# User-facing coverage for issue-to-PR model persistence and PR repairs. The
# real helpers and core functions are extracted from copilot-loop.sh; gh, git,
# and Copilot are mocked so the tests exercise the complete argument and label
# flow without touching GitHub or a real repository.
#
# Run: tests/pr-model.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

model_block="$(sed -n '/# >>> pr-model helpers >>>/,/# <<< pr-model helpers <<</p' "$script")"
process_block="$(awk '
  /^process_issue\(\) \{/ { p=1 }
  p { print }
  p && /^}$/ { exit }
' "$script")"
conflict_fn="$(awk '
  /^resolve_pr_conflicts\(\) \{/ { p=1 }
  p { print }
  p && /^}$/ { exit }
' "$script")"
checks_fn="$(awk '
  /^resolve_pr_check_failures\(\) \{/ { p=1 }
  p { print }
  p && /^}$/ { exit }
' "$script")"
review_fn="$(awk '
  /^resolve_pr_review_comments\(\) \{/ { p=1 }
  p { print }
  p && /^}$/ { exit }
' "$script")"

[ -n "$model_block" ] || { echo "could not extract model_block"; exit 1; }
[ -n "$process_block" ] || { echo "could not extract process_block"; exit 1; }
[ -n "$conflict_fn" ] || { echo "could not extract conflict_fn"; exit 1; }
[ -n "$checks_fn" ] || { echo "could not extract checks_fn"; exit 1; }
[ -n "$review_fn" ] || { echo "could not extract review_fn"; exit 1; }

eval "$model_block"
eval "$process_block"
eval "$conflict_fn"
eval "$checks_fn"
eval "$review_fn"

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

assert_contains() {
  local desc="$1" file="$2" text="$3"
  if grep -Fq -- "$text" "$file"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       file: [%s]\n       missing: [%s]\n' "$desc" "$file" "$text"
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# Shared fixtures and mocks
# ---------------------------------------------------------------------------

DEFAULT_BRANCH="main"
BRANCH_PREFIX="copilot/"
REPO_SLUG="example/repo"
INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
CHECKS_UNRESOLVED_LABEL="checks-unresolved"
PR_COMMENT_INPROGRESS_MARKER="<!-- copilot-loop:pr-comment-in-progress -->"
COPILOT_MODEL=""
COPILOT_EFFORT=""
COPILOT_TIMEOUT=""
QUALITY_ASSURANCE=0
TRIAGE_MODEL=""
TRIAGE_MAP=""
TRIAGE_TIMEOUT_MAP=""
SUMMARY_MODEL=""
RESUME_SESSION_ID=""
RESUME_BRANCH=""
COPILOT_RC=0

LOG_DIR="$(mktemp -d)"
REPO_DIR="$(mktemp -d)"
TEST_WORKSPACE="$(mktemp -d)"
REPAIR_WORKSPACE="$(mktemp -d)"
RUN_ARGS_FILE="$(mktemp)"
PR_CREATE_ARGS_FILE="$(mktemp)"
LABEL_CALLS_FILE="$(mktemp)"
USAGE_FILE="$(mktemp)"
trap 'rm -rf "$LOG_DIR" "$REPO_DIR" "$TEST_WORKSPACE" "$REPAIR_WORKSPACE"; rm -f "$RUN_ARGS_FILE" "$PR_CREATE_ARGS_FILE" "$LABEL_CALLS_FILE" "$USAGE_FILE"' EXIT

GH_PR_LABELS="[]"
PR_STATE="OPEN"
TRIAGE_RESULT="trivial"
TRIAGE_SELECTED_MODEL="gpt-luna-5.6"
FAILURE_REASON=""
AUTO_MERGE_CALLED=0
GIT_MODE="normal"
THREAD_RECORD="$(printf 'thread-1\034src/main.go\0344\034@@ hunk\034**reviewer:** please fix')"

log() { :; }
vlog() { :; }
set_worker_issue() { :; }
set_terminal_title() { :; }
cleanup_workspace() { :; }
delete_remote_branch() { :; }
try_auto_merge() { AUTO_MERGE_CALLED=1; }
_report_summary() { :; }
_ask_issue() { :; }
_fail_issue() { FAILURE_REASON="${3:-}"; return 1; }
_fail_pr() { return 1; }
_fail_pr_checks() { return 1; }
comments_have_plan() { return 1; }
maybe_ask_when_vague() { return 1; }
qa_instruction() { :; }
_new_session_id() { printf 'session-id'; }
copilot_session_arg() { printf -- '--session-id=%s' "${2:-session-id}"; }
write_resume_marker() { :; }
clear_resume_marker() { :; }
copilot_run_timed_out() { return 1; }
_report_usage() { printf '%s\n' "${4:-}" >>"$USAGE_FILE"; }
build_commit_message() { printf 'Resolve issue'; }
resolve_rebase_conflicts() { return 0; }
build_pr_conflict_prompt() { printf 'resolve conflicts'; }
build_pr_check_prompt() { printf 'fix checks'; }
build_pr_review_prompt() { printf 'address review'; }
clean_summary() { cat; }
pr_failing_check_names() { printf 'ci/test'; }
pr_review_threads() { printf '%s\n' "$THREAD_RECORD"; }
_post_review_thread_reply() { :; }
ensure_label() {
  printf '%s\n' "$1" >>"$LABEL_CALLS_FILE"
}

triage_issue() { printf '%s' "$TRIAGE_RESULT"; }
parse_triage_map() {
  if [ "$1" = "trivial=${TRIAGE_SELECTED_MODEL}" ] && [ "$2" = "trivial" ]; then
    printf '%s' "$TRIAGE_SELECTED_MODEL"
  fi
}

prepare_workspace() {
  WORKSPACE_DIR="$REPAIR_WORKSPACE"
  mkdir -p "$WORKSPACE_DIR"
  return 0
}

run_copilot() {
  local log_file="$1"
  shift
  printf '%s\n' "$*" >"$RUN_ARGS_FILE"
  printf 'copilot completed\n' >"$log_file"
  COPILOT_RC=0
}

# Return the fields process_issue and each repair function ask GitHub for, while
# recording PR creation arguments and exposing the fixture's persisted labels.
gh() {
  local sub="${1:-} ${2:-}"
  shift 2
  case "$sub" in
    "issue view")
      printf 'Test issue\0Issue body\0\0'
      ;;
    "issue edit"|"pr edit"|"pr comment")
      : ;;
    "label create")
      : ;;
    "pr create")
      printf '%s\n' "$*" >"$PR_CREATE_ARGS_FILE"
      printf 'https://example.test/repo/pull/255\n'
      ;;
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
      case "$json" in
        labels) printf '%s' "$GH_PR_LABELS" ;;
        state) printf '%s\n' "$PR_STATE" ;;
        statusCheckRollup) printf 'ci/test\n' ;;
        *) printf 'feature-branch\0main\0Test PR\0' ;;
      esac
      ;;
    *)
      : ;;
  esac
}

# Git is only used to drive the control flow here. The fixture makes the issue
# branch one commit ahead and lets the repair paths report a changed worktree.
git() {
  case "$*" in
    *" fetch origin "*) return 0 ;;
    *" rev-parse --verify --quiet "*) return 0 ;;
    *" rev-list --count "*) printf '1\n'; return 0 ;;
    *" diff --cached --quiet"*) return 1 ;;
    *" rebase "*) return 0 ;;
    *" diff --name-only --diff-filter=U"*)
      if [ "$GIT_MODE" = "conflict" ]; then
        printf 'conflict.txt\n'
      fi
      return 0
      ;;
    *" merge --no-edit "*)
      [ "$GIT_MODE" = "conflict" ] && return 1
      return 0
      ;;
    *" status --porcelain"*) printf ' M changed.txt\n'; return 0 ;;
    *" add -A"*) return 0 ;;
    *" commit "*) return 0 ;;
    *" push "*) return 0 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Model metadata helpers
# ---------------------------------------------------------------------------

assert_eq "extracts dotted and hyphenated model label" \
  "$(extract_model_tag_from_labels '[{"name":"bug"},{"name":"model:gpt-luna-5.6"}]')" \
  "gpt-luna-5.6"
assert_eq "first model label wins" \
  "$(extract_model_tag_from_labels '[{"name":"model:first-model"},{"name":"model:second-model"}]')" \
  "first-model"
assert_eq "empty model label is ignored" \
  "$(extract_model_tag_from_labels '[{"name":"model:"},{"name":"model:real-model"}]')" \
  "real-model"
assert_eq "model label preserves explicit auto" \
  "$(model_label_for_model auto)" "model:auto"
assert_eq "empty model produces no label" \
  "$(model_label_for_model '')" ""
assert_eq "PR model label wins over worker model" \
  "$(COPILOT_MODEL='worker-model' GH_PR_LABELS='[{"name":"model:gpt-luna-5.6"}]' resolve_pr_model 255)" \
  "gpt-luna-5.6"
assert_eq "unlabelled PR falls back to worker model" \
  "$(COPILOT_MODEL='worker-model' GH_PR_LABELS='[]' resolve_pr_model 255)" \
  "worker-model"
assert_eq "unlabelled PR preserves empty auto fallback" \
  "$(COPILOT_MODEL='' GH_PR_LABELS='[]' resolve_pr_model 255)" \
  ""

# ---------------------------------------------------------------------------
# Issue -> PR persistence, including triage-selected and unpinned runs
# ---------------------------------------------------------------------------

run_issue_case() {
  local worker_model="$1" triage_model="$2" triage_map="$3" labels="$4"
  COPILOT_MODEL="$worker_model"
  TRIAGE_MODEL="$triage_model"
  TRIAGE_MAP="$triage_map"
  TRIAGE_TIMEOUT_MAP=""
  GH_PR_LABELS="$labels"
  FAILURE_REASON=""
  AUTO_MERGE_CALLED=0
  : >"$RUN_ARGS_FILE"
  : >"$PR_CREATE_ARGS_FILE"
  : >"$LABEL_CALLS_FILE"
  : >"$USAGE_FILE"
  process_issue 255
}

run_issue_case "auto" "classifier" "trivial=gpt-luna-5.6" \
  '[{"name":"model:gpt-luna-5.6"}]'
issue_rc=$?
assert_eq "triage-selected issue run opens a PR" "$issue_rc" "0"
assert_contains "triage-selected model is used for issue coding" \
  "$RUN_ARGS_FILE" "--model gpt-luna-5.6"
assert_contains "triage-selected model is labelled on the PR" \
  "$PR_CREATE_ARGS_FILE" "--label model:gpt-luna-5.6"
assert_eq "triage-selected model label is ensured" \
  "$(cat "$LABEL_CALLS_FILE")" "model:gpt-luna-5.6"
assert_eq "triage-selected model is used for issue usage" \
  "$(cat "$USAGE_FILE")" "gpt-luna-5.6"
assert_eq "auto-merge runs only after model metadata is verified" \
  "$AUTO_MERGE_CALLED" "1"

run_issue_case "" "" "" "[]"
issue_rc=$?
assert_eq "unpinned issue run opens a PR" "$issue_rc" "0"
assert_eq "unpinned run has no model label argument" \
  "$(grep -c -- '--label' "$PR_CREATE_ARGS_FILE")" "0"
assert_eq "unpinned run has no model-label creation" \
  "$(wc -l <"$LABEL_CALLS_FILE" | tr -d ' ')" "0"
assert_eq "unpinned run leaves Copilot model selection empty" \
  "$(grep -c -- '--model' "$RUN_ARGS_FILE")" "0"

run_issue_case "gpt-luna-5.6" "" "" "[]"
issue_rc=$?
assert_eq "missing required PR metadata fails the issue" "$issue_rc" "1"
assert_contains "metadata failure is surfaced" \
  <(printf '%s\n' "$FAILURE_REASON") "required model label"
assert_eq "metadata failure does not auto-merge" "$AUTO_MERGE_CALLED" "0"

# ---------------------------------------------------------------------------
# All PR repair paths prefer the persisted model and report that same model.
# ---------------------------------------------------------------------------

run_repair_case() {
  local path="$1" labels="$2" worker_model="$3" expected_model="$4" rc
  GH_PR_LABELS="$labels"
  COPILOT_MODEL="$worker_model"
  GIT_MODE="normal"
  : >"$RUN_ARGS_FILE"
  : >"$USAGE_FILE"
  case "$path" in
    conflict)
      GIT_MODE="conflict"
      printf 'resolved\n' >"$REPAIR_WORKSPACE/conflict.txt"
      resolve_pr_conflicts 255
      ;;
    checks)
      resolve_pr_check_failures 255
      ;;
    review)
      resolve_pr_review_comments 255
      ;;
  esac
  rc=$?
  assert_eq "$path repair succeeds" "$rc" "0"
  if [ -n "$expected_model" ]; then
    assert_contains "$path repair passes its effective model" \
      "$RUN_ARGS_FILE" "--model $expected_model"
  else
    assert_eq "$path repair passes no model when both PR and worker are unpinned" \
      "$(grep -c -- '--model' "$RUN_ARGS_FILE")" "0"
  fi
  assert_eq "$path repair reports the same effective model" \
    "$(cat "$USAGE_FILE")" "$expected_model"
}

run_repair_case conflict '[{"name":"model:gpt-luna-5.6"}]' \
  "worker-model" "gpt-luna-5.6"
run_repair_case checks '[{"name":"model:gpt-luna-5.6"}]' \
  "worker-model" "gpt-luna-5.6"
run_repair_case review '[{"name":"model:gpt-luna-5.6"}]' \
  "worker-model" "gpt-luna-5.6"
run_repair_case checks '[]' "worker-model" "worker-model"
run_repair_case checks '[{"name":"model:auto"}]' "worker-model" "auto"
run_repair_case checks '[]' "" ""

if [ "$fail" -eq 0 ]; then
  echo "All pr-model tests passed."
else
  echo "Some pr-model tests FAILED."
fi
exit "$fail"
