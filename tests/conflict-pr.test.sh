#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Unit tests for the conflicted-PR claiming helpers in copilot-loop.sh. On each
# iteration the loop looks for open PRs whose merge is CONFLICTING and hands one
# to Copilot to fix; to stop two instances grabbing the SAME PR it claims a PR by
# adding the "in-progress" label under the GitHub lock, and the selector skips any
# PR already carrying "in-progress" or "conflict-unresolved". These tests pin that
# label-based, anti-double-grab behaviour (issue #111).
#
# next_conflicted_pr and claim_next_conflicted_pr are extracted verbatim from the
# script between the "conflict-pr helpers" markers and run with `gh` mocked (the
# real jq selection filter is applied to a fixture), so the actual code is
# exercised without touching GitHub.
#
# Run: tests/conflict-pr.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

conflict_block="$(sed -n '/# >>> conflict-pr helpers >>>/,/# <<< conflict-pr helpers <<</p' "$script")"
[ -n "$conflict_block" ] || { echo "could not extract conflict-pr helpers (markers missing?)"; exit 1; }
eval "$conflict_block"

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

# Fixtures/edits live in files (not shell vars) so mutations survive the command
# substitution subshell that claim_next_conflicted_pr runs in.
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

# --- next_conflicted_pr: pure selection (no claim) --------------------------
# 8, 10 are conflicting and unclaimed; 12 is already in-progress; 14 already
# failed (conflict-unresolved); 16 is mergeable; 18's mergeability is unknown.
set_fixture <<'JSON'
[ {"number":16,"mergeable":"MERGEABLE","labels":[]},
  {"number":10,"mergeable":"CONFLICTING","labels":[]},
  {"number":8,"mergeable":"CONFLICTING","labels":[]},
  {"number":12,"mergeable":"CONFLICTING","labels":[{"name":"in-progress"}]},
  {"number":14,"mergeable":"CONFLICTING","labels":[{"name":"conflict-unresolved"}]},
  {"number":18,"mergeable":"UNKNOWN","labels":[]} ]
JSON

assert_eq "selects lowest-numbered unclaimed conflicting PR" "$(next_conflicted_pr)" "8"

# Only labelled/non-conflicting PRs left -> nothing to select.
set_fixture <<'JSON'
[ {"number":12,"mergeable":"CONFLICTING","labels":[{"name":"in-progress"}]},
  {"number":14,"mergeable":"CONFLICTING","labels":[{"name":"conflict-unresolved"}]},
  {"number":16,"mergeable":"MERGEABLE","labels":[]},
  {"number":18,"mergeable":"UNKNOWN","labels":[]} ]
JSON

assert_eq "skips in-progress / conflict-unresolved / non-conflicting" "$(next_conflicted_pr)" ""

# --- claim_next_conflicted_pr: claiming marks the PR in-progress ------------
set_fixture <<'JSON'
[ {"number":10,"mergeable":"CONFLICTING","labels":[]},
  {"number":8,"mergeable":"CONFLICTING","labels":[]} ]
JSON
: >"$EDITS_FILE"

claim1="$(claim_next_conflicted_pr)"
assert_eq "claim returns lowest conflicting PR"           "$claim1" "8"
assert_eq "claim marks that PR in-progress under the lock" "$(cat "$EDITS_FILE")" "add:8:in-progress"

# --- anti-double-grab: a second claim never re-grabs the first PR -----------
claim2="$(claim_next_conflicted_pr)"
assert_eq "second claim skips the already-claimed PR" "$claim2" "10"

# Both conflicting PRs are now in-progress; a third claim finds nothing.
claim3="$(claim_next_conflicted_pr)"; claim3_rc=$?
assert_eq "third claim finds no unclaimed PR"      "$claim3" ""
assert_eq "third claim reports failure (rc != 0)"  "$([ "$claim3_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

if [ "$fail" -eq 0 ]; then
  echo "All conflict-pr tests passed."
else
  echo "Some conflict-pr tests FAILED."
fi
exit "$fail"
