#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Unit tests for the failing-checks-PR claiming helpers in copilot-loop.sh. Before
# picking a new issue the loop looks for open PRs whose CI checks are failing and
# hands one to Copilot to fix; to stop two instances grabbing the SAME PR it claims
# a PR by adding the "in-progress" label under the GitHub lock, and the selector
# skips any PR that is conflicting (handled by the conflict path first) or already
# carrying "in-progress", "conflict-unresolved" or "checks-unresolved". A check
# counts as failing only when it is a completed CheckRun with a failing conclusion
# or a StatusContext in a failing state — pending/successful/skipped/neutral checks
# are ignored so a PR whose CI is still running or green is left alone (issue #127).
#
# next_failing_checks_pr and claim_next_failing_pr are extracted verbatim from the
# script between the "failing-checks-pr helpers" markers and run with `gh` mocked
# (the real jq selection filter is applied to a fixture), so the actual code is
# exercised without touching GitHub.
#
# Run: tests/failing-checks-pr.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

checks_block="$(sed -n '/# >>> failing-checks-pr helpers >>>/,/# <<< failing-checks-pr helpers <<</p' "$script")"
[ -n "$checks_block" ] || { echo "could not extract failing-checks-pr helpers (markers missing?)"; exit 1; }
eval "$checks_block"

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
# shellcheck disable=SC2034
INPROGRESS_LABEL="in-progress"
# shellcheck disable=SC2034
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
# shellcheck disable=SC2034
CHECKS_UNRESOLVED_LABEL="checks-unresolved"

# Fixtures/edits live in files (not shell vars) so mutations survive the command
# substitution subshell that claim_next_failing_pr runs in.
PR_FILE="$(mktemp)"
EDITS_FILE="$(mktemp)"
: >"$EDITS_FILE"
trap 'rm -f "$PR_FILE" "$EDITS_FILE"' EXIT

set_fixture() { cat >"$PR_FILE"; }

# Silence the helper's log lines and make the lock a no-op so the real selection
# and claim logic runs unchanged.
# shellcheck disable=SC2329  # invoked indirectly by the extracted helpers
log() { :; }
# shellcheck disable=SC2329
acquire_github_lock() { return 0; }
# shellcheck disable=SC2329
release_github_lock() { :; }

# Mock gh: `pr list` applies the REAL jq filter the helper built to the fixture;
# `pr edit` records the label change and mutates the fixture so a later selection
# reflects it (this is what makes a claimed PR invisible to the next claim).
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
    "pr edit")
      local num="$1"; shift
      local action="" label=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    action="add";    label="$2"; shift 2 ;;
          --remove-label) action="remove"; label="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      printf '%s:%s:%s\n' "$action" "$num" "$label" >>"$EDITS_FILE"
      local tmp; tmp="$(mktemp)"
      if [ "$action" = "add" ]; then
        jq --arg n "$num" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels += [{"name":$l}]) else . end)' \
          "$PR_FILE" >"$tmp" && mv "$tmp" "$PR_FILE"
      else
        jq --arg n "$num" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels |= map(select(.name != $l))) else . end)' \
          "$PR_FILE" >"$tmp" && mv "$tmp" "$PR_FILE"
      fi
      ;;
  esac
}

# --- next_failing_checks_pr: pure selection (no claim) ----------------------
# 20 mixes a passing and a failing CheckRun (any failing check makes it eligible);
# 30 fails via a StatusContext. 22 is all green, 18 is still running (pending), and
# 24/26/32 fail but are already claimed (in-progress) or given up on
# (checks-unresolved / conflict-unresolved). 28 is conflicting, which the conflict
# path handles first, so it is skipped here.
set_fixture <<'JSON'
[ {"number":22,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","status":"COMPLETED","name":"test"}]},
  {"number":20,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","status":"COMPLETED","name":"test"},{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"rust-tui"}]},
  {"number":30,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"StatusContext","state":"ERROR","context":"ci/ext"}]},
  {"number":24,"mergeable":"MERGEABLE","labels":[{"name":"in-progress"}],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":26,"mergeable":"MERGEABLE","labels":[{"name":"checks-unresolved"}],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":32,"mergeable":"MERGEABLE","labels":[{"name":"conflict-unresolved"}],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":28,"mergeable":"CONFLICTING","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":18,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":null,"status":"IN_PROGRESS","name":"test"}]} ]
JSON

assert_eq "selects lowest-numbered eligible PR with a failing check" "$(next_failing_checks_pr)" "20"

# Only green / pending / already-claimed / conflicting PRs left -> nothing.
set_fixture <<'JSON'
[ {"number":22,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","status":"COMPLETED","name":"test"}]},
  {"number":18,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":null,"status":"IN_PROGRESS","name":"test"}]},
  {"number":24,"mergeable":"MERGEABLE","labels":[{"name":"in-progress"}],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":26,"mergeable":"MERGEABLE","labels":[{"name":"checks-unresolved"}],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]},
  {"number":28,"mergeable":"CONFLICTING","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"test"}]} ]
JSON

assert_eq "skips green / pending / claimed / unresolved / conflicting" "$(next_failing_checks_pr)" ""

# --- failing-conclusion coverage: TIMED_OUT fails, NEUTRAL/SKIPPED do not ----
set_fixture <<'JSON'
[ {"number":42,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"NEUTRAL","status":"COMPLETED","name":"lint"}]},
  {"number":44,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SKIPPED","status":"COMPLETED","name":"deploy"}]},
  {"number":40,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"TIMED_OUT","status":"COMPLETED","name":"e2e"}]} ]
JSON

assert_eq "TIMED_OUT counts as failing; NEUTRAL/SKIPPED do not" "$(next_failing_checks_pr)" "40"

# --- claim_next_failing_pr: claiming marks the PR in-progress ---------------
set_fixture <<'JSON'
[ {"number":30,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"StatusContext","state":"ERROR","context":"ci/ext"}]},
  {"number":20,"mergeable":"MERGEABLE","labels":[],"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"FAILURE","status":"COMPLETED","name":"rust-tui"}]} ]
JSON
: >"$EDITS_FILE"

claim1="$(claim_next_failing_pr)"
assert_eq "claim returns lowest failing PR"                "$claim1" "20"
assert_eq "claim marks that PR in-progress under the lock" "$(cat "$EDITS_FILE")" "add:20:in-progress"

# --- anti-double-grab: a second claim never re-grabs the first PR -----------
claim2="$(claim_next_failing_pr)"
assert_eq "second claim skips the already-claimed PR" "$claim2" "30"

# Both failing PRs are now in-progress; a third claim finds nothing.
claim3="$(claim_next_failing_pr)"; claim3_rc=$?
assert_eq "third claim finds no unclaimed PR"     "$claim3" ""
assert_eq "third claim reports failure (rc != 0)" "$([ "$claim3_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

if [ "$fail" -eq 0 ]; then
  echo "All failing-checks-pr tests passed."
else
  echo "Some failing-checks-pr tests FAILED."
fi
exit "$fail"
