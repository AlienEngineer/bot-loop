#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # helpers are invoked indirectly by the eval'd code under test
#
# Unit tests for the Copilot run timeout helpers in copilot-loop.sh. The main
# Copilot runs (issue resolve, PR conflict/checks fix, default-branch sync) are
# time-boxed by COPILOT_TIMEOUT so a stuck run cannot block the loop (issue #60),
# and that per-run limit is scaled by triage difficulty (issue #190): a trivial
# issue is killed sooner and a complex one gets more time. These pin the pure
# config/normalisation logic that decides whether a timeout is in force, what
# duration is passed to timeout(1), when an exit code counts as a timeout, and how
# the baseline is scaled per difficulty class.
#
# The "copilot-timeout helpers" and "triage helpers" blocks are extracted verbatim
# from the script between their markers and sourced here, so the real code is
# exercised without running copilot or timeout. (parse_triage_map from the triage
# block is used to exercise the class -> factor -> scaled-timeout path a user
# configures through TRIAGE_TIMEOUT_MAP.)
#
# Run: tests/timeout.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

for marker in "copilot-timeout helpers" "triage helpers"; do
  block="$(sed -n "/# >>> ${marker} >>>/,/# <<< ${marker} <<</p" "$script")"
  [ -n "$block" ] || { echo "could not extract '${marker}' (markers missing?)"; exit 1; }
  eval "$block"
done

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

# --- _copilot_timeout_to_secs: spec -> whole seconds -------------------------
assert_eq "to_secs: 30m"            "$(_copilot_timeout_to_secs "30m")"   "1800"
assert_eq "to_secs: bare seconds"   "$(_copilot_timeout_to_secs "1800")"  "1800"
assert_eq "to_secs: seconds suffix" "$(_copilot_timeout_to_secs "45s")"   "45"
assert_eq "to_secs: hours"          "$(_copilot_timeout_to_secs "2h")"    "7200"
assert_eq "to_secs: days"           "$(_copilot_timeout_to_secs "1d")"    "86400"
assert_eq "to_secs: trims + case"   "$(_copilot_timeout_to_secs " 30M ")" "1800"
assert_eq "to_secs: garbage empty"  "$(_copilot_timeout_to_secs "30min")" ""
assert_eq "to_secs: empty empty"    "$(_copilot_timeout_to_secs "")"      ""

# --- _copilot_timeout_fmt_secs: seconds -> readable timeout(1) spec ----------
assert_eq "fmt: whole minutes"      "$(_copilot_timeout_fmt_secs 3600)"   "60m"
assert_eq "fmt: 15 minutes"         "$(_copilot_timeout_fmt_secs 900)"    "15m"
assert_eq "fmt: exactly 1 minute"   "$(_copilot_timeout_fmt_secs 60)"     "1m"
assert_eq "fmt: not whole minutes"  "$(_copilot_timeout_fmt_secs 594)"    "594s"
assert_eq "fmt: sub-minute"         "$(_copilot_timeout_fmt_secs 45)"     "45s"

# --- scale_copilot_timeout: percentage factors (issue #190) ------------------
# Baseline 30m: trivial (33%) is killed sooner, complex (200%) gets more time.
assert_eq "scale: trivial 33% of 30m"  "$(scale_copilot_timeout "30m" "33%")"  "594s"
assert_eq "scale: complex 200% of 30m" "$(scale_copilot_timeout "30m" "200%")" "60m"
assert_eq "scale: 50% of 30m"          "$(scale_copilot_timeout "30m" "50%")"  "15m"
assert_eq "scale: bare int is percent" "$(scale_copilot_timeout "30m" "50")"   "15m"
assert_eq "scale: percent of bare secs" "$(scale_copilot_timeout "1800" "50%")" "15m"
assert_eq "scale: percent of hours"    "$(scale_copilot_timeout "2h" "50%")"   "60m"
assert_eq "scale: tiny percent clamps to 1s" "$(scale_copilot_timeout "60s" "1%")" "1s"

