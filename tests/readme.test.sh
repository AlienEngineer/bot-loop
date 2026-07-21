#!/usr/bin/env bash
#
# Tests for README.md (issue #225). The README was rewritten to contain exactly
# three things a user needs and nothing else:
#   1. Getting started — how to install via Homebrew.
#   2. A brief description of what the loop does on each iteration.
#   3. A description of every flag the bash script accepts.
#
# These are user-perspective checks: they assert the outcomes a reader observes
# in the published README (the install commands, the loop walkthrough, and that
# every flag the script actually accepts is documented), not any internal
# implementation detail. The flag list is derived from the script's real
# `--help` output so the README can never silently drift from the flags a user
# can pass.
#
# Run: tests/readme.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
readme="$here/../README.md"
script="$here/../copilot-loop.sh"

[ -f "$readme" ] || { echo "cannot find README.md next to tests/"; exit 1; }
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

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

# has <needle>: "yes" when the fixed string appears anywhere in the README.
has() {
  if grep -qF -- "$1" "$readme"; then echo yes; else echo no; fi
}

# --- 1. Getting started: install via Homebrew --------------------------------
assert_eq "has a Getting started section" \
  "$(grep -ciE '^##[[:space:]]+getting started' "$readme")" "1"
assert_eq "documents the Homebrew tap"        "$(has 'brew tap alienengineer/bot-loop')" "yes"
assert_eq "documents the Homebrew install"    "$(has 'brew install bot-loop')" "yes"
assert_eq "mentions copilot must be installed separately" "$(has 'copilot')" "yes"
assert_eq "shows how to run the loop"         "$(has 'bot-loop-bash')" "yes"

# --- 2. Describes what the loop does each iteration ---------------------------
assert_eq "has a How the loop works section" \
  "$(grep -ciE '^##[[:space:]]+how the loop works' "$readme")" "1"
# A few representative steps of a single pass so the section actually walks the
# iteration, from picking up an issue to opening a PR.
assert_eq "iteration: reads issues/ markdown" "$(has 'issues/')" "yes"
assert_eq "iteration: picks the ready issue"  "$(has 'ready')" "yes"
assert_eq "iteration: runs Copilot"           "$(has 'Copilot')" "yes"
assert_eq "iteration: opens a PR"             "$(has 'PR')" "yes"
assert_eq "iteration: sleeps when idle"       "$(has 'sleep')" "yes"

# --- 3. Documents every flag the bash script accepts -------------------------
assert_eq "has a Flags section" \
  "$(grep -ciE '^##[[:space:]]+flags' "$readme")" "1"

# The authoritative flag list is whatever `--help` prints. `--flag` appears there
# only as a placeholder in the "--flag value / --flag=value" explanation, so it is
# excluded. Every remaining long flag must be documented in the README.
undocumented=""
for flag in $(bash "$script" --help 2>/dev/null \
                | grep -oE -- '--[a-z][a-z-]+' | sort -u \
                | grep -vxF -- '--flag'); do
  grep -qF -- "$flag" "$readme" || undocumented="$undocumented $flag"
done
assert_eq "every --help flag is documented in the README" "${undocumented:-none}" "none"

# The short flags and the plan-mode flag (which had been missing from the table)
# are documented too.
assert_eq "documents -h/--help"    "$(has '-h')" "yes"
assert_eq "documents -V/--version" "$(has '-V')" "yes"
assert_eq "documents --plan-label" "$(has '--plan-label')" "yes"

# The flags table pairs each flag with its environment variable, so the env-var
# names other tests rely on are surfaced to the reader.
assert_eq "surfaces AGENTS_MODEL env var"        "$(has 'AGENTS_MODEL')" "yes"
assert_eq "surfaces TRIAGE_TIMEOUT_MAP env var"  "$(has 'TRIAGE_TIMEOUT_MAP')" "yes"

# --- "Nothing else": exactly the three requested sections --------------------
assert_eq "has exactly three top-level sections" \
  "$(grep -cE '^## ' "$readme")" "3"

if [ "$fail" -eq 0 ]; then
  echo "All README tests passed."
else
  echo "Some README tests FAILED."
fi
exit "$fail"
