#!/usr/bin/env bash
# shellcheck disable=SC2317  # helpers are invoked indirectly by the code under test
#
# Unit tests for log() mirroring in copilot-loop.sh. The TUI's output panel reads
# a run's per-issue/per-PR log file, so for the TUI to show the loop's own
# narration (branch creation and the rest) — not just Copilot's transcript — the
# loop must write those status lines into that file too. log() does this by also
# appending to CURRENT_RUN_LOG when it is set, matching what the bash loop prints
# to the terminal (#126).
#
# log() is extracted verbatim from the script (from its definition to the first
# closing brace) and sourced here, so the real function is exercised.
#
# Run: tests/run-log-mirror.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

log_block="$(sed -n '/^log() {/,/^}/p' "$script")"
[ -n "$log_block" ] || { echo "could not extract log()"; exit 1; }
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

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t runlog)"
trap 'rm -rf "$tmp"' EXIT

# --- With no active run log, log() writes to stdout only ---------------------
CURRENT_RUN_LOG=""
run_log="$tmp/none.log"
out="$(log "issue #7: working on branch copilot/7-x")"
assert_contains "unset: stdout still gets the line" "$out" "issue #7: working on branch copilot/7-x"
assert_eq "unset: no per-run file is created" "$([ -e "$run_log" ] && echo exists || echo missing)" "missing"

# --- With an active run log, log() mirrors the line into that file -----------
CURRENT_RUN_LOG="$tmp/issue-7.log"
out="$(log "issue #7: working on branch copilot/7-x")"
assert_contains "set: stdout still gets the line" "$out" "issue #7: working on branch copilot/7-x"
assert_contains "set: per-run log gets the same line" "$(cat "$CURRENT_RUN_LOG")" "issue #7: working on branch copilot/7-x"

# The mirrored line matches stdout verbatim (timestamp + message), so the TUI
# shows exactly what the terminal shows.
assert_eq "set: mirrored line equals stdout line" "$(cat "$CURRENT_RUN_LOG")" "$out"

# --- Successive calls append in order (interleaved with a run's transcript) --
log "issue #7: running copilot" >/dev/null
printf 'copilot: editing files\n' >>"$CURRENT_RUN_LOG"
log "issue #7: copilot exited with code 0" >/dev/null

body="$(cat "$CURRENT_RUN_LOG")"
assert_contains "append: keeps the branch line"   "$body" "working on branch copilot/7-x"
assert_contains "append: keeps the running line"  "$body" "running copilot"
assert_contains "append: keeps the transcript"    "$body" "copilot: editing files"
assert_contains "append: keeps the exit line"     "$body" "copilot exited with code 0"

# Ordering: branch creation precedes the transcript, which precedes the exit.
first_line="$(head -n1 "$CURRENT_RUN_LOG")"
assert_contains "append: branch line is first" "$first_line" "working on branch copilot/7-x"

if [ "$fail" -eq 0 ]; then
  echo "All run-log-mirror tests passed."
else
  echo "Some run-log-mirror tests FAILED."
fi
exit "$fail"
