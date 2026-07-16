#!/usr/bin/env bash
#
# Unit tests for the triage helpers in copilot-loop.sh: normalize_triage_class
# (canonicalise a model's difficulty answer) and parse_triage_map (look up the
# coding model for a class in the TRIAGE_MAP string). The functions under test
# are extracted verbatim from the script (between the "triage helpers" markers)
# and sourced here so the real code is exercised without touching GitHub or any
# model.
#
# Run: tests/triage.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> triage helpers >>>/,/# <<< triage helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract triage helpers (markers missing?)"; exit 1; }
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

# --- normalize_triage_class: canonical words ---------------------------------
assert_eq "trivial verbatim"        "$(normalize_triage_class 'trivial')"      "trivial"
assert_eq "normal verbatim"         "$(normalize_triage_class 'normal')"       "normal"
assert_eq "complex verbatim"        "$(normalize_triage_class 'complex')"      "complex"

# --- normalize_triage_class: case, punctuation, surrounding text -------------
assert_eq "uppercase"               "$(normalize_triage_class 'TRIVIAL')"      "trivial"
assert_eq "trailing period"         "$(normalize_triage_class 'Complex.')"     "complex"
assert_eq "leading/trailing space"  "$(normalize_triage_class '  normal  ')"   "normal"
assert_eq "embedded in sentence"    "$(normalize_triage_class 'This is a complex change')" "complex"
assert_eq "multiline answer"        "$(normalize_triage_class $'I think:\nnormal')"        "normal"
assert_eq "first keyword wins"      "$(normalize_triage_class 'trivial not complex')"      "trivial"

# --- normalize_triage_class: synonyms ----------------------------------------
assert_eq "simple -> trivial"       "$(normalize_triage_class 'simple')"       "trivial"
assert_eq "easy -> trivial"         "$(normalize_triage_class 'easy')"         "trivial"
assert_eq "hard -> complex"         "$(normalize_triage_class 'hard')"         "complex"
assert_eq "difficult -> complex"    "$(normalize_triage_class 'difficult')"    "complex"
assert_eq "complicated -> complex"  "$(normalize_triage_class 'complicated')"  "complex"
assert_eq "medium -> normal"        "$(normalize_triage_class 'medium')"       "normal"
assert_eq "moderate -> normal"      "$(normalize_triage_class 'moderate')"     "normal"

# --- normalize_triage_class: unknown / empty ---------------------------------
assert_eq "empty -> nothing"        "$(normalize_triage_class '')"             ""
assert_eq "unknown -> nothing"      "$(normalize_triage_class 'banana')"       ""

# --- parse_triage_map: basic lookups -----------------------------------------
map='trivial=gpt-5-mini,complex=o1'
assert_eq "map trivial"             "$(parse_triage_map "$map" 'trivial')"     "gpt-5-mini"
assert_eq "map complex"             "$(parse_triage_map "$map" 'complex')"     "o1"
assert_eq "map absent class"        "$(parse_triage_map "$map" 'normal')"      ""

# --- parse_triage_map: whitespace and case -----------------------------------
assert_eq "trims spaces"            "$(parse_triage_map 'trivial = a , normal = b' 'normal')" "b"
assert_eq "case-insensitive class"  "$(parse_triage_map 'trivial=a' 'TRIVIAL')" "a"
assert_eq "case-insensitive key"    "$(parse_triage_map 'Trivial=a' 'trivial')" "a"

# --- parse_triage_map: empty values, empty map, malformed pairs --------------
assert_eq "empty value -> nothing"  "$(parse_triage_map 'trivial=' 'trivial')"  ""
assert_eq "empty map -> nothing"    "$(parse_triage_map '' 'trivial')"          ""
assert_eq "pair without = skipped"  "$(parse_triage_map 'trivialfoo,complex=o1' 'complex')" "o1"
assert_eq "first entry wins"        "$(parse_triage_map 'trivial=a,trivial=b' 'trivial')"   "a"

# --- parse_triage_map: model ids with dots/hyphens preserved -----------------
assert_eq "preserves model id"      "$(parse_triage_map 'complex=claude-opus-4.5' 'complex')" "claude-opus-4.5"

if [ "$fail" -eq 0 ]; then
  echo "All triage tests passed."
else
  echo "Some triage tests FAILED."
fi
exit "$fail"
