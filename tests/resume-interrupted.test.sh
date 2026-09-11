#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd code under test
#
# Tests for resuming interrupted in-progress issues (#233).
#
# When a bot is killed mid-run its issue is left labelled "in-progress" and its
# Copilot session abandoned, so re-running it later starts from scratch. The loop
# now pins a known Copilot session id per run and drops a marker while Copilot is
# live; a marker that survives means the run was interrupted. On the next start
# resume_interrupted_issues continues that exact session with `copilot --resume`
# in the original workspace, instead of leaving the issue hanging.
#
# These are user-perspective checks on the observable outcomes:
#   - a killed run's issue (owner gone, still in-progress) is RESUMED, and it is
#     resumed with its ORIGINAL session id and branch (so no context/work is lost);
#   - an issue a live loop still owns is LEFT ALONE (no double work);
#   - a marker whose issue already moved on is DISCARDED (no stale re-runs);
#   - the run selects the right Copilot CLI arg (--session-id for a new session,
#     --resume for an interrupted one);
#   - the resume prompt tells Copilot to continue where it left off.
#
# The functions are extracted verbatim from copilot-loop.sh and sourced here.
#
# Run: tests/resume-interrupted.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

extract() { sed -n "/^$1() {/,/^}/p" "$script"; }

ownership_block="$(sed -n '/# >>> worker-ownership helpers >>>/,/# <<< worker-ownership helpers <<</p' "$script")"
[ -n "$ownership_block" ] || { echo "could not extract worker ownership helpers"; exit 1; }
eval "$ownership_block"

for fn in log _new_session_id copilot_session_arg _resume_marker_path \
          write_resume_marker clear_resume_marker resume_marker_field \
          resume_marker_action issue_has_label build_resume_prompt \
          resume_interrupted_issues; do
  block="$(extract "$fn")"
  [ -n "$block" ] || { echo "could not extract $fn() from copilot-loop.sh"; exit 1; }
  eval "$block"
done

fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"; fail=1; fi
}
assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)           printf 'FAIL - %s\n       [%s] does not contain [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
  esac
}
assert_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  case "$hay" in
    *"$needle"*) printf 'FAIL - %s\n       [%s] unexpectedly contains [%s]\n' "$desc" "$hay" "$needle"; fail=1 ;;
    *)           printf 'ok   - %s\n' "$desc" ;;
  esac
}

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t resumeint)"
trap 'rm -rf "$tmp"' EXIT

CURRENT_RUN_LOG=""
VERBOSE=0
INPROGRESS_LABEL="in-progress"
OVERRIDE_WORKER_LABEL="override worker"
WORKER_LABEL_PREFIX="worker:"
TASK_LABEL_PREFIX="bot-loop:task:"
WORKER_ID="build-host"
WORKER_LABEL="worker:build-host"
WORK_DIR="$tmp/.copilot-loop"
RESUME_DIR="$WORK_DIR/resume"

# --- copilot_session_arg: the CLI flag that selects the session ---------------
# A brand-new run pins the UUID (so it can be resumed later); an interrupted run
# continues it. Both are emitted as one =-joined arg so the id is never mistaken
# for a prompt.
assert_eq "session arg: fresh run pins --session-id" \
  "$(copilot_session_arg 0 abc-123)" "--session-id=abc-123"
assert_eq "session arg: resume run uses --resume" \
  "$(copilot_session_arg 1 abc-123)" "--resume=abc-123"

# --- resume_marker_action: what to do with a surviving marker at startup ------
assert_eq "action: owner alive -> skip (a live loop still owns it)" \
  "$(resume_marker_action 1 1)" "skip"
assert_eq "action: owner alive, not in-progress -> skip" \
  "$(resume_marker_action 1 0)" "skip"
assert_eq "action: owner gone, still in-progress -> resume" \
  "$(resume_marker_action 0 1)" "resume"
assert_eq "action: owner gone, moved on -> drop (stale)" \
  "$(resume_marker_action 0 0)" "drop"
assert_eq "action: marker from another worker -> drop" \
  "$(resume_marker_action 0 1 other build-host worker:other)" "drop"
assert_eq "action: override pending -> drop" \
  "$(resume_marker_action 0 1 build-host build-host worker:build-host \
      $'in-progress\037worker:build-host\037override worker')" "drop"
