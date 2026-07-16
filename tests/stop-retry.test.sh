#!/usr/bin/env bash
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
# Mock gh: record every label add/remove from `issue edit`; count comments.
# shellcheck disable=SC2329  # invoked indirectly by _fail_issue
gh() {
  case "$1 $2" in
    "issue comment") COMMENTS=$((COMMENTS + 1)) ;;
    "issue edit")
      shift 3  # drop "issue" "edit" "<num>"
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    EDITS="${EDITS:+$EDITS }add:$2";    shift 2 ;;
          --remove-label) EDITS="${EDITS:+$EDITS }remove:$2"; shift 2 ;;
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
assert_no_match "never re-adds the trigger label"   "$EDITS" "add:ready"
assert_eq       "comments the failure once"         "$COMMENTS" "1"

# Repeated failures still never re-queue: there is no attempt counter to exhaust,
# so the issue can never be retried in an endless loop.
EDITS=""
_fail_issue 90 "$log_file" "git push failed"
_fail_issue 90 "$log_file" "git push failed"
assert_no_match "still never re-queues on repeat failures" "$EDITS" "add:ready"
assert_eq       "always marks failed on repeat" "$EDITS" \
  "add:copilot-failed remove:in-progress add:copilot-failed remove:in-progress"

rm -f "$log_file"

if [ "$fail" -eq 0 ]; then
  echo "All stop-retry tests passed."
else
  echo "Some stop-retry tests FAILED."
fi
exit "$fail"
