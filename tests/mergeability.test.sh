#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Unit tests for the mergeability-wait helpers in copilot-loop.sh. GitHub computes
# a PR's mergeable state asynchronously, so just after a push or a base-branch move
# it reports UNKNOWN for a while. next_conflicted_pr only matches CONFLICTING, so
# before the per-iteration conflict check the loop waits for that computation to
# settle — otherwise a PR that is really in conflict but not yet evaluated would be
# skipped and the loop would start a ready issue with the conflict still open.
# These tests pin that "wait until mergeability is known, bounded" behaviour so the
# conflict check runs before ready-issue selection sees accurate state (issue #124).
#
# unknown_mergeability_prs and ensure_pr_mergeability_known are extracted verbatim
# from the script between the "mergeability helpers" markers and run with `gh`,
# `sleep` and `log` mocked (the real jq selection filter is applied to a fixture),
# so the actual code is exercised without touching GitHub or really sleeping.
#
# Run: tests/mergeability.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

merge_block="$(sed -n '/# >>> mergeability helpers >>>/,/# <<< mergeability helpers <<</p' "$script")"
[ -n "$merge_block" ] || { echo "could not extract mergeability helpers (markers missing?)"; exit 1; }
eval "$merge_block"

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

# --- Config the extracted helpers read from the environment -----------------
# shellcheck disable=SC2034  # consumed by the eval'd helpers, invisible to shellcheck
DEFAULT_BRANCH="main"

# Fixtures/counters live in files (not shell vars) so mutations survive the command
# substitution subshell that ensure_pr_mergeability_known's helpers run in.
PR_FILE="$(mktemp)"
POKES_FILE="$(mktemp)"
SLEEPS_FILE="$(mktemp)"
trap 'rm -f "$PR_FILE" "$POKES_FILE" "$SLEEPS_FILE"' EXIT

set_fixture() { cat >"$PR_FILE"; }
reset_counters() { : >"$POKES_FILE"; : >"$SLEEPS_FILE"; }

# When set, a `gh pr view <n>` (a "poke") flips that PR from UNKNOWN to MERGEABLE,
# simulating GitHub finishing its background evaluation.
FLIP_ON_POKE=0

# Silence log lines so test output stays clean.
# shellcheck disable=SC2329  # invoked indirectly by the extracted helpers
log() { :; }
# Record each sleep instead of really pausing, so the test is instant.
# shellcheck disable=SC2329
sleep() { printf 'sleep\n' >>"$SLEEPS_FILE"; }

# Mock gh: `pr list` applies the REAL jq filter the helper built to the fixture;
# `pr view` records the poke and (optionally) mutates the fixture so a later list
# reflects GitHub having finished computing that PR's mergeability.
# shellcheck disable=SC2329  # invoked indirectly by the extracted helpers
gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "pr list")
      local jqf=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "--jq" ]; then jqf="$2"; shift 2; else shift; fi
      done
      jq -r "$jqf" "$PR_FILE"
      ;;
    "pr view")
      local num="$1"; shift
      printf '%s\n' "$num" >>"$POKES_FILE"
      if [ "$FLIP_ON_POKE" = "1" ]; then
        local tmp; tmp="$(mktemp)"
        jq --arg n "$num" \
          'map(if (.number|tostring)==$n then (.mergeable="MERGEABLE") else . end)' \
          "$PR_FILE" >"$tmp" && mv "$tmp" "$PR_FILE"
      fi
      ;;
  esac
}

count_lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }

# --- unknown_mergeability_prs: pure selection -------------------------------
set_fixture <<'JSON'
[ {"number":16,"mergeable":"MERGEABLE"},
  {"number":10,"mergeable":"UNKNOWN"},
  {"number":8,"mergeable":"CONFLICTING"},
  {"number":18,"mergeable":"UNKNOWN"} ]
JSON

assert_eq "lists only UNKNOWN PR numbers" "$(unknown_mergeability_prs | sort | tr '\n' ' ')" "10 18 "

set_fixture <<'JSON'
[ {"number":16,"mergeable":"MERGEABLE"},
  {"number":8,"mergeable":"CONFLICTING"} ]
JSON
assert_eq "no UNKNOWN -> empty" "$(unknown_mergeability_prs)" ""

# --- ensure_pr_mergeability_known: returns at once when all known -----------
# shellcheck disable=SC2034  # read by the extracted helper
MERGEABILITY_WAIT_ATTEMPTS=5
# shellcheck disable=SC2034
MERGEABILITY_WAIT_SECONDS=3
reset_counters
ensure_pr_mergeability_known; rc=$?
assert_eq "all-known: returns success"      "$rc" "0"
assert_eq "all-known: never sleeps"         "$(count_lines "$SLEEPS_FILE")" "0"
assert_eq "all-known: never pokes a PR"     "$(count_lines "$POKES_FILE")" "0"

# --- ensure_pr_mergeability_known: clears after GitHub computes -------------
# 12 starts UNKNOWN; the first poke flips it to MERGEABLE, so the wait ends on the
# second pass without exhausting the attempt budget.
FLIP_ON_POKE=1
set_fixture <<'JSON'
[ {"number":9,"mergeable":"CONFLICTING"},
  {"number":12,"mergeable":"UNKNOWN"} ]
JSON
reset_counters
ensure_pr_mergeability_known; rc=$?
assert_eq "clears: returns success"                 "$rc" "0"
assert_eq "clears: pokes the unknown PR once"       "$(cat "$POKES_FILE")" "12"
assert_eq "clears: sleeps exactly once before recheck" "$(count_lines "$SLEEPS_FILE")" "1"
assert_eq "clears: UNKNOWN is gone afterwards"       "$(unknown_mergeability_prs)" ""

# --- ensure_pr_mergeability_known: bounded when a PR stays UNKNOWN ----------
# GitHub never resolves this PR; the wait must give up after the budget, not hang.
FLIP_ON_POKE=0
# shellcheck disable=SC2034  # read by the extracted helper
MERGEABILITY_WAIT_ATTEMPTS=3
set_fixture <<'JSON'
[ {"number":7,"mergeable":"UNKNOWN"} ]
JSON
reset_counters
ensure_pr_mergeability_known; rc=$?
assert_eq "stuck: still returns success (never blocks)" "$rc" "0"
assert_eq "stuck: pokes on every attempt"               "$(count_lines "$POKES_FILE")" "3"
assert_eq "stuck: sleeps attempts-1 times"              "$(count_lines "$SLEEPS_FILE")" "2"

# --- ensure_pr_mergeability_known: disabled with 0 attempts ------------------
# shellcheck disable=SC2034  # read by the extracted helper
MERGEABILITY_WAIT_ATTEMPTS=0
set_fixture <<'JSON'
[ {"number":7,"mergeable":"UNKNOWN"} ]
JSON
reset_counters
ensure_pr_mergeability_known; rc=$?
assert_eq "disabled: returns success"   "$rc" "0"
assert_eq "disabled: never pokes"       "$(count_lines "$POKES_FILE")" "0"
assert_eq "disabled: never sleeps"      "$(count_lines "$SLEEPS_FILE")" "0"

if [ "$fail" -eq 0 ]; then
  echo "All mergeability tests passed."
else
  echo "Some mergeability tests FAILED."
fi
exit "$fail"
