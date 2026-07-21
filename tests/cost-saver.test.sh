#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars are read by the resolve mirror under test
#
# Tests for the cost-saver preset in copilot-loop.sh (#186). --cost-saver /
# COST_SAVER=1 is a one-switch convenience over triage: it turns on smart model
# routing with built-in defaults so a user stops running one (often expensive)
# model on every issue. With only the preset set, a cheap model classifies each
# issue and the coding model tracks difficulty -- trivial runs on the cheap
# model, normal on a mid model, and complex escalates to the configured --model
# (or a strong default). An explicit --triage-model/--triage-map always overrides
# the preset, and any triage failure falls back to the default model so the
# preset never blocks a run.
#
# The real code is exercised by extracting the marked "cost-saver helpers" and
# "triage helpers" blocks and driving them -- no GitHub and no model are touched.
# resolve_triage() below mirrors, verbatim, the four config lines that compose
# the preset with the existing off-normalisation and empty-map default, so the
# end-to-end model a user actually gets is asserted, not just the pieces.
#
# Run: tests/cost-saver.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

for marker in "cost-saver helpers" "triage helpers"; do
  block="$(sed -n "/# >>> ${marker} >>>/,/# <<< ${marker} <<</p" "$script")"
  [ -n "$block" ] || { echo "could not extract '${marker}' (markers missing?)"; exit 1; }
  eval "$block"
done

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

# The exact model defaults a user gets from the preset alone. Kept in step with
# the constants inside the "cost-saver helpers" block.
CHEAP="gpt-5-mini"
MID="claude-sonnet-4.5"
STRONG="claude-opus-4.5"

# Mirror of the config block that resolves triage from the preset. Given the raw
# COST_SAVER / TRIAGE_MODEL / TRIAGE_MAP / COPILOT_MODEL a user supplies, echo the
# effective "model|map" the loop would run with, using the real extracted helpers
# and the same ordering as copilot-loop.sh (preset fill -> off-normalise ->
# empty-map default). Keep in step with the "Triage" config section.
resolve_triage() {
  local cost_saver="$1" tmodel="$2" tmap="$3" cmodel="$4"
  tmap="$(cost_saver_triage_map "$cost_saver" "$tmap" "$tmodel" "$cmodel")"
  tmodel="$(cost_saver_triage_model "$cost_saver" "$tmodel")"
  case "$tmodel" in off|none|0) tmodel="" ;; esac
  if [ -n "$tmodel" ] && [ -z "$tmap" ]; then
    tmap="trivial=${tmodel}"
  fi
  printf '%s|%s' "$tmodel" "$tmap"
}

# Route an issue difficulty class exactly as process_issue does: map the class,
# and fall back to the default coding model when the class has no mapping. This
# is the model a user observes running for an issue of that difficulty.
route() {
  local map="$1" class="$2" default_model="$3" mapped
  mapped="$(parse_triage_map "$map" "$class")"
  printf '%s' "${mapped:-$default_model}"
}

# ============================================================================
# cost_saver_enabled: truthy/falsy spellings
# ============================================================================
assert_eq "enabled: 1"            "$(cost_saver_enabled 1    && echo on || echo off)" "on"
assert_eq "enabled: true"         "$(cost_saver_enabled true && echo on || echo off)" "on"
assert_eq "enabled: yes"          "$(cost_saver_enabled yes  && echo on || echo off)" "on"
assert_eq "enabled: on"           "$(cost_saver_enabled on   && echo on || echo off)" "on"
assert_eq "disabled: 0"           "$(cost_saver_enabled 0    && echo on || echo off)" "off"
assert_eq "disabled: empty"       "$(cost_saver_enabled ''   && echo on || echo off)" "off"
assert_eq "disabled: off"         "$(cost_saver_enabled off  && echo on || echo off)" "off"
assert_eq "disabled: garbage"     "$(cost_saver_enabled xyz  && echo on || echo off)" "off"

