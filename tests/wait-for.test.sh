#!/usr/bin/env bash
#
# Unit tests for the "Wait for: #N" issue-dependency helpers in copilot-loop.sh.
# The functions under test are extracted verbatim from the script (between the
# "wait-for helpers" markers) and sourced here, with `gh` mocked, so the real
# code is exercised without touching GitHub.
#
# Run: tests/wait-for.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> wait-for helpers >>>/,/# <<< wait-for helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract wait-for helpers (markers missing?)"; exit 1; }
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

# --- issue_wait_for: body parsing -------------------------------------------
assert_eq "wait for, single"        "$(issue_wait_for 'Wait for: #1')"                    "1"
assert_eq "wait for, no colon"      "$(issue_wait_for 'wait for #7')"                     "7"
assert_eq "case insensitive"        "$(issue_wait_for 'WAIT FOR: #8')"                    "8"
assert_eq "blocked by, list"        "$(issue_wait_for 'Blocked by: #2, #3')"              "$(printf '2\n3')"
assert_eq "depends on, and"         "$(issue_wait_for 'Depends on #4 and #5')"            "$(printf '4\n5')"
assert_eq "ignores unrelated hash"  "$(issue_wait_for $'See #9 for context\nWait for: #1')" "1"
assert_eq "no directive"            "$(issue_wait_for 'nothing here #x')"                 ""
assert_eq "empty body"              "$(issue_wait_for '')"                                ""
assert_eq "dedup and sort"          "$(issue_wait_for $'Wait for: #3\nBlocked by #1 #3')" "$(printf '1\n3')"
assert_eq "inline sentence"         "$(issue_wait_for 'This one must wait for #12 before starting')" "12"

# --- issue_open_blockers: gate against open dependencies ---------------------
# Mock gh: `gh issue view <n> --json state --jq '.state'` -> state by number.
gh() {
  local n="$3"
  case "$n" in
    1) echo "CLOSED" ;;
    2) echo "OPEN" ;;
    3) echo "CLOSED" ;;
    *) echo "" ;;   # unknown -> not blocking
  esac
}

assert_eq "open dep blocks"         "$(issue_open_blockers 10 'Wait for: #2')"       "2"
assert_eq "closed dep clears"       "$(issue_open_blockers 10 'Wait for: #1')"       ""
assert_eq "mixed keeps open only"   "$(issue_open_blockers 10 'Wait for: #1, #2')"   "2"
assert_eq "all closed clears"       "$(issue_open_blockers 10 'Wait for: #1, #3')"   ""
assert_eq "self reference ignored"  "$(issue_open_blockers 2 'Wait for: #2')"        ""
assert_eq "unknown dep ignored"     "$(issue_open_blockers 10 'Wait for: #99')"      ""
assert_eq "no directive, no block"  "$(issue_open_blockers 10 'just some text')"     ""

if [ "$fail" -eq 0 ]; then
  echo "All wait-for tests passed."
else
  echo "Some wait-for tests FAILED."
fi
exit "$fail"