assert_eq "action: takeover has multiple owners -> drop" \
  "$(resume_marker_action 0 1 build-host build-host worker:build-host \
      $'in-progress\037worker:build-host\037worker:other')" "drop"

# --- _new_session_id: always a fresh lowercase UUID ---------------------------
sid1="$(_new_session_id)"
sid2="$(_new_session_id)"
uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
assert_eq "session id: looks like a lowercase UUID" \
  "$([[ "$sid1" =~ $uuid_re ]] && echo yes || echo no)" "yes"
assert_eq "session id: two runs get different ids" \
  "$([ "$sid1" != "$sid2" ] && echo yes || echo no)" "yes"

# --- marker lifecycle: write records everything, clear removes it -------------
write_resume_marker 42 "sess-42" "copilot/42-thing" "$tmp/issue-42.log"
marker="$RESUME_DIR/issue-42.env"
assert_eq "marker: written for the issue"        "$([ -f "$marker" ] && echo yes || echo no)" "yes"
assert_eq "marker: records the session id"       "$(resume_marker_field "$marker" SESSION_ID)" "sess-42"
assert_eq "marker: records the work branch"      "$(resume_marker_field "$marker" BRANCH)" "copilot/42-thing"
assert_eq "marker: records the issue number"     "$(resume_marker_field "$marker" NUM)" "42"
assert_eq "marker: records the owning loop pid"  "$(resume_marker_field "$marker" PID)" "$$"
assert_eq "marker: records the worker identity" "$(resume_marker_field "$marker" WORKER_ID)" "build-host"
assert_eq "marker: records the task kind"        "$(resume_marker_field "$marker" TASK_KIND)" "process"
clear_resume_marker 42
assert_eq "marker: cleared once Copilot returns" "$([ -e "$marker" ] && echo exists || echo gone)" "gone"

# --- build_resume_prompt: tells Copilot to continue, keeps the guardrails ------
qf="$tmp/wt/.copilot-loop/issue-9.question"
rp="$(build_resume_prompt 9 "Fix the widget" "$qf" $'\nAdd tests too.\n')"
assert_contains "resume prompt: says it was interrupted"       "$rp" "interrupted"
assert_contains "resume prompt: names the issue number/title"  "$rp" 'issue #9 ("Fix the widget")'
assert_contains "resume prompt: keeps the no-commit guardrail"  "$rp" "Do NOT run git commit"
assert_contains "resume prompt: keeps the question-file path"   "$rp" "$qf"
assert_contains "resume prompt: carries the QA instruction"     "$rp" "Add tests too."

# --- resume_interrupted_issues: the startup sweep -----------------------------
# Stand in for the collaborators the sweep calls so we can observe its decisions.
# gh reports which issues are still in-progress; guard just runs the unit; and a
# stubbed process_issue records that it was asked to resume, with the env the
# sweep handed it (the original session id and branch).
INPROGRESS_ISSUES=" 7 8 10 11 12 13 "   # 9 has moved on
gh() {
  local jqf="${7:-}"
  if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
    if [[ "$jqf" == *'join("\u001f")'* ]]; then
      case "$3" in
        7|8)  printf 'in-progress\037worker:build-host\037bot-loop:task:process\n' ;;
        9)    printf 'worker:build-host\037bot-loop:task:process\n' ;;
        10)   printf 'in-progress\037worker:other\037bot-loop:task:process\n' ;;
        11)   printf 'in-progress\037worker:build-host\037bot-loop:task:process\037override worker\n' ;;
        12)   printf 'in-progress\037worker:other\037bot-loop:task:process\n' ;;
        13)   printf 'in-progress\037worker:other\037bot-loop:task:process\n' ;;
      esac
    else
      case " $INPROGRESS_ISSUES " in *" ${3} "*) echo "true" ;; *) echo "false" ;; esac
    fi
  fi
}
guard() { local _label="$1"; shift; "$@"; }
process_issue() {
  printf 'RESUMED num=%s session=%s branch=%s\n' \
    "$1" "${RESUME_SESSION_ID:-}" "${RESUME_BRANCH:-}" >>"$tmp/processed"
}

