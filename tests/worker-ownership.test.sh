#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # mocks/config are used indirectly
#
# User-perspective tests for cross-machine issue ownership. The real ownership
# helpers and all three issue claimers are extracted from copilot-loop.sh and
# driven against a small GitHub fixture, so no network or model is needed.
#
# Run: tests/worker-ownership.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

ownership_block="$(sed -n '/# >>> worker-ownership helpers >>>/,/# <<< worker-ownership helpers <<</p' "$script")"
ready_block="$(sed -n '/^claim_next_ready_issue() {/,/^}/p' "$script")"
plan_block="$(sed -n '/# >>> plan-issue helpers >>>/,/# <<< plan-issue helpers <<</p' "$script")"
reply_block="$(sed -n '/^claim_next_reply_issue() {/,/^}/p' "$script")"
model_block="$(sed -n '/^should_pick_issue_by_model() {/,/^}/p' "$script")"
[ -n "$ownership_block" ] || { echo "could not extract worker ownership helpers"; exit 1; }
[ -n "$ready_block" ] || { echo "could not extract ready claimer"; exit 1; }
[ -n "$plan_block" ] || { echo "could not extract plan claimer"; exit 1; }
[ -n "$reply_block" ] || { echo "could not extract reply claimer"; exit 1; }
[ -n "$model_block" ] || { echo "could not extract model matcher"; exit 1; }
eval "$ownership_block"
eval "$model_block"
eval "$ready_block"
eval "$plan_block"
eval "$reply_block"

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
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *) printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}
assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'FAIL - %s\n       [%s] unexpectedly contains [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
    *) printf 'ok   - %s\n' "$desc" ;;
  esac
}

INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
FAILED_LABEL="copilot-failed"
NEEDS_INFO_LABEL="needs-info"
PENDING_LABEL="pending"
TRIGGER_LABEL="ready"
PLAN_LABEL="plan"
PLAN_REVIEW_LABEL="plan-review"
OVERRIDE_WORKER_LABEL="override worker"
WORKER_LABEL_PREFIX="worker:"
TASK_LABEL_PREFIX="bot-loop:task:"
TASK_PROCESS_LABEL="bot-loop:task:process"
TASK_PLAN_LABEL="bot-loop:task:plan"
TASK_REPLY_LABEL="bot-loop:task:reply"
WORKER_ID="build-host"
WORKER_LABEL="worker:build-host"
COPILOT_MODEL=""
BOT_LOGIN="bot-loop[bot]"

labels() {
  printf '%s' "$1" | tr '\037' ','
}

assert_issue_labels() {
  local desc="$1" n="$2" want="$3" got
  got="$(jq -r --arg n "$n" '.[] | select((.number|tostring)==$n) | [.labels[].name] | join(",")' "$ISSUES_FILE")"
  assert_eq "$desc" "$got" "$want"
}

ISSUES_FILE="$(mktemp)"
EDITS_FILE="$(mktemp)"
trap 'rm -f "$ISSUES_FILE" "$EDITS_FILE"' EXIT

cat >"$ISSUES_FILE" <<'JSON'
[
  {"number":1,"body":"ready issue","labels":[{"name":"ready"}],"state":"OPEN","comments":[]},
  {"number":2,"body":"foreign ready","labels":[{"name":"ready"},{"name":"worker:other"}],"state":"OPEN","comments":[]},
  {"number":3,"body":"legacy active","labels":[{"name":"ready"},{"name":"in-progress"}],"state":"OPEN","comments":[]},
  {"number":4,"body":"answered question","labels":[{"name":"needs-info"},{"name":"worker:build-host"},{"name":"bot-loop:task:process"}],"state":"OPEN","comments":[{"author":{"login":"bot-loop[bot]"}},{"author":{"login":"alice"}}]},
  {"number":5,"body":"override implementation","labels":[{"name":"in-progress"},{"name":"worker:other"},{"name":"bot-loop:task:process"},{"name":"override worker"}],"state":"OPEN","comments":[]},
  {"number":6,"body":"foreign active","labels":[{"name":"in-progress"},{"name":"worker:other"},{"name":"bot-loop:task:process"}],"state":"OPEN","comments":[]},
  {"number":7,"body":"override plan","labels":[{"name":"in-progress"},{"name":"worker:other"},{"name":"bot-loop:task:plan"},{"name":"override worker"}],"state":"OPEN","comments":[]},
  {"number":8,"body":"override reply","labels":[{"name":"in-progress"},{"name":"worker:other"},{"name":"bot-loop:task:reply"},{"name":"override worker"}],"state":"OPEN","comments":[]},
  {"number":9,"body":"verification race","labels":[{"name":"in-progress"},{"name":"worker:other"},{"name":"bot-loop:task:process"}],"state":"OPEN","comments":[]}
]
JSON

