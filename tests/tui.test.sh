#!/usr/bin/env bash
#
# Unit tests for the pure helpers in copilot-loop-tui.sh. The functions under
# test are extracted verbatim from the script (between the "tui-pure helpers"
# markers) and sourced here, so the real code is exercised without spawning any
# process or touching the terminal.
#
# Run: tests/tui.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop-tui.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop-tui.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> tui-pure helpers >>>/,/# <<< tui-pure helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract tui-pure helpers (markers missing?)"; exit 1; }
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

# --- next_bot_id: next free id from a list ----------------------------------
assert_eq "empty -> 1"              "$(printf '' | next_bot_id)"                "1"
assert_eq "sequential -> max+1"     "$(printf '1\n2\n3\n' | next_bot_id)"       "4"
assert_eq "gaps -> max+1"           "$(printf '2\n5\n3\n' | next_bot_id)"       "6"
assert_eq "ignores non-numeric"     "$(printf '1\nfoo\n4\n' | next_bot_id)"     "5"
assert_eq "single -> next"          "$(printf '9\n' | next_bot_id)"             "10"

# --- tui_action_for_key: key -> action --------------------------------------
assert_eq "s spawns"                "$(tui_action_for_key s)"                   "spawn"
assert_eq "n spawns"                "$(tui_action_for_key n)"                   "spawn"
assert_eq "x stops"                 "$(tui_action_for_key x)"                   "stop"
assert_eq "d stops"                 "$(tui_action_for_key d)"                   "stop"
assert_eq "a stop-all"              "$(tui_action_for_key a)"                   "stop-all"
assert_eq "k is up"                 "$(tui_action_for_key k)"                   "up"
assert_eq "up token is up"          "$(tui_action_for_key up)"                  "up"
assert_eq "j is down"               "$(tui_action_for_key j)"                   "down"
assert_eq "down token is down"      "$(tui_action_for_key down)"                "down"
assert_eq "l opens log"             "$(tui_action_for_key l)"                   "log"
assert_eq "enter opens log"         "$(tui_action_for_key enter)"               "log"
assert_eq "c clears"                "$(tui_action_for_key c)"                   "clear"
assert_eq "r refreshes"             "$(tui_action_for_key r)"                   "refresh"
assert_eq "q quits"                 "$(tui_action_for_key q)"                   "quit"
assert_eq "? helps"                 "$(tui_action_for_key '?')"                 "help"
assert_eq "h helps"                 "$(tui_action_for_key h)"                   "help"
assert_eq "unknown -> none"         "$(tui_action_for_key z)"                   "none"

# --- clamp_selection: keep index in range -----------------------------------
assert_eq "empty list pins 0"       "$(clamp_selection 0 0)"                    "0"
assert_eq "empty list pins 0 (hi)"  "$(clamp_selection 5 0)"                    "0"
assert_eq "over max clamps"         "$(clamp_selection 5 3)"                    "2"
assert_eq "under min clamps"        "$(clamp_selection -1 3)"                   "0"
assert_eq "in range unchanged"      "$(clamp_selection 1 3)"                    "1"

# --- fmt_uptime: compact durations ------------------------------------------
assert_eq "seconds"                 "$(fmt_uptime 5)"                           "5s"
assert_eq "minutes"                 "$(fmt_uptime 65)"                          "1m05s"
assert_eq "hours"                   "$(fmt_uptime 3725)"                        "1h02m"
assert_eq "zero"                    "$(fmt_uptime 0)"                           "0s"
assert_eq "non-numeric -> dash"     "$(fmt_uptime x)"                           "—"
assert_eq "empty -> dash"           "$(fmt_uptime '')"                          "—"

# --- sanitize_line: strip escapes/control chars -----------------------------
assert_eq "strips SGR colour"       "$(sanitize_line "$(printf '\033[0;32mHELLO\033[0m')")" "HELLO"
assert_eq "strips carriage return"  "$(sanitize_line "$(printf 'abc\rdef')")"   "abcdef"
assert_eq "tab becomes space"       "$(sanitize_line "$(printf 'a\tb')")"       "a b"
assert_eq "plain text untouched"    "$(sanitize_line 'just text')"              "just text"

# --- truncate_display: fit to width -----------------------------------------
assert_eq "fits unchanged"          "$(truncate_display 'abc' 10)"              "abc"
assert_eq "exact width unchanged"   "$(truncate_display 'abcde' 5)"             "abcde"
assert_eq "truncates with ellipsis" "$(truncate_display 'abcdef' 3)"           "ab…"
assert_eq "zero width empty"        "$(truncate_display 'abc' 0)"               ""

# --- render_header / fmt_bot_line: exact rendered strings -------------------
assert_eq "header text" \
  "$(render_header 2 3 'owner/repo')" \
  "Running bots: 2    Total tracked: 3    Repo: owner/repo"
assert_eq "bot line, selected" \
  "$(fmt_bot_line 1 1 12345 running 3m12s 'working #50')" \
  "> #1   pid 12345   running  3m12s   | working #50"
assert_eq "bot line, unselected" \
  "$(fmt_bot_line 0 2 '----' stopped 5s '(exited)')" \
  "  #2   pid ----    stopped  5s      | (exited)"

if [ "$fail" -eq 0 ]; then
  echo "All tui tests passed."
else
  echo "Some tui tests FAILED."
fi
exit "$fail"
