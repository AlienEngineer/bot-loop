#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Unit tests for plan mode in copilot-loop.sh (#172). An issue labelled with the
# plan label is drafted into an implementation plan (no code changes) that is
# posted for review; the user then adds the trigger label to run it. Two pieces
# of real logic are exercised here, extracted verbatim from the script between
# their markers so the actual code runs without touching GitHub or any model:
#   - comments_have_plan: detects the posted-plan marker in an issue's thread, so
#     the execution pass knows to follow the approved plan.
#   - claim_next_plan_issue: atomically selects and claims the oldest plan-labelled
#     issue, skipping any blocked by an open dependency (like the ready queue).
#
# Run: tests/plan-mode.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

# claim_next_plan_issue depends on the wait-for helpers (issue_open_blockers),
# so pull those in too. All three blocks are extracted verbatim from the script.
wait_block="$(sed -n '/# >>> wait-for helpers >>>/,/# <<< wait-for helpers <<</p' "$script")"
[ -n "$wait_block" ] || { echo "could not extract wait-for helpers (markers missing?)"; exit 1; }
detect_block="$(sed -n '/# >>> plan-detect helpers >>>/,/# <<< plan-detect helpers <<</p' "$script")"
[ -n "$detect_block" ] || { echo "could not extract plan-detect helpers (markers missing?)"; exit 1; }
claim_block="$(sed -n '/# >>> plan-issue helpers >>>/,/# <<< plan-issue helpers <<</p' "$script")"
[ -n "$claim_block" ] || { echo "could not extract plan-issue helpers (markers missing?)"; exit 1; }
eval "$wait_block"
eval "$detect_block"
eval "$claim_block"

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

# --- comments_have_plan: detects the posted-plan marker ----------------------
plan_marker="<!-- copilot-loop:plan -->"
yes_if() { if comments_have_plan "$1"; then echo yes; else echo no; fi; }

assert_eq "marker present -> yes"        "$(yes_if "some plan text $plan_marker more")" "yes"
assert_eq "marker on its own line -> yes" "$(yes_if $'a comment\n'"$plan_marker")"       "yes"
assert_eq "no marker -> no"              "$(yes_if 'just a normal conversation')"       "no"
assert_eq "empty thread -> no"           "$(yes_if '')"                                 "no"

# --- Config the extracted claim helper reads from the environment ------------
# shellcheck disable=SC2034  # consumed by the eval'd helper, invisible to shellcheck
PLAN_LABEL="plan"
# shellcheck disable=SC2034
INPROGRESS_LABEL="in-progress"
# shellcheck disable=SC2034
PENDING_LABEL="pending"

# Silence logs, make the lock a no-op, and format blockers plainly so the real
# selection and claim logic runs unchanged.
# shellcheck disable=SC2329  # invoked indirectly by the extracted helper
log() { :; }
# shellcheck disable=SC2329
acquire_github_lock() { return 0; }
# shellcheck disable=SC2329
release_github_lock() { :; }
# shellcheck disable=SC2329
_fmt_blockers() { printf '%s' "$1"; }

# Fixtures/edits live in files (not shell vars) so mutations survive the command
# substitution subshell that claim_next_plan_issue runs in.
ISSUES_FILE="$(mktemp)"
EDITS_FILE="$(mktemp)"
: >"$EDITS_FILE"
trap 'rm -f "$ISSUES_FILE" "$EDITS_FILE"' EXIT

set_fixture() { cat >"$ISSUES_FILE"; }
# Flip a dependency issue's state so the blocker gate can be exercised.
set_state() {
  local n="$1" state="$2" tmp; tmp="$(mktemp)"
  jq --arg n "$n" --arg s "$state" \
    'map(if (.number|tostring)==$n then (.state=$s) else . end)' "$ISSUES_FILE" >"$tmp" \
    && mv "$tmp" "$ISSUES_FILE"
}