# --- scale_copilot_timeout: absolute duration overrides ----------------------
assert_eq "scale: absolute minutes"    "$(scale_copilot_timeout "30m" "10m")"  "10m"
assert_eq "scale: absolute 45m"        "$(scale_copilot_timeout "30m" "45m")"  "45m"
assert_eq "scale: absolute seconds"    "$(scale_copilot_timeout "30m" "1800s")" "1800s"

# --- scale_copilot_timeout: no-ops keep the baseline unchanged ---------------
assert_eq "scale: normal (empty factor) keeps baseline" "$(scale_copilot_timeout "30m" "")"    "30m"
assert_eq "scale: 100% keeps baseline"                  "$(scale_copilot_timeout "30m" "100%")" "30m"
assert_eq "scale: bare 100 keeps baseline"              "$(scale_copilot_timeout "30m" "100")"  "30m"
assert_eq "scale: 0% keeps baseline (no instant kill)"  "$(scale_copilot_timeout "30m" "0")"    "30m"
assert_eq "scale: garbage factor keeps baseline"        "$(scale_copilot_timeout "30m" "abc")"  "30m"

# --- scale_copilot_timeout: a disabled baseline stays disabled ("0"/"off" wins)
assert_eq "scale: disabled baseline stays off (percent)"  "$(scale_copilot_timeout "" "33%")" ""
assert_eq "scale: disabled baseline stays off (absolute)" "$(scale_copilot_timeout "" "10m")" ""

# --- Composition: TRIAGE_TIMEOUT_MAP a user configures, resolved per class ----
# This is the exact path process_issue runs: parse_triage_map picks the factor for
# the triage class, then scale_copilot_timeout scales the baseline COPILOT_TIMEOUT.
map='trivial=33%,complex=200%'   # the built-in default when triage is on
base='30m'
scale_for() { scale_copilot_timeout "$base" "$(parse_triage_map "$map" "$1")"; }
assert_eq "map: trivial issue killed sooner" "$(scale_for trivial)" "594s"
assert_eq "map: normal issue keeps baseline" "$(scale_for normal)"  "30m"
assert_eq "map: complex issue gets more time" "$(scale_for complex)" "60m"
# The user-visible ordering: trivial < normal (baseline) < complex.
assert_pred "map: trivial < baseline seconds" true \
  test "$(_copilot_timeout_to_secs "$(scale_for trivial)")" -lt "$(_copilot_timeout_to_secs "$base")"
assert_pred "map: complex > baseline seconds" true \
  test "$(_copilot_timeout_to_secs "$(scale_for complex)")" -gt "$(_copilot_timeout_to_secs "$base")"
# An absolute-duration map works too, and a disabled baseline stays disabled.
absmap='trivial=10m,complex=60m'
assert_eq "abs map: trivial -> 10m" "$(scale_copilot_timeout "$base" "$(parse_triage_map "$absmap" trivial)")" "10m"
assert_eq "abs map: complex -> 60m" "$(scale_copilot_timeout "$base" "$(parse_triage_map "$absmap" complex)")" "60m"
assert_eq "map: complex with timeout off stays off" \
  "$(scale_copilot_timeout "" "$(parse_triage_map "$map" complex)")" ""

# --- Docs: the flag/env var are surfaced to users ----------------------------
assert_eq "help documents --triage-timeout-map" \
  "$(bash "$script" --help 2>/dev/null | grep -c -- '--triage-timeout-map')" "1"
assert_eq "help lists TRIAGE_TIMEOUT_MAP env var" \
  "$([ "$(bash "$script" --help 2>/dev/null | grep -c 'TRIAGE_TIMEOUT_MAP')" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "README documents TRIAGE_TIMEOUT_MAP" \
  "$([ "$(grep -c 'TRIAGE_TIMEOUT_MAP' "$here/../README.md")" -gt 0 ] && echo yes || echo no)" "yes"

if [ "$fail" -eq 0 ]; then
  echo "All timeout tests passed."
else
  echo "Some timeout tests FAILED."
fi
exit "$fail"
