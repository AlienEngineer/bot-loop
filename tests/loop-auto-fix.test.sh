#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2034  # helpers/vars are used indirectly by the eval'd functions under test
#
# Tests for the self-improving "loop auto-fix" behaviour in copilot-loop.sh
# (issue #218). When the loop ITSELF crashes — a guarded unit exits unexpectedly,
# i.e. a bug in the loop rather than a handled failure — the loop reports the
# crash upstream so it can be fixed:
#   * operator can push to the bot-loop repo  -> file a trigger-labelled fix
#     issue there (the loop then resolves it into a PR);
#   * operator cannot push                    -> write a local crash report and
#     email the maintainer, asking the operator to forward it.
# When the error could not be captured a generic "the loop crashed" message is
# used instead. Reports are de-duplicated so a recurring crash is filed once.
#
# The real functions are extracted verbatim from the script (the marker-delimited
# auto-fix block, plus guard()/_guard_on_exit() for the end-to-end crash test)
# and sourced here with stubbed gh/mail, so the shipping code is exercised.
#
# Run: tests/loop-auto-fix.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"
[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

autofix_block="$(sed -n '/# >>> auto-fix helpers >>>/,/# <<< auto-fix helpers <<</p' "$script")"
[ -n "$autofix_block" ] || { echo "could not extract the auto-fix helper block"; exit 1; }
on_exit_block="$(sed -n '/^_guard_on_exit() {/,/^}/p' "$script")"
[ -n "$on_exit_block" ] || { echo "could not extract _guard_on_exit()"; exit 1; }
guard_block="$(sed -n '/^guard() {/,/^}/p' "$script")"
[ -n "$guard_block" ] || { echo "could not extract guard()"; exit 1; }

fail=0
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
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then printf 'ok   - %s\n' "$desc"
  else printf 'FAIL - %s\n       got:  [%s]\n       want: [%s]\n' "$desc" "$got" "$want"; fail=1; fi
}
exists() { [ -e "$1" ] && echo yes || echo no; }

tmp="$(mktemp -d 2>/dev/null || mktemp -d -t autofixtest)"
trap 'rm -rf "$tmp"' EXIT

# --- Config the extracted functions read ------------------------------------
AUTO_FIX=1
BOT_LOOP_REPO="test/bot-loop"
BOT_LOOP_EMAIL="maintainer@example.com"
TRIGGER_LABEL="ready"
AUTO_FIX_MARKER="<!-- copilot-loop:auto-fix -->"
AUTO_FIX_STATE_DIR="$tmp/state"
WORK_DIR="$tmp"

# Faithful log(): to stdout and, when set, into the active run log (as in the
# script), so both the terminal narration and the per-run log can be asserted.
CURRENT_RUN_LOG=""
log() {
  local line
  line="$(printf '%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$line"
  if [ -n "${CURRENT_RUN_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$CURRENT_RUN_LOG" 2>/dev/null || true
  fi
}

# --- Stubs: observe gh and mail without touching the network ----------------
# gh: `api` echoes the controllable push permission; `issue create` records the
# call (so the label/repo/body can be asserted) and echoes a fake issue URL.
GH_PUSH="true"
gh() {
  case "${1:-}" in
    api)    printf '%s\n' "$GH_PUSH" ;;
    issue)
      shift
      printf 'CREATE %s\n' "$*" >>"$tmp/gh-issue.log"
      printf 'https://github.com/%s/issues/999\n' "$BOT_LOOP_REPO"
      ;;
    *) return 0 ;;
  esac
}
# mail: record the invocation and drain stdin (the report is piped in).
mail() { printf 'MAIL %s\n' "$*" >>"$tmp/mail.log"; cat >/dev/null 2>&1 || true; }

eval "$autofix_block"
eval "$on_exit_block"
eval "$guard_block"

reset_state() { rm -rf "$tmp/state" "$tmp/gh-issue.log" "$tmp/mail.log"; }

# --- _auto_fix_signature: stable, and sensitive to input ---------------------
s1="$(_auto_fix_signature "issue #7" "boom")"
s2="$(_auto_fix_signature "issue #7" "boom")"
s3="$(_auto_fix_signature "issue #7" "different error")"
assert_eq "signature: same input -> same signature" "$s1" "$s2"
if [ "$s1" != "$s3" ]; then printf 'ok   - signature: different error -> different signature\n'
else printf 'FAIL - signature: different error should differ\n'; fail=1; fi

# --- bot_loop_can_push: reads the repo permission ----------------------------
GH_PUSH="true"
if bot_loop_can_push "test/bot-loop"; then printf 'ok   - can-push: true when the user has push\n'
else printf 'FAIL - can-push: should be true when push=true\n'; fail=1; fi
GH_PUSH="false"
if bot_loop_can_push "test/bot-loop"; then printf 'FAIL - can-push: should be false when push=false\n'; fail=1
else printf 'ok   - can-push: false when the user cannot push\n'; fi

# --- _auto_fix_build_prompt: embeds the error, or a generic note -------------
p_err="$(_auto_fix_build_prompt "issue #7" "segfault in prepare_workspace")"
assert_contains "prompt: names the crash" "$p_err" "crashed while running \"issue #7\""
assert_contains "prompt: embeds the captured error" "$p_err" "segfault in prepare_workspace"
p_gen="$(_auto_fix_build_prompt "issue #7" "")"
assert_contains "prompt: generic note when no error captured" "$p_gen" "could not be captured"

