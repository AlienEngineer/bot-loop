#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Unit tests for the model tag filtering logic in copilot-loop.sh. Issues can have
# optional model tags (e.g., "model:gpt-5.4") and bots filter issues based on their
# configured model. The pure decision (should_pick_issue_by_model) is tested with
# various combinations of bot models and issue model tags.
#
# Run: tests/model-tag-filtering.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

# Extract the helper functions from the script
helpers="$(sed -n '/^should_pick_issue_by_model() {/,/^}/p' "$script")"
[ -n "$helpers" ] || { echo "could not extract should_pick_issue_by_model"; exit 1; }
eval "$helpers"

fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  local rc=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"
    fail=1
  fi
}

assert_true() {
  local desc="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected true, got false)\n' "$desc"
    fail=1
  fi
}

assert_false() {
  local desc="$1" cmd="$2"
  if ! eval "$cmd"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected false, got true)\n' "$desc"
    fail=1
  fi
}

# --- should_pick_issue_by_model: pure decision table ---------------------
# The logic is:
# - Auto bot (empty or "auto" model) picks:
#   - Issues with no model tag
#   - Issues with model:auto tag
# - Specific bot (e.g., "gpt-5.4") picks:
#   - ONLY issues with matching model tag (e.g., model:gpt-5.4)
#   - NOT untagged issues
#   - NOT mismatched tags

echo "=== Auto bot (no model specified) ==="
assert_true "auto bot picks untagged issue"           "should_pick_issue_by_model '' ''"
assert_true "auto bot picks model:auto tagged issue"  "should_pick_issue_by_model '' 'auto'"
assert_false "auto bot skips model:gpt-5.4 issue"     "should_pick_issue_by_model '' 'gpt-5.4'"
assert_false "auto bot skips model:claude issue"      "should_pick_issue_by_model '' 'claude-opus-4.5'"

echo ""
echo "=== Auto bot (explicit 'auto' model) ==="
assert_true "auto bot picks untagged issue"           "should_pick_issue_by_model 'auto' ''"
assert_true "auto bot picks model:auto tagged issue"  "should_pick_issue_by_model 'auto' 'auto'"
assert_false "auto bot skips model:gpt-5.4 issue"     "should_pick_issue_by_model 'auto' 'gpt-5.4'"
assert_false "auto bot skips model:claude issue"      "should_pick_issue_by_model 'auto' 'claude-opus-4.5'"

echo ""
echo "=== Specific bot (gpt-5.4) ==="
assert_false "gpt-5.4 bot skips untagged issue"       "should_pick_issue_by_model 'gpt-5.4' ''"
assert_false "gpt-5.4 bot skips model:auto issue"     "should_pick_issue_by_model 'gpt-5.4' 'auto'"
assert_true "gpt-5.4 bot picks model:gpt-5.4 issue"   "should_pick_issue_by_model 'gpt-5.4' 'gpt-5.4'"
assert_false "gpt-5.4 bot skips model:gpt-5.5 issue"  "should_pick_issue_by_model 'gpt-5.4' 'gpt-5.5'"
assert_false "gpt-5.4 bot skips model:claude issue"   "should_pick_issue_by_model 'gpt-5.4' 'claude-opus-4.5'"

echo ""
echo "=== Specific bot (claude-opus-4.5) ==="
assert_false "claude bot skips untagged issue"        "should_pick_issue_by_model 'claude-opus-4.5' ''"
assert_false "claude bot skips model:auto issue"      "should_pick_issue_by_model 'claude-opus-4.5' 'auto'"
assert_false "claude bot skips model:gpt-5.4 issue"   "should_pick_issue_by_model 'claude-opus-4.5' 'gpt-5.4'"
assert_true "claude bot picks model:claude issue"     "should_pick_issue_by_model 'claude-opus-4.5' 'claude-opus-4.5'"

if [ "$fail" -eq 0 ]; then
  echo ""
  echo "All model-tag-filtering tests passed."
else
  echo ""
  echo "Some model-tag-filtering tests FAILED."
fi
exit "$fail"