# A pid that is definitely not alive (a reaped background process), for the runs
# whose owning bot was killed.
( exit 0 ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null
if kill -0 "$dead_pid" 2>/dev/null; then dead_pid=2147480000; fi

: >"$tmp/processed"
mkdir -p "$RESUME_DIR"
# #7: owner dead + still in-progress  -> must be resumed with its session/branch.
printf 'NUM=7\nSESSION_ID=sess-7\nBRANCH=copilot/7-alpha\nPID=%s\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-7.env"
# #8: owner is THIS live process      -> a peer still owns it, must be left alone.
printf 'NUM=8\nSESSION_ID=sess-8\nBRANCH=copilot/8-beta\nPID=%s\nLOG=x\n' "$$"        >"$RESUME_DIR/issue-8.env"
# #9: owner dead but no longer in-progress -> stale marker, must be discarded.
printf 'NUM=9\nSESSION_ID=sess-9\nBRANCH=copilot/9-gamma\nPID=%s\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-9.env"
# #10: owner dead but a different machine owns the issue -> never resume here.
printf 'NUM=10\nSESSION_ID=sess-10\nBRANCH=copilot/10-delta\nPID=%s\nWORKER_ID=build-host\nTASK_KIND=process\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-10.env"
# #11: the user has explicitly requested a takeover -> discard the old marker.
printf 'NUM=11\nSESSION_ID=sess-11\nBRANCH=copilot/11-epsilon\nPID=%s\nWORKER_ID=build-host\nTASK_KIND=process\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-11.env"
# #12: another worker has already replaced this marker's owner.
printf 'NUM=12\nSESSION_ID=sess-12\nBRANCH=copilot/12-zeta\nPID=%s\nWORKER_ID=build-host\nTASK_KIND=process\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-12.env"
# #13: the marker itself belongs to another worker.
printf 'NUM=13\nSESSION_ID=sess-13\nBRANCH=copilot/13-eta\nPID=%s\nWORKER_ID=other\nTASK_KIND=process\nLOG=x\n' "$dead_pid" >"$RESUME_DIR/issue-13.env"

resume_interrupted_issues >/dev/null 2>&1
processed="$(cat "$tmp/processed" 2>/dev/null)"

assert_contains "sweep: resumes the killed run (#7)"                 "$processed" "RESUMED num=7"
assert_contains "sweep: resumes #7 with its ORIGINAL session id"    "$processed" "session=sess-7"
assert_contains "sweep: resumes #7 in its ORIGINAL branch"          "$processed" "branch=copilot/7-alpha"
assert_not_contains "sweep: leaves the live-owned issue (#8) alone" "$processed" "num=8"
assert_not_contains "sweep: does not resume the stale issue (#9)"   "$processed" "num=9"
assert_not_contains "sweep: does not resume a foreign-owned issue (#10)" "$processed" "num=10"
assert_not_contains "sweep: does not resume an overridden issue (#11)" "$processed" "num=11"
assert_not_contains "sweep: does not resume a retaken issue (#12)" "$processed" "num=12"
assert_not_contains "sweep: does not resume a foreign marker (#13)" "$processed" "num=13"
assert_eq "sweep: discards the stale marker (#9)" \
  "$([ -e "$RESUME_DIR/issue-9.env" ] && echo exists || echo gone)" "gone"
assert_eq "sweep: discards the foreign marker (#10)" \
  "$([ -e "$RESUME_DIR/issue-10.env" ] && echo exists || echo gone)" "gone"
assert_eq "sweep: discards the overridden marker (#11)" \
  "$([ -e "$RESUME_DIR/issue-11.env" ] && echo exists || echo gone)" "gone"
assert_eq "sweep: discards the retaken marker (#12)" \
  "$([ -e "$RESUME_DIR/issue-12.env" ] && echo exists || echo gone)" "gone"
assert_eq "sweep: discards the foreign-worker marker (#13)" \
  "$([ -e "$RESUME_DIR/issue-13.env" ] && echo exists || echo gone)" "gone"
assert_eq "sweep: keeps the live-owned marker (#8)" \
  "$([ -e "$RESUME_DIR/issue-8.env" ] && echo exists || echo gone)" "exists"

# Idempotent/no-op when there is nothing to resume (no resume dir at all).
rm -rf "$RESUME_DIR"
: >"$tmp/processed"
resume_interrupted_issues >/dev/null 2>&1
assert_eq "sweep: no-op when there are no markers" "$(cat "$tmp/processed")" ""

if [ "$fail" -eq 0 ]; then
  echo "All resume-interrupted tests passed."
else
  echo "Some resume-interrupted tests FAILED."
fi
exit "$fail"
