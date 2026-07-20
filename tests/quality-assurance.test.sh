#!/usr/bin/env bash
#
# Unit tests for the quality-assurance helpers in copilot-loop.sh: qa_enabled
# (normalise a raw config value to on/off, defaulting on) and qa_instruction
# (the QA instruction paragraph appended to the issue prompt). The functions
# under test are extracted verbatim from the script (between the
# "quality-assurance helpers" markers) and sourced here, so the real code is
# exercised without touching GitHub or any model.
#
# Run: tests/quality-assurance.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> quality-assurance helpers >>>/,/# <<< quality-assurance helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract quality-assurance helpers (markers missing?)"; exit 1; }
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *) printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$haystack" "$needle"; fail=1 ;;
  esac
}

# --- qa_enabled: on by default -----------------------------------------------
assert_eq "empty -> on (default)"   "$(qa_enabled '')"          "1"

# --- qa_enabled: explicit truthy spellings stay on ---------------------------
assert_eq "1 -> on"                 "$(qa_enabled '1')"         "1"
assert_eq "true -> on"              "$(qa_enabled 'true')"      "1"
assert_eq "yes -> on"              "$(qa_enabled 'yes')"        "1"
assert_eq "on -> on"                "$(qa_enabled 'on')"        "1"
assert_eq "garbage -> on"           "$(qa_enabled 'banana')"    "1"

# --- qa_enabled: explicit falsy spellings turn it off ------------------------
assert_eq "0 -> off"                "$(qa_enabled '0')"         "0"
assert_eq "false -> off"            "$(qa_enabled 'false')"     "0"
assert_eq "no -> off"               "$(qa_enabled 'no')"        "0"
assert_eq "off -> off"              "$(qa_enabled 'off')"       "0"
assert_eq "disable -> off"          "$(qa_enabled 'disable')"   "0"
assert_eq "disabled -> off"         "$(qa_enabled 'disabled')"  "0"

# --- qa_instruction: enabled emits the user-perspective instruction ----------
enabled="$(qa_instruction 1)"
assert_contains "enabled mentions quality assurance" "$enabled" "Quality assurance:"
assert_contains "enabled asks to add tests"          "$enabled" "add automated tests"
assert_contains "enabled asks for user perspective"  "$enabled" "perspective of the user"
assert_contains "enabled allows technical fallback"  "$enabled" "technical/unit tests"

# Default argument is treated as enabled so a bare call still returns the text.
assert_eq "default arg matches enabled" "$(qa_instruction)" "$enabled"

# --- qa_instruction: disabled emits nothing ----------------------------------
assert_eq "disabled -> empty"       "$(qa_instruction 0)"       ""

if [ "$fail" -eq 0 ]; then
  echo "All quality-assurance tests passed."
else
  echo "Some quality-assurance tests FAILED."
fi
exit "$fail"