# Mock gh: `issue list` emulates GitHub's server-side --state/--label filtering,
# then applies the REAL --jq filter the helper built (the NUL-joined number/body
# stream); `issue view` answers the dependency's state; `issue edit` records the
# label change and mutates the fixture so a claimed issue drops out of the next
# selection (this is what makes the anti-double-grab behaviour testable).
# shellcheck disable=SC2329  # invoked indirectly by the extracted helper
gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "issue list")
      local label="" jqf=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) label="$2"; shift 2 ;;
          --jq)    jqf="$2";   shift 2 ;;
          *) shift ;;
        esac
      done
      jq --arg L "$label" \
        '[ .[] | select(.state=="OPEN") | select(any(.labels[]?; .name==$L)) ]' "$ISSUES_FILE" \
        | jq -r "$jqf"
      ;;
    "issue view")
      local n="$1"
      jq -r --arg n "$n" '.[] | select((.number|tostring)==$n) | .state // ""' "$ISSUES_FILE"
      ;;
    "issue edit")
      local n="$1"; shift
      local action="" label=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    action="add";    label="$2"; shift 2 ;;
          --remove-label) action="remove"; label="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      printf '%s:%s:%s\n' "$action" "$n" "$label" >>"$EDITS_FILE"
      local tmp; tmp="$(mktemp)"
      if [ "$action" = "add" ]; then
        jq --arg n "$n" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels += [{"name":$l}]) else . end)' \
          "$ISSUES_FILE" >"$tmp" && mv "$tmp" "$ISSUES_FILE"
      else
        jq --arg n "$n" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels |= map(select(.name != $l))) else . end)' \
          "$ISSUES_FILE" >"$tmp" && mv "$tmp" "$ISSUES_FILE"
      fi
      ;;
  esac
}

# Fixture: #3 is blocked by the still-open #9; #5 and #7 are ready to plan; #9 is
# the (unlabelled) dependency.
set_fixture <<'JSON'
[ {"number":3,"body":"Wait for: #9","labels":[{"name":"plan"}],"state":"OPEN"},
  {"number":5,"body":"add a feature","labels":[{"name":"plan"}],"state":"OPEN"},
  {"number":7,"body":"another feature","labels":[{"name":"plan"}],"state":"OPEN"},
  {"number":9,"body":"the dependency","labels":[],"state":"OPEN"} ]
JSON

# Records are newline-separated in the file; join to spaces for a compact compare.
edits() { tr '\n' ' ' <"$EDITS_FILE" | sed 's/ *$//'; }

# --- claim_next_plan_issue: oldest unblocked issue is claimed ----------------
claim1="$(claim_next_plan_issue)"
assert_eq "claims oldest unblocked plan issue (skips blocked #3)" "$claim1" "5"
assert_eq "claim marks it in-progress and drops plan+pending" \
  "$(edits)" "add:5:in-progress remove:5:plan remove:5:pending"

# --- anti-double-grab: the next claim never re-grabs the claimed issue -------
: >"$EDITS_FILE"
claim2="$(claim_next_plan_issue)"
assert_eq "second claim moves on to the next ready plan issue" "$claim2" "7"

# Only the dependency-blocked #3 still carries the plan label -> nothing to claim.
: >"$EDITS_FILE"
claim3="$(claim_next_plan_issue)"; claim3_rc=$?
assert_eq "no unblocked plan issue left -> empty"        "$claim3" ""
assert_eq "empty claim reports failure (rc != 0)" \
  "$([ "$claim3_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
assert_eq "blocked issue is not touched (no edits)"      "$(edits)" ""

# --- once the dependency closes, the blocked issue becomes claimable ---------
set_state 9 CLOSED
: >"$EDITS_FILE"
claim4="$(claim_next_plan_issue)"
assert_eq "closing the dependency unblocks #3" "$claim4" "3"

if [ "$fail" -eq 0 ]; then
  echo "All plan-mode tests passed."
else
  echo "Some plan-mode tests FAILED."
fi
exit "$fail"
