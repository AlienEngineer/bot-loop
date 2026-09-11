#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Regression test for issue #90 "stop retry": a failed issue must be marked
# "copilot-failed" and never re-queued for an automatic retry. _fail_issue is
# extracted verbatim from copilot-loop.sh and run with `gh` and the workspace
# helpers mocked, so the real failure path runs without touching GitHub.
#
# Run: tests/stop-retry.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

path_block="$(sed -n '/# >>> path-sanitization helpers >>>/,/# <<< path-sanitization helpers <<</p' "$script")"
[ -n "$path_block" ] || { echo "could not extract path-sanitization helpers"; exit 1; }
eval "$path_block"
ownership_block="$(sed -n '/# >>> worker-ownership helpers >>>/,/# <<< worker-ownership helpers <<</p' "$script")"
[ -n "$ownership_block" ] || { echo "could not extract worker ownership helpers"; exit 1; }
eval "$ownership_block"

fail_block="$(sed -n '/^_fail_issue() {/,/^}/p' "$script")"
[ -n "$fail_block" ] || { echo "could not extract _fail_issue"; exit 1; }
eval "$fail_block"

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
assert_no_match() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'FAIL - %s\n       [%s] contains [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
    *)           printf 'ok   - %s\n' "$desc" ;;
  esac
}

# Config _fail_issue reads (globals in the real script).
# shellcheck disable=SC2034
FAILED_LABEL="copilot-failed"
# shellcheck disable=SC2034
INPROGRESS_LABEL="in-progress"
# shellcheck disable=SC2034
NEEDS_INFO_LABEL="needs-info"
# shellcheck disable=SC2034
OVERRIDE_WORKER_LABEL="override worker"
# shellcheck disable=SC2034
WORKER_LABEL_PREFIX="worker:"
# shellcheck disable=SC2034
TASK_LABEL_PREFIX="bot-loop:task:"
# shellcheck disable=SC2034
WORKER_ID="build-host"
# shellcheck disable=SC2034
WORKER_LABEL="worker:build-host"
# TRIGGER_LABEL is what a re-queue would add; kept so the guard below is explicit.
# shellcheck disable=SC2034
TRIGGER_LABEL="ready"
# shellcheck disable=SC2034
FAILURE_MARKER="<!-- copilot-loop:failed -->"
# _fail_issue cleans up "$branch" (a global set by process_issue).
# shellcheck disable=SC2034
branch="copilot/90-stop-retry"

# Silence logging and the workspace teardown.
# shellcheck disable=SC2329  # invoked indirectly by _fail_issue
log() { :; }
# shellcheck disable=SC2329  # invoked indirectly by _fail_issue
cleanup_workspace() { :; }

EDITS=""
COMMENTS=0
ISSUE_LABELS=$'in-progress\037worker:build-host\037bot-loop:task:process'
label_add() {
  local label="$1"
  label_list_has "$ISSUE_LABELS" "$label" && return 0
  ISSUE_LABELS="${ISSUE_LABELS:+$ISSUE_LABELS$'\037'}$label"
}
label_remove() {
  local wanted="$1" label next=""
  while IFS= read -r label; do
    [ "$label" = "$wanted" ] && continue
    next="${next:+$next$'\037'}$label"
  done < <(printf '%s\n' "$ISSUE_LABELS" | tr '\037' '\n')
  ISSUE_LABELS="$next"
}
# Mock gh: record every label add/remove from `issue edit`; count comments.
# shellcheck disable=SC2329  # invoked indirectly by _fail_issue
gh() {
  case "$1 $2" in
    "issue comment") COMMENTS=$((COMMENTS + 1)) ;;
    "issue view") printf '%s' "$ISSUE_LABELS" ;;
    "issue edit")
      shift 3  # drop "issue" "edit" "<num>"
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    EDITS="${EDITS:+$EDITS }add:$2"; label_add "$2"; shift 2 ;;
          --remove-label) EDITS="${EDITS:+$EDITS }remove:$2"; label_remove "$2"; shift 2 ;;
          *)              shift ;;
        esac
      done ;;
  esac
}

log_file="$(mktemp)"
printf 'some log output\n' >"$log_file"

# First failure: mark failed, clear in-progress, never re-queue.
_fail_issue 90 "$log_file" "git push failed"
assert_eq       "marks failed + clears in-progress" "$EDITS" "add:copilot-failed remove:in-progress"
assert_eq       "unfinished failure retains the machine owner" \
  "$(printf '%s' "$ISSUE_LABELS" | tr '\037' ',' )" \
  "worker:build-host,bot-loop:task:process,copilot-failed"
assert_no_match "never re-adds the trigger label"   "$EDITS" "add:ready"
assert_eq       "comments the failure once"         "$COMMENTS" "1"

# A later invocation from the old process cannot overwrite a finished transition.
EDITS=""
_fail_issue 90 "$log_file" "git push failed"
_fail_issue 90 "$log_file" "git push failed"
assert_eq       "stale failure does not edit labels" "$EDITS" ""
assert_eq       "stale failure does not add comments" "$COMMENTS" "1"

# A fresh retry claim restores in-progress for the same owner; its next failure
# still retains that owner instead of releasing the job to another machine.
ISSUE_LABELS=$'in-progress\037worker:build-host\037bot-loop:task:process'
EDITS=""
_fail_issue 90 "$log_file" "git push failed"
assert_eq "fresh owned retry marks failed again" "$EDITS" \
  "add:copilot-failed remove:in-progress"
assert_no_match "fresh owned retry never re-queues" "$EDITS" "add:ready"

# A foreign worker cannot mark this issue failed or post a stale failure comment.
ISSUE_LABELS=$'in-progress\037worker:other\037bot-loop:task:process'
EDITS=""
_fail_issue 90 "$log_file" "git push failed"
assert_eq "foreign failure makes no label edits" "$EDITS" ""
assert_eq "foreign failure makes no comment" "$COMMENTS" "2"

rm -f "$log_file"

if [ "$fail" -eq 0 ]; then
  echo "All stop-retry tests passed."
else
  echo "Some stop-retry tests FAILED."
fi
exit "$fail"
