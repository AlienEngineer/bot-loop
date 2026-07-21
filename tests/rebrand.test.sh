#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034,SC2329  # mocks/config are invoked and read indirectly by the extracted code under test
#
# Tests for issue #228: every user-facing reference to the autonomous agent is a
# "bot" and the tool is "bot-loop". The underlying `copilot` CLI we actually
# execute is deliberately left unchanged. These assert the outcomes a user
# observes -- the CLI's --version/--help text and the exact GitHub comment
# bodies the loop posts on an issue -- not internal identifiers.
#
# Run: tests/rebrand.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n       %s\n' "$1" "$2"; fail=1; }
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in *"$needle"*) ok "$desc" ;; *) bad "$desc" "missing: [$needle]" ;; esac
}
assert_absent() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in *"$needle"*) bad "$desc" "unexpected: [$needle]" ;; *) ok "$desc" ;; esac
}

# ============================================================================
# 1. `--version` reports the bot-loop brand, not copilot-loop.
# ============================================================================
ver="$(bash "$script" --version 2>/dev/null)"
assert_contains "version: names bot-loop"       "$ver" "bot-loop "
assert_absent   "version: drops copilot-loop"   "$ver" "copilot-loop"

# ============================================================================
# 2. `--help` calls the agent "the bot" and the tool "bot-loop".
# ============================================================================
help="$(bash "$script" --help 2>/dev/null)"
assert_contains "help: prints the bot-loop version" "$help" "Print the bot-loop version"
assert_contains "help: each bot run"                "$help" "each bot run"
assert_contains "help: the bot's output"            "$help" "the bot's output"
assert_contains "help: ask the bot to add tests"    "$help" "Ask the bot to add tests"
# The underlying CLI we execute is still named once, as the Copilot CLI product.
assert_contains "help: still names the Copilot CLI" "$help" "Copilot CLI"
# ...but the agent itself is never called Copilot, nor the tool copilot-loop.
assert_absent   "help: no 'Copilot run'"            "$help" "Copilot run"
assert_absent   "help: no 'Ask Copilot'"            "$help" "Ask Copilot"
assert_absent   "help: no \"Copilot's output\""     "$help" "Copilot's output"
assert_absent   "help: no 'copilot-loop version'"   "$help" "copilot-loop version"

# ============================================================================
# GitHub comment harness: capture the exact --body the loop would post so we
# assert the wording a user reads on the issue, driving the REAL functions.
# ============================================================================
GH_LOG="$(mktemp)"
QDIR="$(mktemp -d)"
trap 'rm -f "$GH_LOG"; rm -rf "$QDIR"' EXIT

log() { :; }
cleanup_workspace() { :; }
# Record the posted comment body exactly as GitHub would receive it. The real
# calls redirect their own stdout/stderr to /dev/null, so writing to a file here
# (not stdout) keeps the body observable.
gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "issue comment" | "pr comment")
      shift # the issue/PR number
      local body=""
      while [ $# -gt 0 ]; do case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac; done
      printf '%s\n' "$body" >"$GH_LOG"
      ;;
    *) : ;;
  esac
}

# Config the extracted functions read.
QUESTION_MARKER="<!-- copilot-loop:needs-info -->"
FAILURE_MARKER="<!-- copilot-loop:failed -->"
NEEDS_INFO_LABEL="needs-info"
INPROGRESS_LABEL="in-progress"
FAILED_LABEL="copilot-failed"
branch="copilot/7-demo"

# Pull in the REAL functions under test straight from the script.
eval "$(sed -n '/# >>> needs-info helpers >>>/,/# <<< needs-info helpers <<</p' "$script")"
eval "$(sed -n '/^_fail_issue() {/,/^}/p' "$script")"

# --- 3. The needs-info question comment is branded bot-loop ------------------
qf="$QDIR/issue-7.question"
printf 'Which database should store sessions?\n' >"$qf"
_ask_issue 7 "$qf"
ask_body="$(cat "$GH_LOG")"
assert_contains "needs-info: bot-loop heading" \
  "$ask_body" "**bot-loop needs more information to continue:**"
assert_contains "needs-info: keeps the question" \
  "$ask_body" "Which database should store sessions?"
# The hidden marker keeps its stable id, so ignore it when checking the prose.
assert_absent "needs-info: no copilot-loop brand in prose" \
  "${ask_body%%<!--*}" "copilot-loop"

# --- 4. The failure comment is branded bot-loop -----------------------------
_fail_issue 7 /dev/null "the build broke" "cargo test: 1 failed"
fail_body="$(cat "$GH_LOG")"
assert_contains "failure: bot-loop prefix"    "$fail_body" "bot-loop failed:"
assert_contains "failure: keeps the reason"   "$fail_body" "the build broke"
assert_absent   "failure: no copilot-loop brand in prose" \
  "${fail_body%%<!--*}" "copilot-loop"

if [ "$fail" -eq 0 ]; then
  echo "All rebrand tests passed."
else
  echo "Some rebrand tests FAILED."
fi
exit "$fail"
