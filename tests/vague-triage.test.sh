#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034  # mocks/config are invoked and read indirectly by the extracted code under test
#
# Tests for the vagueness triage gate in copilot-loop.sh (#188). When triage is
# enabled the cheap TRIAGE_MODEL also judges whether an issue is specified well
# enough to implement; a genuinely vague issue is asked a clarifying question via
# the existing needs-info flow and gets no coding run, resuming once the author
# replies. The real code is exercised by extracting the marked blocks and driving
# them with mocks -- no GitHub and no model are touched.
#
# Covered:
#   - parse_vague_question:  the model's verdict -> question/proceed decision,
#     including the strong bias toward proceeding.
#   - comments_have_question: detects a question we already posted, so the gate
#     asks at most once.
#   - triage_vagueness:      the plumbing returns the parsed question and always
#     falls back to proceeding.
#   - maybe_ask_when_vague:  the end-to-end gate a user observes -- a vague issue
#     gets a clarifying comment + needs-info and no coding run; a clear issue is
#     untouched; a reply (or triage off, or an approved plan) is not re-asked.
#
# Run: tests/vague-triage.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

extract() {
  local block; block="$(sed -n "/# >>> $1 >>>/,/# <<< $1 <<</p" "$script")"
  [ -n "$block" ] || { echo "could not extract '$1' (markers missing?)"; exit 1; }
  eval "$block"
}
extract "vagueness helpers"      # comments_have_question, parse_vague_question
extract "triage-vagueness helper" # triage_vagueness
extract "plan-detect helpers"    # comments_have_plan (the plan guard)
extract "needs-info helpers"     # _ask_issue, maybe_ask_when_vague

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

# ============================================================================
# parse_vague_question: verdict -> clarifying question (or proceed)
# ============================================================================
assert_eq "CLEAR verdict proceeds"        "$(parse_vague_question 'CLEAR')"                              ""
assert_eq "empty answer proceeds"         "$(parse_vague_question '')"                                  ""
assert_eq "VAGUE + question is asked"     "$(parse_vague_question 'VAGUE: Which database stores sessions?')" "Which database stores sessions?"
assert_eq "lowercase vague works"         "$(parse_vague_question 'vague: which auth provider?')"       "which auth provider?"
assert_eq "dash separator works"          "$(parse_vague_question 'VAGUE - what format?')"              "what format?"
assert_eq "no separator works"            "$(parse_vague_question 'VAGUE what should it output?')"      "what should it output?"
assert_eq "leading blank lines ignored"   "$(parse_vague_question $'\n\nVAGUE: which DB?')"             "which DB?"
assert_eq "multi-line question kept"      "$(parse_vague_question $'VAGUE:\nWhich DB?\nWhich auth?')"   $'Which DB?\nWhich auth?'

# Bias toward proceeding: anything that is not an explicit VAGUE verdict with a
# real question proceeds, so false "vague" verdicts do not stall the backlog.
assert_eq "VAGUE with no question proceeds" "$(parse_vague_question 'VAGUE:')"                          ""
assert_eq "clear prose proceeds"          "$(parse_vague_question 'This issue is clear enough to build.')" ""
assert_eq "prose mentioning vague later"  "$(parse_vague_question 'The scope is not vague at all here.')" ""
assert_eq "unrecognised answer proceeds"  "$(parse_vague_question 'banana')"                            ""

# ============================================================================
# comments_have_question: ask-at-most-once signal
# ============================================================================
q_marker="<!-- copilot-loop:needs-info -->"
has_q() { if comments_have_question "$1"; then echo yes; else echo no; fi; }
assert_eq "marker present -> yes"   "$(has_q "we asked $q_marker earlier")" "yes"
assert_eq "marker on own line -> yes" "$(has_q $'a reply\n'"$q_marker")"    "yes"
assert_eq "no marker -> no"         "$(has_q 'just a normal conversation')" "no"
assert_eq "empty thread -> no"      "$(has_q '')"                           "no"

