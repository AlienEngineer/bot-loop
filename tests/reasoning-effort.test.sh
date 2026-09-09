#!/usr/bin/env bash
#
# Tests for --effort / COPILOT_EFFORT in copilot-loop.sh. Copilot does not
# persist the effort picked in an interactive session, so a coding run reasons at
# the model's default unless the loop passes --effort. Checks what a user
# observes: the flag is accepted, and every copilot run that carries the coding
# model carries the effort with it.
#
# Run: tests/reasoning-effort.test.sh
# shellcheck disable=SC2016  # assertions intentionally match literal shell source
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

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

# The flag and its alias are accepted, in both "--effort max" and "--effort=max"
# spellings, and land in COPILOT_EFFORT.
for spelling in '--effort|--reasoning-effort)' '--effort=*)' '--reasoning-effort=*)'; do
  assert_eq "arg parser accepts ${spelling%)}" \
    "$(grep -cF -- "$spelling" "$script")" \
    "1"
done

# The default is empty, so an unset effort leaves each model on its own default.
assert_eq "COPILOT_EFFORT defaults to empty" \
  "$(grep -c '^COPILOT_EFFORT="${COPILOT_EFFORT:-}"$' "$script")" \
  "1"

# Every copilot run that forwards a coding model forwards the effort too. The
# cheap side models (triage, commit message, close summary, AGENTS.md) stay on
# their defaults.
model_lines="$(grep -nE 'copilot_args\+=\(--model "\$(COPILOT_MODEL|coding_model)"\)' "$script" | cut -d: -f1)"
missing=""
while read -r line; do
  [ -n "$line" ] || continue
  next="$(sed -n "$((line + 1))p" "$script")"
  case "$next" in
    *'copilot_args+=(--effort "$COPILOT_EFFORT")'*) ;;
    *) missing="$missing $line" ;;
  esac
done <<< "$model_lines"
assert_eq "every coding run forwards the effort next to the model" \
  "${missing:-none}" \
  "none"

assert_eq "there is at least one such run" \
  "$([ -n "$model_lines" ] && echo yes || echo no)" \
  "yes"

if [ "$fail" -eq 0 ]; then
  echo "All reasoning-effort tests passed."
else
  echo "Some reasoning-effort tests FAILED."
fi
exit "$fail"
