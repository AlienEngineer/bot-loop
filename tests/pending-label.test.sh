#!/usr/bin/env bash
#
# Unit tests for the "pending" label helpers in copilot-loop.sh. An issue held
# back by an open dependency ("Wait for: #N") is labelled "pending"; the label
# is removed once nothing blocks it. The pure decision (pending_action) is
# extracted verbatim from the script between the "pending-label helpers"
# markers, and reconcile_pending_labels is exercised with `gh` mocked so the
# real reconciliation runs without touching GitHub.
#
# Run: tests/pending-label.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

# reconcile_pending_labels depends on the wait-for helpers (issue_open_blockers),
# so pull those in too. Both blocks are extracted verbatim from the script.
wait_block="$(sed -n '/# >>> wait-for helpers >>>/,/# <<< wait-for helpers <<</p' "$script")"
[ -n "$wait_block" ] || { echo "could not extract wait-for helpers (markers missing?)"; exit 1; }
pending_block="$(sed -n '/# >>> pending-label helpers >>>/,/# <<< pending-label helpers <<</p' "$script")"
[ -n "$pending_block" ] || { echo "could not extract pending-label helpers (markers missing?)"; exit 1; }
# reconcile_pending_labels lives just after the marked block; pull the whole
# function too so the integration path is exercised against the real code.
reconcile_block="$(sed -n '/^reconcile_pending_labels() {/,/^}/p' "$script")"
[ -n "$reconcile_block" ] || { echo "could not extract reconcile_pending_labels"; exit 1; }
eval "$wait_block"
eval "$pending_block"
eval "$reconcile_block"

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

# --- pending_action: pure decision table ------------------------------------
assert_eq "blocked, unlabelled -> add"    "$(pending_action '44' 'false')"          "add"
assert_eq "blocked, empty flag -> add"    "$(pending_action '44' '')"               "add"
assert_eq "blocked, many -> add"          "$(pending_action "$(printf '44\n45')" 'false')" "add"
assert_eq "blocked, labelled -> noop"     "$(pending_action '44' 'true')"           ""
assert_eq "clear, labelled -> remove"     "$(pending_action '' 'true')"             "remove"
assert_eq "clear, unlabelled -> noop"     "$(pending_action '' 'false')"            ""
assert_eq "clear, empty flag -> noop"     "$(pending_action '' '')"                 ""

# --- reconcile_pending_labels: end-to-end with gh mocked --------------------
# Config the reconciler reads from the environment. These are consumed by the
# eval'd reconcile_pending_labels above, which shellcheck cannot see statically.
# shellcheck disable=SC2034
TRIGGER_LABEL="ready"
# shellcheck disable=SC2034
NEEDS_INFO_LABEL="needs-info"
# shellcheck disable=SC2034
FAILED_LABEL="copilot-failed"
# shellcheck disable=SC2034
PENDING_LABEL="pending"

# Silence the reconciler's log lines and stub the blocker formatter it uses.
log() { :; }
_fmt_blockers() { printf '%s' "$1"; }

# Fixture: dependency states and per-issue body / current pending flag.
declare -A STATE BODY HASPEND
STATE[44]="OPEN"     # unresolved dependency
STATE[43]="CLOSED"   # resolved dependency

BODY[45]="Wait for: #44"   ; HASPEND[45]="false"  # blocked, needs the label -> add
BODY[50]="Wait for: #44"   ; HASPEND[50]="true"   # blocked, already labelled -> noop
BODY[60]="Wait for: #43"   ; HASPEND[60]="true"   # unblocked, stale label   -> remove
BODY[70]="no dependencies" ; HASPEND[70]="false"  # never blocked            -> noop
BODY[80]="Wait for: #43"   ; HASPEND[80]="false"  # unblocked, unlabelled    -> noop

QUEUE="45 50 60 70 80"
EDITS=""

# Mock gh: list returns the queue (deduped by the caller), view answers the
# body/labels/state field asked for, edit records add/remove operations.
gh() {
  case "$1 $2" in
    "issue list")
      printf '%s\n' $QUEUE ;;
    "issue view")
      local n="$3"
      case "$*" in
        *"--json body"*)   printf '%s' "${BODY[$n]:-}" ;;
        *"--json labels"*) printf '%s' "${HASPEND[$n]:-false}" ;;
        *"--json state"*)  printf '%s' "${STATE[$n]:-}" ;;
      esac ;;
    "issue edit")
      local n="$3"
      case "$*" in
        *"--add-label"*)    EDITS="${EDITS:+$EDITS }add:$n" ;;
        *"--remove-label"*) EDITS="${EDITS:+$EDITS }remove:$n" ;;
      esac ;;
  esac
}

reconcile_pending_labels
assert_eq "reconcile edits only changed issues" "$EDITS" "add:45 remove:60"

if [ "$fail" -eq 0 ]; then
  echo "All pending-label tests passed."
else
  echo "Some pending-label tests FAILED."
fi
exit "$fail"
