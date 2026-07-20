#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd code under test
#
# Unit tests for the loop's worker->issue state and verbose narration in
# copilot-loop.sh (#214).
#
# 1. set_worker_issue()/clear_worker_issue() publish which issue this loop
#    process (its pid) is working, in .copilot-loop/workers/worker-<pid>.issue,
#    so the TUI can show a bot's pid on that issue's row. The reader trusts the
#    file only for a *running* pid, so the writer just keeps it current and drops
#    it between issues and on shutdown.
# 2. vlog() emits extra loop-level detail only when VERBOSE=1, so the operator
#    can opt into "more output about the loop itself" without changing the
#    default output.
#
# The functions are extracted verbatim from the script and sourced here.
#
# Run: tests/worker-issue-state.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

set_block="$(sed -n '/^set_worker_issue() {/,/^}/p' "$script")"
clear_block="$(sed -n '/^clear_worker_issue() {/,/^}/p' "$script")"
vlog_block="$(sed -n '/^vlog() {/,/^}/p' "$script")"
log_block="$(sed -n '/^log() {/,/^}/p' "$script")"
[ -n "$set_block" ]   || { echo "could not extract set_worker_issue()"; exit 1; }
[ -n "$clear_block" ] || { echo "could not extract clear_worker_issue()"; exit 1; }
[ -n "$vlog_block" ]  || { echo "could not extract vlog()"; exit 1; }
[ -n "$log_block" ]   || { echo "could not extract log()"; exit 1; }

eval "$set_block"
eval "$clear_block"
eval "$vlog_block"
eval "$log_block"

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
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)           printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t workerissue)"
trap 'rm -rf "$tmp"' EXIT

WORK_DIR="$tmp/.copilot-loop"
WORKER_STATE_DIR="$WORK_DIR/workers"
CURRENT_RUN_LOG=""
state_file="$WORKER_STATE_DIR/worker-$$.issue"

# --- set_worker_issue records the issue this pid is on -----------------------
set_worker_issue 42
assert_eq "set: writes the pid's state file"        "$([ -f "$state_file" ] && echo yes || echo no)" "yes"
assert_eq "set: file holds the issue number"        "$(cat "$state_file")" "42"

# The TUI keys the file by *this* process's pid, matching the pid it recorded for
# the worker it spawned, so the mapping lands on the right bot (#214).
assert_contains "set: file name carries the pid" "$state_file" "worker-$$.issue"

# --- set_worker_issue overwrites when the worker moves to a new issue ---------
set_worker_issue 99
assert_eq "set: updates to the new issue number"    "$(cat "$state_file")" "99"

# --- clear_worker_issue drops the assignment (between issues / on shutdown) ---
clear_worker_issue
assert_eq "clear: removes the pid's state file"     "$([ -e "$state_file" ] && echo exists || echo missing)" "missing"

# clear is safe to call when there is nothing to clear (top of every pass).
clear_worker_issue
assert_eq "clear: is a no-op when already absent"   "$([ -e "$state_file" ] && echo exists || echo missing)" "missing"

# --- vlog only speaks when VERBOSE=1 -----------------------------------------
VERBOSE=0
out="$(vlog "loop: syncing default branch")"
assert_eq "vlog: silent when verbose is off"        "$out" ""

VERBOSE=1
out="$(vlog "loop: syncing default branch")"
assert_contains "vlog: prints the detail when verbose is on" "$out" "loop: syncing default branch"
# Tagged so the extra loop-level lines are easy to spot and filter (#214).
assert_contains "vlog: tags verbose lines"          "$out" "·"

if [ "$fail" -eq 0 ]; then
  echo "All worker-issue-state tests passed."
else
  echo "Some worker-issue-state tests FAILED."
fi
exit "$fail"
