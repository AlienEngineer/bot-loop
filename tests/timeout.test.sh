#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # helpers are invoked indirectly by the eval'd code under test
#
# Unit tests for the Copilot run timeout helpers in copilot-loop.sh. The main
# Copilot runs (issue resolve, PR conflict/checks fix, default-branch sync) are
# time-boxed by COPILOT_TIMEOUT so a stuck run cannot block the loop (issue #60).
# These pin the pure config/normalisation logic that decides whether a timeout is
# in force, what duration is passed to timeout(1), and when an exit code counts as
# a timeout.
#
# The "copilot-timeout helpers" block is extracted verbatim from the script
# between its markers and sourced here, so the real code is exercised without
# running copilot or timeout.
#
# Run: tests/timeout.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> copilot-timeout helpers >>>/,/# <<< copilot-timeout helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract copilot-timeout helpers (markers missing?)"; exit 1; }
eval "$block"

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
# Assert a predicate's exit status: run it, compare "true"/"false" to expectation.
assert_pred() {
  local desc="$1" want="$2"; shift 2
  local got=false
  if "$@"; then got=true; fi
  assert_eq "$desc" "$got" "$want"
}

# --- copilot_timeout_disabled: which specs mean "no timeout" -----------------
assert_pred "disabled: empty"     true  copilot_timeout_disabled ""
assert_pred "disabled: 0"         true  copilot_timeout_disabled "0"
assert_pred "disabled: off"       true  copilot_timeout_disabled "off"
assert_pred "disabled: OFF (case)" true copilot_timeout_disabled "OFF"
assert_pred "disabled: none"      true  copilot_timeout_disabled "none"
assert_pred "disabled: false"     true  copilot_timeout_disabled "false"
assert_pred "disabled: no"        true  copilot_timeout_disabled "no"
assert_pred "disabled: disabled"  true  copilot_timeout_disabled "disabled"
assert_pred "disabled: 0s"        true  copilot_timeout_disabled "0s"
assert_pred "disabled: 0m"        true  copilot_timeout_disabled "0m"
assert_pred "disabled: 00 (leading zero)" true copilot_timeout_disabled "00"
assert_pred "not disabled: 30m"   false copilot_timeout_disabled "30m"
assert_pred "not disabled: 1800"  false copilot_timeout_disabled "1800"
assert_pred "not disabled: 2h"    false copilot_timeout_disabled "2h"
assert_pred "not disabled: garbage" false copilot_timeout_disabled "abc"

# --- normalize_copilot_timeout: spec -> timeout(1) duration ------------------
assert_eq "normalize: 30m"                "$(normalize_copilot_timeout "30m")"    "30m"
assert_eq "normalize: trims + lowercases" "$(normalize_copilot_timeout "  30M ")" "30m"
assert_eq "normalize: bare seconds"       "$(normalize_copilot_timeout "1800")"   "1800"
assert_eq "normalize: seconds suffix"     "$(normalize_copilot_timeout "45s")"    "45s"
assert_eq "normalize: hours"              "$(normalize_copilot_timeout "2h")"     "2h"
assert_eq "normalize: days"               "$(normalize_copilot_timeout "1d")"     "1d"
assert_eq "normalize: garbage -> empty"   "$(normalize_copilot_timeout "abc")"    ""
assert_eq "normalize: typo 30min -> empty" "$(normalize_copilot_timeout "30min")" ""
assert_eq "normalize: compound -> empty"  "$(normalize_copilot_timeout "1h30m")"  ""
assert_eq "normalize: unit only -> empty" "$(normalize_copilot_timeout "m")"      ""
assert_eq "normalize: empty -> empty"     "$(normalize_copilot_timeout "")"       ""

# --- copilot_run_timed_out: 124 counts as a timeout only when one is in force -
assert_pred "timed out: guarded run exits 124"      true  copilot_run_timed_out "30m" "124"
assert_pred "not timed out: guarded run exits 0"    false copilot_run_timed_out "30m" "0"
assert_pred "not timed out: guarded run exits 125"  false copilot_run_timed_out "30m" "125"
assert_pred "not timed out: 124 but timeout off"    false copilot_run_timed_out "" "124"

if [ "$fail" -eq 0 ]; then
  echo "All timeout tests passed."
else
  echo "Some timeout tests FAILED."
fi
exit "$fail"
