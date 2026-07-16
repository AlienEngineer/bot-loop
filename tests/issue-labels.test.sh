#!/usr/bin/env bash
#
# Unit tests for the "Label:" issue-file directive helper in copilot-loop.sh.
# The function under test is extracted verbatim from the script (between the
# "issue-label helpers" markers) and sourced here so the real code is exercised
# without touching GitHub.
#
# Run: tests/issue-labels.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> issue-label helpers >>>/,/# <<< issue-label helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract issue-label helpers (markers missing?)"; exit 1; }
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

# --- No directive: fall back to the default (trigger) label ------------------
assert_eq "no directive -> default"   "$(issue_labels 'just a task' 'ready')"            "ready"
assert_eq "empty body -> default"     "$(issue_labels '' 'ready')"                       "ready"
assert_eq "word label, no colon"      "$(issue_labels 'we should label this' 'ready')"   "ready"

# --- "no label" sentinels: echo nothing --------------------------------------
assert_eq "none -> no label"          "$(issue_labels 'Label: none' 'ready')"            ""
assert_eq "empty value -> no label"   "$(issue_labels 'Label:' 'ready')"                 ""
assert_eq "no-label -> no label"      "$(issue_labels 'Label: no-label' 'ready')"        ""
assert_eq "nolabel -> no label"       "$(issue_labels 'Labels: nolabel' 'ready')"        ""
assert_eq "dash -> no label"          "$(issue_labels 'Label: -' 'ready')"               ""
assert_eq "NONE upper -> no label"    "$(issue_labels 'LABEL: NONE' 'ready')"            ""

# --- Explicit labels: echoed verbatim (names are case-sensitive) -------------
assert_eq "single label"              "$(issue_labels 'Label: bug' 'ready')"             "bug"
assert_eq "preserves case"            "$(issue_labels 'Label: Bug' 'ready')"             "Bug"
assert_eq "plural key + list"         "$(issue_labels 'Labels: bug, enhancement' 'x')"   "bug, enhancement"
assert_eq "case-insensitive key"      "$(issue_labels 'LABEL: bug' 'ready')"             "bug"
assert_eq "trims surrounding space"   "$(issue_labels '   label:   bug  ' 'ready')"      "bug"

# --- First matching line wins; other lines ignored ---------------------------
assert_eq "picks directive line"      "$(issue_labels $'# Title\n\nsome text\nLabel: bug\nmore' 'ready')" "bug"
assert_eq "first of two wins"         "$(issue_labels $'Label: bug\nLabel: none' 'ready')" "bug"

if [ "$fail" -eq 0 ]; then
  echo "All issue-label tests passed."
else
  echo "Some issue-label tests FAILED."
fi
exit "$fail"