log() { :; }
acquire_github_lock() { return 0; }
release_github_lock() { :; }
_fmt_blockers() { printf '%s' "$1"; }
issue_open_blockers() { :; }

# Mock the GitHub calls used by the real queue/claim code. The fixture is mutated
# by issue edit, making a second claim observe the labels a user would see.
READBACK_MODE=""
READBACK_LABELS=""
EDIT_SEEN=0
gh() {
  local sub="${1:-} ${2:-}"
  shift 2
  case "$sub" in
    "issue list")
      local label="" jqf=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --label) label="$2"; shift 2 ;;
          --jq) jqf="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      jq --arg L "$label" \
        '[.[] | select(.state=="OPEN") | select(any(.labels[]; .name==$L))]' \
        "$ISSUES_FILE" | jq -r "$jqf"
      ;;
    "issue view")
      local n="$1" jqf=""
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jqf="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      if [ "$jqf" = '[.labels[].name] | join("\u001f")' ]; then
        if [ "$READBACK_MODE" = wrong ] && [ "$EDIT_SEEN" -eq 1 ]; then
          printf '%s' "$READBACK_LABELS"
        else
          jq -r --arg n "$n" \
            '.[] | select((.number|tostring)==$n) | [.labels[].name] | join("\u001f")' "$ISSUES_FILE"
        fi
      elif [[ "$jqf" == *'.comments[-1].author.login'* ]]; then
        jq -r --arg n "$n" \
          '.[] | select((.number|tostring)==$n) | [(.comments[-1].author.login // ""), (.body // ""), ([.labels[].name] | join("\u001f"))] | join("\u0000")' "$ISSUES_FILE"
      else
        jq -r --arg n "$n" '.[] | select((.number|tostring)==$n) | .state // ""' "$ISSUES_FILE"
      fi
      ;;
    "issue edit")
      local n="$1"; shift
      while [ $# -gt 0 ]; do
        local action="" label="" tmp
        case "$1" in
          --add-label) action=add; label="$2"; shift 2 ;;
          --remove-label) action=remove; label="$2"; shift 2 ;;
          *) shift; continue ;;
        esac
        printf '%s:%s:%s\n' "$action" "$n" "$label" >>"$EDITS_FILE"
        tmp="$(mktemp)"
        if [ "$action" = add ]; then
          jq --arg n "$n" --arg l "$label" \
            'map(if (.number|tostring)==$n and (any(.labels[]; .name==$l)|not) then (.labels += [{"name":$l}]) else . end)' \
            "$ISSUES_FILE" >"$tmp" && mv "$tmp" "$ISSUES_FILE"
        else
          jq --arg n "$n" --arg l "$label" \
            'map(if (.number|tostring)==$n then (.labels |= map(select(.name != $l))) else . end)' \
            "$ISSUES_FILE" >"$tmp" && mv "$tmp" "$ISSUES_FILE"
        fi
      done
      EDIT_SEEN=1
      ;;
  esac
}

# --- Identity and pure ownership decisions ----------------------------------
assert_eq "default-like hostname is normalized safely" \
  "$(normalize_worker_id 'Build.Host/CI_01')" "build-host-ci-01"
assert_eq "explicit identity is bounded and label-safe" \
  "$(worker_label_for_id 'A machine with spaces and punctuation!')" \
  "worker:a-machine-with-spaces-and-punctuation"
assert_eq "owner and task labels are parsed" \
  "$(worker_owner_label $'ready\037worker:build-host\037bot-loop:task:plan')" "worker:build-host"
assert_eq "task kind is parsed" \
  "$(worker_task_kind $'worker:build-host\037bot-loop:task:plan')" "plan"
assert_eq "unowned issue can be claimed" \
  "$(worker_claim_decision 'ready' process)" "claim"
assert_eq "foreign issue is skipped without override" \
  "$(worker_claim_decision $'ready\037worker:other' process)" "skip"
assert_eq "legacy in-progress issue is skipped" \
  "$(worker_claim_decision $'ready\037in-progress' process)" "skip"
assert_eq "override authorizes a typed takeover" \
  "$(worker_claim_decision $'in-progress\037worker:other\037bot-loop:task:process\037override worker' process)" "takeover"

