#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd code under test
#
# Unit tests for the loop's shutdown message in copilot-loop.sh. The issue was
# that a run ended with a bare "shutting down" and the operator could not tell
# *why* (#214). cleanup() (the EXIT trap) now captures the exit status and
# reports a reason: an explicit one set by die()/the signal traps, "exited
# normally" on a clean exit, or "unexpected exit <code>" otherwise. die() sets
# that reason so a fatal error's final line explains itself.
#
# die() and cleanup() are extracted verbatim from the script (definition to the
# first closing brace) and sourced here, so the real functions are exercised.
#
# Run: tests/shutdown-reason.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

cleanup_block="$(sed -n '/^cleanup() {/,/^}/p' "$script")"
[ -n "$cleanup_block" ] || { echo "could not extract cleanup()"; exit 1; }
die_block="$(sed -n '/^die() {/,/^}/p' "$script")"
[ -n "$die_block" ] || { echo "could not extract die()"; exit 1; }

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

# Minimal stand-ins for cleanup()'s collaborators so we can observe them without
# touching a real lock or state dir. cleanup() runs inside a command
# substitution (a subshell), so the stubs record that they ran by touching a
# marker file on disk (a variable set in the subshell would not survive).
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t shutdownreason)"
trap 'rm -rf "$tmp"' EXIT
release_github_lock() { : >"$tmp/lock-released"; }
clear_worker_issue()  { : >"$tmp/worker-cleared"; }
log() { printf '%s\n' "$*"; }

eval "$cleanup_block"
eval "$die_block"

# --- A reason set by die()/a signal is reported verbatim, with the code --------
rm -f "$tmp/lock-released" "$tmp/worker-cleared"
SHUTDOWN_REASON="fatal: boom"
false                                  # seed a non-zero exit status
out="$(cleanup)"
assert_contains "reason set: explains the cause"      "$out" "shutting down: fatal: boom"
assert_contains "reason set: includes the exit code"  "$out" "(exit 1)"

# cleanup releases the GitHub lock and drops the worker's issue so the next run
# is never blocked and the TUI stops attributing an issue to a dead pid (#214).
assert_eq "reason set: released the GitHub lock"   "$([ -e "$tmp/lock-released" ] && echo yes || echo no)" "yes"
assert_eq "reason set: cleared the worker's issue" "$([ -e "$tmp/worker-cleared" ] && echo yes || echo no)" "yes"

# --- A clean exit (no reason, code 0) reads as a normal shutdown ---------------
SHUTDOWN_REASON=""
true
out="$(cleanup)"
assert_contains "clean exit: says the loop exited normally" "$out" "loop exited normally (exit 0)"

# --- An unexplained non-zero exit is flagged with its code --------------------
SHUTDOWN_REASON=""
( exit 5 )                             # seed exit status 5
out="$(cleanup)"
assert_contains "unexpected exit: flags it with the code" "$out" "unexpected exit 5"
assert_contains "unexpected exit: points at the error above" "$out" "see the error above"

# --- End to end: a fatal error's final line explains why ----------------------
# die() sets the reason and exits; the EXIT trap's cleanup() then prints a line
# that names the cause, so the operator is no longer left guessing (#214).
end_to_end="$(
  set -uo pipefail
  release_github_lock() { :; }
  clear_worker_issue()  { :; }
  log() { printf '%s\n' "$*"; }
  SHUTDOWN_REASON=""
  eval "$cleanup_block"
  eval "$die_block"
  trap cleanup EXIT
  die "gh call failed"
)"
assert_contains "fatal: prints the FATAL line"                 "$end_to_end" "FATAL: gh call failed"
assert_contains "fatal: shutdown line explains the cause"      "$end_to_end" "shutting down: fatal: gh call failed (exit 1)"

if [ "$fail" -eq 0 ]; then
  echo "All shutdown-reason tests passed."
else
  echo "Some shutdown-reason tests FAILED."
fi
exit "$fail"