# ============================================================================
# triage_vagueness: plumbing returns the parsed question, always falls back to
# proceeding. The REAL function is run with the model call stubbed by
# _run_with_timeout (via a file counter, since it runs in a $() subshell) so no
# model is invoked.
# ============================================================================
# shellcheck disable=SC2034  # read by the extracted triage_vagueness
WORKSPACE_DIR=""
MODEL_RAW=""          # what the "model" prints
MODEL_CALLS_FILE="$(mktemp)"; : >"$MODEL_CALLS_FILE"
model_calls() { wc -l <"$MODEL_CALLS_FILE" | tr -d ' '; }
# shellcheck disable=SC2329
_run_with_timeout() { echo x >>"$MODEL_CALLS_FILE"; printf '%s' "$MODEL_RAW"; }

TRIAGE_MODEL="cheap-model"
MODEL_RAW='VAGUE: which database?'; : >"$MODEL_CALLS_FILE"
assert_eq "triage_vagueness returns the parsed question" "$(triage_vagueness 7 't' 'b')" "which database?"
assert_eq "triage_vagueness consulted the model"         "$(model_calls)" "1"

MODEL_RAW='CLEAR'
assert_eq "triage_vagueness proceeds on CLEAR" "$(triage_vagueness 7 't' 'b')" ""
MODEL_RAW=''
assert_eq "triage_vagueness proceeds on empty model output" "$(triage_vagueness 7 't' 'b')" ""

# Triage off: the model is never called and it always proceeds.
TRIAGE_MODEL=""; MODEL_RAW='VAGUE: ignored?'; : >"$MODEL_CALLS_FILE"
out="$(triage_vagueness 7 't' 'b')"
assert_eq "triage off -> proceeds"         "$out" ""
assert_eq "triage off -> model not called" "$(model_calls)" "0"

# ============================================================================
# maybe_ask_when_vague: the end-to-end gate, exercised with the REAL _ask_issue
# and a mocked gh so we assert the outcomes a user sees on the issue.
# ============================================================================
QUESTION_MARKER="<!-- copilot-loop:needs-info -->"
NEEDS_INFO_LABEL="needs-info"
INPROGRESS_LABEL="in-progress"
branch="copilot/7-demo"   # read by _ask_issue -> cleanup_workspace (mocked)

GH_LOG="$(mktemp)"
TRIAGE_CALLS_FILE="$(mktemp)"
trap 'rm -f "$GH_LOG" "$MODEL_CALLS_FILE" "$TRIAGE_CALLS_FILE"' EXIT
: >"$GH_LOG"
# shellcheck disable=SC2329
log() { :; }
# shellcheck disable=SC2329
cleanup_workspace() { :; }
# Record every gh action plus the comment body so the posted question + marker
# and the label changes are observable exactly as GitHub would receive them.
# shellcheck disable=SC2329
gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "issue comment")
      local num="$1"; shift
      local body=""
      while [ $# -gt 0 ]; do case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac; done
      printf 'comment:%s\n%s\n' "$num" "$body" >>"$GH_LOG"
      ;;
    "issue edit")
      local num="$1"; shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    printf 'add:%s:%s\n' "$num" "$2" >>"$GH_LOG"; shift 2 ;;
          --remove-label) printf 'remove:%s:%s\n' "$num" "$2" >>"$GH_LOG"; shift 2 ;;
          *) shift ;;
        esac
      done
      ;;
  esac
}

# The gate calls triage_vagueness; stub it to return VERDICT (piped through the
# REAL parse_vague_question, mirroring production) and count calls via a file
# (maybe_ask_when_vague invokes it in a $() subshell) so the guardrail skips are
# observable.
VERDICT=""
: >"$TRIAGE_CALLS_FILE"
triage_calls() { wc -l <"$TRIAGE_CALLS_FILE" | tr -d ' '; }
# shellcheck disable=SC2329
triage_vagueness() { echo x >>"$TRIAGE_CALLS_FILE"; parse_vague_question "$VERDICT"; }