# --- Option 1: operator can push -> file a ready-labelled fix issue ----------
reset_state
GH_PUSH="true"
printf 'unbound variable: triage_class\n' >"$tmp/err1"
out="$(report_loop_error "issue #218" "$tmp/err1" 2>&1)"
gh_log="$(cat "$tmp/gh-issue.log" 2>/dev/null)"
assert_contains "push: filed a fix issue"                "$gh_log" "CREATE create"
assert_contains "push: filed on the bot-loop repo"       "$gh_log" "--repo test/bot-loop"
assert_contains "push: labelled with the trigger label"  "$gh_log" "--label ready"
assert_contains "push: issue carries the captured error" "$gh_log" "unbound variable: triage_class"
assert_contains "push: logs where the fix was filed"     "$out"    "filed a fix request on test/bot-loop"
assert_eq "push: no report emailed when a fix issue was filed" "$(exists "$tmp/mail.log")" "no"
assert_eq "push: recorded the crash so it is not re-filed" "$(exists "$tmp/state/reported-$(_auto_fix_signature "unbound variable: triage_class")")" "yes"

# De-dup: the SAME crash is reported once, not on every pass.
out2="$(report_loop_error "issue #218" "$tmp/err1" 2>&1)"
n_created="$(grep -c 'CREATE' "$tmp/gh-issue.log" 2>/dev/null || echo 0)"
assert_eq "push: recurring crash filed only once" "$n_created" "1"
assert_contains "push: second time says already reported" "$out2" "already reported"

# De-dup spans units: the SAME bug hit while running a DIFFERENT issue is still
# reported only once, so one loop bug does not file an issue per affected issue.
out3="$(report_loop_error "issue #219" "$tmp/err1" 2>&1)"
n_created="$(grep -c 'CREATE' "$tmp/gh-issue.log" 2>/dev/null || echo 0)"
assert_eq "push: same bug on another issue not re-filed" "$n_created" "1"
assert_contains "push: cross-issue duplicate says already reported" "$out3" "already reported"

# --- Generic message path: the error could not be captured -------------------
reset_state
GH_PUSH="true"
out="$(report_loop_error "the sync step" "$tmp/does-not-exist" 2>&1)"
gh_log="$(cat "$tmp/gh-issue.log" 2>/dev/null)"
assert_contains "no-error: still files a fix request" "$gh_log" "CREATE create"
assert_contains "no-error: uses the generic message"  "$gh_log" "could not be captured"

# --- Option 2: operator cannot push -> write a report and email the owner -----
reset_state
GH_PUSH="false"
printf 'git worktree add failed: already exists\n' >"$tmp/err2"
out="$(report_loop_error "issue #218" "$tmp/err2" 2>&1)"
assert_eq "report: did NOT open a GitHub issue" "$(exists "$tmp/gh-issue.log")" "no"
report_file=""
for f in "$tmp"/state/report-*.md; do [ -e "$f" ] && { report_file="$f"; break; }; done
assert_eq "report: wrote a crash report to disk" "$([ -n "$report_file" ] && echo yes || echo no)" "yes"
report_body="$(cat "$report_file" 2>/dev/null)"
assert_contains "report: describes the problem"        "$report_body" "git worktree add failed"
assert_contains "report: names the maintainer email"   "$report_body" "maintainer@example.com"
assert_contains "report: asks the user to forward it"   "$report_body" "send this report"
mail_log="$(cat "$tmp/mail.log" 2>/dev/null)"
assert_contains "report: emailed the maintainer"        "$mail_log" "maintainer@example.com"
assert_contains "report: log tells the operator what happened" "$out" "crash report"

# --- AUTO_FIX=0: the whole feature is a silent no-op -------------------------
reset_state
AUTO_FIX=0
GH_PUSH="true"
out="$(report_loop_error "issue #218" "$tmp/err1" 2>&1)"
assert_eq "off: opened no GitHub issue"  "$(exists "$tmp/gh-issue.log")" "no"
assert_eq "off: wrote no report"         "$(exists "$tmp/state")" "no"
assert_eq "off: stayed silent"           "$out" ""
AUTO_FIX=1

# --- End to end: a real loop crash triggers the self-improvement report ------
# A guarded unit crashes on an unbound variable (the #214/#216 regression). guard()
# contains the crash AND, via report_loop_error(), files a fix issue upstream, so
# the loop does not just crash and forget — it reports itself for fixing.
reset_state
GH_PUSH="true"
CURRENT_RUN_LOG=""
unit_crash() {
  CURRENT_RUN_LOG="$tmp/issue-218-run.log"; : >"$CURRENT_RUN_LOG"
  log "issue #218: working on branch copilot/218-x"
  local triage_class
  [ -n "$triage_class" ] && true
}
out="$(guard "issue #218" unit_crash 2>&1)"; rc=$?
printf 'ok   - e2e: the loop survived the crash\n'
assert_contains "e2e: guard still reports the crash"        "$out" "issue #218 ended unexpectedly"
assert_contains "e2e: a fix request was filed for the crash" "$(cat "$tmp/gh-issue.log" 2>/dev/null)" "CREATE create"
assert_contains "e2e: the fix request carries the real error" "$(cat "$tmp/gh-issue.log" 2>/dev/null)" "unbound variable"
if [ "$rc" -ne 0 ]; then printf 'ok   - e2e: guard still returns non-zero\n'; else printf 'FAIL - e2e: guard should return non-zero\n'; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "All loop-auto-fix tests passed."
else
  echo "Some loop-auto-fix tests FAILED."
fi
exit "$fail"
