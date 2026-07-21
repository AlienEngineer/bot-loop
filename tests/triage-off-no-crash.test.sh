#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034,SC2016,SC2154  # helpers/vars/snippet are exercised via eval; literal single-quoted match is intentional
#
# Regression test for #216 (and its duplicate on #186): with triage off — the
# default (TRIAGE_MODEL unset) — process_issue crashed right after logging
# "working on branch" with a bare `triage_class: unbound variable` under
# `set -u`, which the loop surfaced only as "shutting down". The run-timeout
# scaling block reads $triage_class even though it is only assigned inside the
# `if [ -n "$TRIAGE_MODEL" ]` branch, so an unset local aborted the whole loop.
#
# This extracts the real model/timeout-selection block from process_issue
# (verbatim, between its stable anchors) and runs it under `set -u` with triage
# off, then on, asserting neither path trips an unbound variable.
#
# Run: tests/triage-off-no-crash.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

# Pull out the block that chooses the coding model and scales the run timeout:
# from the `local coding_model=...` line up to (but not including) the
# `local -a copilot_args=(...)` line that follows it.
snippet="$(awk '
  /local coding_model="\$COPILOT_MODEL"/ {f=1}
  f && /local -a copilot_args=/          {exit}
  f {print}
' "$script")"
[ -n "$snippet" ] || { echo "could not extract the model/timeout selection block"; exit 1; }
case "$snippet" in
  *'[ -n "$triage_class" ]'*) : ;;   # sanity: we grabbed the block that reads it
  *) echo "extracted block does not reference triage_class; anchors moved?"; exit 1 ;;
esac

fail=0
assert_ok() {
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s (rc=%s)\n' "$desc" "$rc"; fail=1; fi
}

# Minimal stand-ins for the collaborators the block calls (only exercised on the
# triage-on path). Values are irrelevant; they just must exist under `set -u`.
log() { :; }
triage_issue()         { printf 'trivial'; }
parse_triage_map()     { printf 'cheap-model'; }
scale_copilot_timeout(){ printf '10m'; }

# The block uses `local`, so it must run inside a function. Wrap it verbatim.
run_block() {
  local num=1 title="t" body="b" log_file=/dev/null prompt="p"
  eval "$snippet"
  # Prove execution reached the end of the block (a crash would have aborted the
  # whole shell before this, since `set -u` errors are not catchable with `||`).
  printf '%s' "$coding_model" >/dev/null
}

# --- triage OFF (the default, the regression) --------------------------------
(
  set -uo pipefail
  COPILOT_MODEL="" COPILOT_TIMEOUT="30m"
  TRIAGE_MODEL="" TRIAGE_MAP="" TRIAGE_TIMEOUT_MAP=""
  run_block
)
assert_ok "triage off: model/timeout selection runs without an unbound variable" "$?"

# --- triage ON (must still work) ---------------------------------------------
(
  set -uo pipefail
  COPILOT_MODEL="base-model" COPILOT_TIMEOUT="30m"
  TRIAGE_MODEL="cheap" TRIAGE_MAP="trivial=cheap-model" TRIAGE_TIMEOUT_MAP="trivial=33%"
  run_block
)
assert_ok "triage on: model/timeout selection still runs" "$?"

if [ "$fail" -eq 0 ]; then
  echo "All triage-off-no-crash tests passed."
else
  echo "Some triage-off-no-crash tests FAILED."
fi
exit "$fail"