QDIR="$(mktemp -d)"
trap 'rm -f "$GH_LOG" "$MODEL_CALLS_FILE" "$TRIAGE_CALLS_FILE"; rm -rf "$QDIR"' EXIT
gate() {  # <verdict> <comments> ; sets RC and leaves outcomes in $GH_LOG
  VERDICT="$1"; local comments="$2"
  : >"$GH_LOG"; : >"$TRIAGE_CALLS_FILE"
  local qf="$QDIR/issue-7.question"; rm -f "$qf"
  if maybe_ask_when_vague 7 "Add a thing" "body text" "$comments" "$qf" /dev/null; then RC=asked; else RC=proceed; fi
  QF_LEFT="$([ -e "$qf" ] && echo yes || echo no)"
}
ghlog() { tr '\n' '|' <"$GH_LOG"; }

# --- A clearly under-specified issue: clarifying comment + needs-info, no run --
TRIAGE_MODEL="cheap-model"
gate 'VAGUE: Which database should store the data?' 'fresh issue, no prior comments'
assert_eq "vague issue -> gate asks (caller stops, no coding run)" "$RC" "asked"
assert_eq "vague issue -> triage model consulted" "$(triage_calls)" "1"
case "$(cat "$GH_LOG")" in
  *"Which database should store the data?"*) assert_eq "vague issue -> question posted as a comment" "yes" "yes" ;;
  *) assert_eq "vague issue -> question posted as a comment" "no" "yes" ;;
esac
case "$(cat "$GH_LOG")" in
  *"$QUESTION_MARKER"*) assert_eq "vague issue -> comment carries the needs-info marker" "yes" "yes" ;;
  *) assert_eq "vague issue -> comment carries the needs-info marker" "no" "yes" ;;
esac
case "|$(ghlog)" in
  *"|add:7:needs-info|"*) assert_eq "vague issue -> labelled needs-info" "yes" "yes" ;;
  *) assert_eq "vague issue -> labelled needs-info" "no" "yes" ;;
esac
case "|$(ghlog)" in
  *"|remove:7:in-progress|"*) assert_eq "vague issue -> in-progress dropped" "yes" "yes" ;;
  *) assert_eq "vague issue -> in-progress dropped" "no" "yes" ;;
esac
assert_eq "vague issue -> question file consumed" "$QF_LEFT" "no"

# --- A well-specified issue: no comment, proceeds to coding ------------------
gate 'CLEAR' 'fresh, well-specified issue'
assert_eq "clear issue -> gate proceeds to coding"     "$RC" "proceed"
assert_eq "clear issue -> triage model was consulted"  "$(triage_calls)" "1"
assert_eq "clear issue -> nothing posted to the issue" "$(ghlog)" ""
assert_eq "clear issue -> no question file written"    "$QF_LEFT" "no"

# --- An author reply resumes the issue and it is not asked again -------------
# On resume the thread carries the question we posted earlier (QUESTION_MARKER).
gate 'VAGUE: still unclear?' $'--- @author wrote:\nhere is more detail\n'"$QUESTION_MARKER"
assert_eq "replied issue -> proceeds (not re-asked)"      "$RC" "proceed"
assert_eq "replied issue -> triage model NOT re-consulted" "$(triage_calls)" "0"
assert_eq "replied issue -> nothing posted"               "$(ghlog)" ""

# --- Triage off: behaviour unchanged (never asks, never consults the model) --
TRIAGE_MODEL=""
gate 'VAGUE: would ask if triage were on?' 'fresh issue'
assert_eq "triage off -> proceeds"                 "$RC" "proceed"
assert_eq "triage off -> triage model not consulted" "$(triage_calls)" "0"
assert_eq "triage off -> nothing posted"           "$(ghlog)" ""

# --- An approved plan pins the approach: the gate does not second-guess it ----
TRIAGE_MODEL="cheap-model"
gate 'VAGUE: would ask otherwise?' $'a plan was posted\n<!-- copilot-loop:plan -->'
assert_eq "approved plan -> proceeds"                 "$RC" "proceed"
assert_eq "approved plan -> triage model not consulted" "$(triage_calls)" "0"
assert_eq "approved plan -> nothing posted"           "$(ghlog)" ""

if [ "$fail" -eq 0 ]; then
  echo "All vague-triage tests passed."
else
  echo "Some vague-triage tests FAILED."
fi
exit "$fail"
