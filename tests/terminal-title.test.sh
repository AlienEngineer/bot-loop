#!/usr/bin/env bash
#
# Unit tests for the terminal-title helpers in copilot-loop.sh. The functions
# under test are extracted verbatim from the script (between the
# "terminal-title helpers" markers) and sourced here, with `tmux` mocked, so the
# real code is exercised without touching any terminal.
#
# Run: tests/terminal-title.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> terminal-title helpers >>>/,/# <<< terminal-title helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract terminal-title helpers (markers missing?)"; exit 1; }
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

# --- terminal_title_seq: pure OSC escape generation -------------------------
assert_eq "osc wraps title"        "$(terminal_title_seq 'copilot/44-foo')" "$(printf '\033]0;copilot/44-foo\007')"
assert_eq "osc with slashes"       "$(terminal_title_seq 'a/b/c')"          "$(printf '\033]0;a/b/c\007')"
assert_eq "osc empty title"        "$(terminal_title_seq '')"               "$(printf '\033]0;\007')"

# --- set_terminal_title: tmux path renames the current window ---------------
# Mock tmux so `rename-window` records its argument instead of touching tmux.
rename_log=""
# shellcheck disable=SC2329  # invoked indirectly by set_terminal_title
tmux() {
  if [ "$1" = "rename-window" ]; then
    rename_log="$2"
  fi
}

TMUX="/tmp/fake-tmux,1,0" set_terminal_title "copilot/44-foo"
assert_eq "tmux renames window"    "$rename_log"                            "copilot/44-foo"

rename_log=""
TMUX="/tmp/fake-tmux,1,0" set_terminal_title "copilot/7-bar"
assert_eq "tmux uses given branch" "$rename_log"                            "copilot/7-bar"

# --- set_terminal_title: no tmux, no TTY -> no output, no failure -----------
# Inside command substitution stdout is a pipe (not a TTY), so the OSC path is
# skipped and nothing is emitted.
unset -f tmux
out="$(unset TMUX; set_terminal_title 'copilot/9-baz')"
assert_eq "no tty emits nothing"   "$out"                                   ""

if [ "$fail" -eq 0 ]; then
  echo "All terminal-title tests passed."
else
  echo "Some terminal-title tests FAILED."
fi
exit "$fail"
