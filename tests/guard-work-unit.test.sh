#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd functions under test
#
# Unit tests for guard() and its EXIT-trap helper _guard_on_exit() in
# copilot-loop.sh. These isolate each unit of work (an issue, plan, or PR fix) in
# a subshell so an *unexpected* exit — most importantly a `set -u` unbound
# variable crash, which the `|| true` on the call site does NOT catch — fails
# only that unit instead of silently killing the whole loop, and records *why*
# in the unit's run log so the operator is not left staring at "shutting down"
# (#214, #216).
#
# The two functions are extracted verbatim from the script and sourced here, so
# the real code is exercised.
#
# Run: tests/guard-work-unit.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

on_exit_block="$(sed -n '/^_guard_on_exit() {/,/^}/p' "$script")"
[ -n "$on_exit_block" ] || { echo "could not extract _guard_on_exit()"; exit 1; }
guard_block="$(sed -n '/^guard() {/,/^}/p' "$script")"
[ -n "$guard_block" ] || { echo "could not extract guard()"; exit 1; }

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

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t guardtest)"
trap 'rm -rf "$tmp"' EXIT
WORK_DIR="$tmp"
LOG_DIR="$tmp"
CURRENT_RUN_LOG=""
# Mirror log() faithfully: to stdout and, when set, into the active run log.
log() {
  local line
  line="$(printf '%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$line"
  if [ -n "${CURRENT_RUN_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$CURRENT_RUN_LOG" 2>/dev/null || true
  fi
}

eval "$on_exit_block"
eval "$guard_block"

# --- Work units to run under guard ------------------------------------------
# Mimics the real regression: open a run log, narrate a branch, then crash on an
# unbound variable exactly as process_issue did with triage off.
unit_crash() {
  CURRENT_RUN_LOG="$LOG_DIR/issue-216-run.log"; : >"$CURRENT_RUN_LOG"
  log "issue #216: working on branch copilot/216-x"
  local triage_class
  [ -n "$triage_class" ] && true
  log "issue #216: unreachable"
}
# A failure the unit already reported itself (the normal _fail_issue path).
unit_handled_fail() {
  CURRENT_RUN_LOG="$LOG_DIR/issue-99-run.log"; : >"$CURRENT_RUN_LOG"
  log "issue #99: failing cleanly and reporting it"
  return 1
}
unit_ok() {
  CURRENT_RUN_LOG="$LOG_DIR/issue-1-run.log"; : >"$CURRENT_RUN_LOG"
  log "issue #1: done"
  return 0
}

# --- A crash is contained, and explained in the run log ----------------------
CURRENT_RUN_LOG=""
out="$(guard "issue #216" unit_crash 2>&1)"; rc=$?
# Reaching this line at all proves the crash did not kill the harness.
printf 'ok   - crash: the loop survived a set -u crash in a unit\n'
assert_contains "crash: guard reports the non-zero exit" "$out" "issue #216 ended unexpectedly"
assert_contains "crash: names the actual cause"          "$out" "unbound variable"
run_log="$(cat "$LOG_DIR/issue-216-run.log")"
assert_contains "crash: run log keeps the branch line"   "$run_log" "working on branch copilot/216-x"
assert_contains "crash: run log explains the crash"      "$run_log" "run ended unexpectedly"
assert_contains "crash: run log captures the error"      "$run_log" "unbound variable"
if [ "$rc" -ne 0 ]; then printf 'ok   - crash: guard returns non-zero\n'; else printf 'FAIL - crash: guard should return non-zero\n'; fail=1; fi

# --- A handled non-zero return is NOT branded a crash ------------------------
CURRENT_RUN_LOG=""
out="$(guard "issue #99" unit_handled_fail 2>&1)"; rc=$?
assert_not_contains "handled fail: not branded a crash"      "$out" "ended unexpectedly"
run_log="$(cat "$LOG_DIR/issue-99-run.log")"
assert_not_contains "handled fail: run log not polluted"     "$run_log" "run ended unexpectedly"
assert_contains "handled fail: unit's own line is kept"      "$run_log" "failing cleanly"
if [ "$rc" -eq 1 ]; then printf 'ok   - handled fail: guard preserves the unit exit code\n'; else printf 'FAIL - handled fail: expected rc 1, got %s\n' "$rc"; fail=1; fi

# --- A clean success is silent ------------------------------------------------
CURRENT_RUN_LOG=""
out="$(guard "issue #1" unit_ok 2>&1)"; rc=$?
assert_not_contains "ok: no crash summary"        "$out" "ended unexpectedly"
run_log="$(cat "$LOG_DIR/issue-1-run.log")"
assert_not_contains "ok: run log not polluted"    "$run_log" "run ended unexpectedly"
if [ "$rc" -eq 0 ]; then printf 'ok   - ok: guard returns 0\n'; else printf 'FAIL - ok: expected rc 0, got %s\n' "$rc"; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "All guard-work-unit tests passed."
else
  echo "Some guard-work-unit tests FAILED."
fi
exit "$fail"