# --- Ready queue: unowned, foreign, legacy, and takeover behavior ------------
: >"$EDITS_FILE"
claim="$(claim_next_ready_issue)"
assert_eq "ready queue claims the oldest unowned issue" "$claim" "1"
assert_issue_labels "ready claim records this worker and task" 1 \
  "in-progress,worker:build-host,bot-loop:task:process"

: >"$EDITS_FILE"
claim="$(claim_next_ready_issue)"
assert_eq "ready queue selects an explicit override takeover" "$claim" "5"
assert_issue_labels "override is consumed and foreign owner replaced" 5 \
  "in-progress,bot-loop:task:process,worker:build-host"
assert_not_contains "legacy active issue receives no edits" "$(cat "$EDITS_FILE")" "3:"

: >"$EDITS_FILE"
claim="$(claim_next_ready_issue)"
assert_eq "consumed override is not immediately stealable again" "$claim" ""
assert_not_contains "foreign active issue remains untouched" "$(cat "$EDITS_FILE")" "6:"

# --- Plan and reply queues route typed override work -------------------------
: >"$EDITS_FILE"
claim="$(claim_next_plan_issue)"
assert_eq "plan queue routes an override-only plan" "$claim" "7"
assert_issue_labels "plan takeover records plan task" 7 \
  "in-progress,bot-loop:task:plan,worker:build-host"

: >"$EDITS_FILE"
claim="$(claim_next_reply_issue)"
assert_eq "reply queue resumes the oldest human answer" "$claim" "4"
assert_issue_labels "reply continuation keeps its process task" 4 \
  "worker:build-host,bot-loop:task:process,in-progress"

: >"$EDITS_FILE"
claim="$(claim_next_reply_issue)"
assert_eq "reply queue routes an override-only reply" "$claim" "8"
assert_issue_labels "reply takeover records reply task" 8 \
  "in-progress,bot-loop:task:reply,worker:build-host"

# --- Unfinished and terminal transitions preserve exclusivity ---------------
assert_eq "unfinished transition succeeds for the owner" \
  "$(worker_mark_unfinished 5 "$NEEDS_INFO_LABEL"; echo "$?")" "0"
assert_issue_labels "needs-info retains owner and task" 5 \
  "bot-loop:task:process,worker:build-host,needs-info"
assert_eq "foreign unfinished issue is not changed" \
  "$(worker_mark_unfinished 6 "$NEEDS_INFO_LABEL"; echo "$?")" "1"
assert_issue_labels "foreign issue remains owned by the other worker" 6 \
  "in-progress,worker:other,bot-loop:task:process"

assert_eq "terminal release succeeds for the owner" \
  "$(worker_release_issue 1 "$DONE_LABEL"; echo "$?")" "0"
assert_issue_labels "terminal release removes owner and task" 1 \
  "copilot-done"
assert_eq "foreign terminal release is rejected" \
  "$(worker_release_issue 6 "$DONE_LABEL"; echo "$?")" "1"
assert_issue_labels "foreign issue remains active after rejected release" 6 \
  "in-progress,worker:other,bot-loop:task:process"

# --- Failed post-claim verification never removes the other owner ------------
# Put the dedicated race fixture in the override queue only after the normal
# ready/plan/reply scans have completed, so it cannot be selected early.
tmp="$(mktemp)"
jq 'map(if .number == 9 then .labels += [{"name":"override worker"}] else . end)' \
  "$ISSUES_FILE" >"$tmp" && mv "$tmp" "$ISSUES_FILE"
READBACK_MODE=wrong
READBACK_LABELS=$'in-progress\037worker:other\037bot-loop:task:process\037override worker'
EDIT_SEEN=0
: >"$EDITS_FILE"
if claim_issue_ownership 9 process ""; then
  claim_rc=claimed
else
  claim_rc=skipped
fi
assert_eq "failed read-back does not dispatch work" "$claim_rc" "skipped"
assert_contains "failed read-back cleans only this worker label" "$(cat "$EDITS_FILE")" \
  "remove:9:worker:build-host"
assert_not_contains "failed read-back does not remove other owner" "$(cat "$EDITS_FILE")" \
  "remove:9:worker:other"
assert_issue_labels "failed read-back leaves previous owner intact" 9 \
  "in-progress,worker:other,bot-loop:task:process,override worker"

if [ "$fail" -eq 0 ]; then
  echo "All worker-ownership tests passed."
else
  echo "Some worker-ownership tests FAILED."
fi
exit "$fail"