# ============================================================================
# The headline user story: with ONLY the preset set, trivial runs cheap and
# complex escalates. Resolve the effective model+map, then route each class.
# ============================================================================
resolved="$(resolve_triage 1 '' '' '')"
eff_model="${resolved%%|*}"
eff_map="${resolved#*|}"
assert_eq "preset on: classifier is the cheap model"  "$eff_model" "$CHEAP"
assert_eq "preset on: trivial -> cheap model"  "$(route "$eff_map" trivial "$eff_model")" "$CHEAP"
assert_eq "preset on: normal  -> mid model"    "$(route "$eff_map" normal  "$eff_model")" "$MID"
assert_eq "preset on: complex -> strong model" "$(route "$eff_map" complex "$eff_model")" "$STRONG"

# With a coding --model set, complex escalates to THAT model (trivial/normal keep
# the cheap/mid defaults) so the user's chosen strong model is used for hard work.
resolved="$(resolve_triage 1 '' '' 'my-strong-model')"
eff_model="${resolved%%|*}"
eff_map="${resolved#*|}"
assert_eq "preset + --model: trivial still cheap"     "$(route "$eff_map" trivial "$eff_model")" "$CHEAP"
assert_eq "preset + --model: normal still mid"        "$(route "$eff_map" normal  "$eff_model")" "$MID"
assert_eq "preset + --model: complex -> that --model" "$(route "$eff_map" complex "$eff_model")" "my-strong-model"

# ============================================================================
# Off by default: without the preset nothing changes (triage stays off).
# ============================================================================
assert_eq "preset off: no triage model" "$(resolve_triage '' '' '' '')"          "|"
assert_eq "preset off: no triage model (0)" "$(resolve_triage 0 '' '' '')"       "|"

# ============================================================================
# Explicit --triage-model / --triage-map always override the preset.
# ============================================================================
# Explicit triage model + preset: the user's model classifies, and with no map
# the existing empty-map default (trivial=<model>) applies -- the preset does not
# invent its own map on top of an explicit model.
assert_eq "explicit triage-model wins over preset" \
  "$(resolve_triage 1 'my-cheap' '' '')" "my-cheap|trivial=my-cheap"

# Explicit map + preset: the user's map is used verbatim, not the preset default.
assert_eq "explicit triage-map wins over preset" \
  "$(resolve_triage 1 '' 'trivial=a,complex=b' '')" "$CHEAP|trivial=a,complex=b"

# Explicit model AND map + preset: both are the user's, preset touches neither.
assert_eq "explicit model+map win over preset" \
  "$(resolve_triage 1 'm' 'complex=z' '')" "m|complex=z"

# Explicitly turning triage off beats the preset: --triage-model off + preset
# leaves triage disabled (the preset never forces triage back on).
assert_eq "explicit off beats preset" "$(resolve_triage 1 off '' '')" "|"

# ============================================================================
# Preset helpers in isolation (the override guard is a plain emptiness check).
# ============================================================================
assert_eq "triage_model: preset off keeps current" "$(cost_saver_triage_model 0 '')" ""
assert_eq "triage_model: preset on fills cheap"     "$(cost_saver_triage_model 1 '')" "$CHEAP"
assert_eq "triage_model: preset on keeps explicit"  "$(cost_saver_triage_model 1 'x')" "x"
assert_eq "triage_map: preset off keeps current"    "$(cost_saver_triage_map 0 '' '' '')" ""
assert_eq "triage_map: preset on, no model"         "$(cost_saver_triage_map 1 '' '' '')" \
  "trivial=${CHEAP},normal=${MID},complex=${STRONG}"
assert_eq "triage_map: preset on, model set"        "$(cost_saver_triage_map 1 '' '' 'coder')" \
  "trivial=${CHEAP},normal=${MID},complex=coder"
assert_eq "triage_map: preset on keeps explicit"    "$(cost_saver_triage_map 1 'a=b' '' 'coder')" "a=b"
assert_eq "triage_map: explicit model skips preset map" "$(cost_saver_triage_map 1 '' 'mymodel' '')" ""

if [ "$fail" -eq 0 ]; then
  echo "PASS: cost-saver preset"
else
  echo "FAIL: cost-saver preset"
fi
exit "$fail"
