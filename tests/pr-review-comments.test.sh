#!/usr/bin/env bash
# shellcheck disable=SC2317  # mock/stub helpers are invoked indirectly by the code under test
#
# Tests for the PR review-comments helpers in copilot-loop.sh. Before picking
# new issues the loop scans open PRs for unresolved reviewer comments, claims
# the first eligible PR atomically (under the GitHub lock), hands the first
# unclaimed thread to Copilot, then posts a reply with what was done.
#
# The helpers are extracted verbatim between the "pr-review-comments helpers"
# markers; gh/GraphQL calls are mocked so no real GitHub access is required.
# The mock captures the --jq filter and --arg pairs, applies them to a JSON
# fixture, so the real jq filtering logic (resolved/in-progress exclusions) is
# exercised without touching GitHub.
#
# Run: tests/pr-review-comments.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

review_block="$(sed -n '/# >>> pr-review-comments helpers >>>/,/# <<< pr-review-comments helpers <<</p' "$script")"
[ -n "$review_block" ] || { echo "could not extract pr-review-comments helpers (markers missing?)"; exit 1; }

# Also pull in clean_summary (used inside resolve_pr_review_comments)
clean_summary_fn="$(awk '/^clean_summary\(\)/{p=1} p{print} p && /^\}$/{p=0}' "$script" | head -25)"
eval "$clean_summary_fn"
eval "$review_block"

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

# --- Config consumed by the extracted helpers --------------------------------
# shellcheck disable=SC2034
DEFAULT_BRANCH="main"
# shellcheck disable=SC2034
INPROGRESS_LABEL="in-progress"
# shellcheck disable=SC2034
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
# shellcheck disable=SC2034
CHECKS_UNRESOLVED_LABEL="checks-unresolved"
# shellcheck disable=SC2034
PR_COMMENT_INPROGRESS_MARKER="<!-- copilot-loop:pr-comment-in-progress -->"
# shellcheck disable=SC2034
COPILOT_MODEL=""
# shellcheck disable=SC2034
COPILOT_TIMEOUT=""

LOG_DIR="$(mktemp -d)"
WORKSPACE_DIR="$(mktemp -d)"
REPO_DIR="$(mktemp -d)"
PR_FILE="$(mktemp)"
EDITS_FILE="$(mktemp)"
GQL_FILE="$(mktemp)"
GQL_QUERY_FILE="$(mktemp)"

: >"$EDITS_FILE" >"$GQL_QUERY_FILE"

cleanup() { rm -rf "$LOG_DIR" "$WORKSPACE_DIR" "$REPO_DIR"; rm -f "$PR_FILE" "$EDITS_FILE" "$GQL_FILE" "$GQL_QUERY_FILE"; }
trap cleanup EXIT

# Stubs for helpers called by the extracted functions
log() { :; }
vlog() { :; }
acquire_github_lock() { return 0; }
release_github_lock() { :; }
set_terminal_title() { :; }
prepare_workspace() { return 0; }
cleanup_workspace() { :; }
run_copilot() { COPILOT_RC=0; }
_report_usage() { :; }
copilot_run_timed_out() { return 1; }

# Mock gh. For "api graphql": captures the --jq filter and any --arg key val
# triples that follow it, then runs jq on the GQL_FILE fixture. This exercises
# the real jq filter (resolved / in-progress exclusions) without hitting GitHub.
# Records the -f query=... value in GQL_QUERY_FILE for mutation-name assertions.
gh() {
  local sub="$1 $2"; shift 2
  case "$sub" in
    "pr list")
      local jqf=""
      while [ $# -gt 0 ]; do
        [ "$1" = "--jq" ] && { jqf="$2"; shift 2; } || shift
      done
      jq -r "$jqf" "$PR_FILE"
      ;;
    "pr edit")
      local num="$1"; shift
      local action="" label=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --add-label)    action="add";    label="$2"; shift 2 ;;
          --remove-label) action="remove"; label="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      printf '%s:%s:%s\n' "$action" "$num" "$label" >>"$EDITS_FILE"
      local tmp; tmp="$(mktemp)"
      if [ "$action" = "add" ]; then
        jq --arg n "$num" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels += [{"name":$l}]) else . end)' \
          "$PR_FILE" >"$tmp" && mv "$tmp" "$PR_FILE"
      else
        jq --arg n "$num" --arg l "$label" \
          'map(if (.number|tostring)==$n then (.labels |= map(select(.name != $l))) else . end)' \
          "$PR_FILE" >"$tmp" && mv "$tmp" "$PR_FILE"
      fi
      ;;
    "api graphql")
      # Collect the -f query=... value for mutation-name assertions
      # Collect --jq filter and --arg key val triples (in order after --jq)
      local jqf="" jq_args=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -f)
            printf '%s\n' "${2:-}" >>"$GQL_QUERY_FILE"
            shift 2 ;;
          -F) shift 2 ;;
          --jq)
            # Everything after --jq: collect --arg triples until the filter
            shift
            while [ $# -gt 0 ]; do
              if [ "$1" = "--arg" ]; then
                jq_args+=(--arg "$2" "$3")
                shift 3
              elif [[ "$1" == -* ]]; then
                break
              else
                jqf="$1"
                shift
                break
              fi
            done
            ;;
          *) shift ;;
        esac
      done
      if [ -n "$jqf" ] && [ -f "$GQL_FILE" ]; then
        jq -r "${jq_args[@]}" "$jqf" "$GQL_FILE" 2>/dev/null
      fi
      ;;
    "pr view")
      printf 'feature-branch\x00main\x00Test PR\x00'
      ;;
    "pr comment")
      : ;;
  esac
}

# Helper: write a full GraphQL reviewThreads response to GQL_FILE
write_threads_fixture() { cat >"$GQL_FILE"; }

# --- pr_review_threads: returns unresolved unclaimed threads -----------------

write_threads_fixture <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "thread-1",
              "isResolved": false,
              "path": "src/foo.rs",
              "line": 42,
              "originalLine": 42,
              "diffHunk": "@@ -1,3 +1,4 @@",
              "comments": {
                "nodes": [
                  {"body": "please fix this", "author": {"login": "alice"}}
                ]
              }
            },
            {
              "id": "thread-2",
              "isResolved": true,
              "path": "src/bar.rs",
              "line": 5,
              "originalLine": 5,
              "diffHunk": "@@ -5,1 +5,2 @@",
              "comments": {
                "nodes": [
                  {"body": "resolved already", "author": {"login": "bob"}}
                ]
              }
            }
          ]
        }
      }
    }
  }
}
JSON

result="$(pr_review_threads 10)"
assert_eq "pr_review_threads returns unclaimed unresolved thread" \
  "$(printf '%s' "$result" | grep -c 'thread-1')" "1"
assert_eq "pr_review_threads skips resolved threads (isResolved=true)" \
  "$(printf '%s' "$result" | grep -c 'thread-2')" "0"

# --- pr_review_threads: skips threads already claimed (in-progress marker) ---

write_threads_fixture <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "thread-claimed",
              "isResolved": false,
              "path": "src/baz.rs",
              "line": 10,
              "originalLine": 10,
              "diffHunk": "@@ hunk",
              "comments": {
                "nodes": [
                  {"body": "bot-loop is handling this\u2026 <!-- copilot-loop:pr-comment-in-progress -->", "author": {"login": "bot-loop[bot]"}}
                ]
              }
            }
          ]
        }
      }
    }
  }
}
JSON

assert_eq "pr_review_threads skips threads with in-progress marker" \
  "$(pr_review_threads 10)" ""

# --- next_pr_with_review_comments: skips ineligible PRs ----------------------

write_threads_fixture <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "thread-open",
              "isResolved": false,
              "path": "main.go",
              "line": 1,
              "originalLine": 1,
              "diffHunk": "@@ hunk",
              "comments": {
                "nodes": [
                  {"body": "please update", "author": {"login": "reviewer"}}
                ]
              }
            }
          ]
        }
      }
    }
  }
}
JSON

cat >"$PR_FILE" <<'JSON'
[
  {"number":10,"labels":[{"name":"conflict-unresolved"}]},
  {"number":11,"labels":[{"name":"checks-unresolved"}]},
  {"number":12,"labels":[{"name":"in-progress"}]},
  {"number":13,"labels":[]}
]
JSON

assert_eq "next_pr_with_review_comments skips conflict/checks/in-progress; returns 13" \
  "$(next_pr_with_review_comments)" "13"

# --- next_pr_with_review_comments: empty threads -> no match -----------------

write_threads_fixture <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": []
        }
      }
    }
  }
}
JSON

assert_eq "next_pr_with_review_comments returns empty when no unresolved threads" \
  "$(next_pr_with_review_comments)" ""

# --- next_pr_with_review_comments: picks lowest PR number --------------------

write_threads_fixture <<'JSON'
{
  "data": {
    "repository": {
      "pullRequest": {
        "reviewThreads": {
          "nodes": [
            {
              "id": "thread-y",
              "isResolved": false,
              "path": "a.go",
              "line": 1,
              "originalLine": 1,
              "diffHunk": "@@ hunk",
              "comments": {
                "nodes": [
                  {"body": "fix", "author": {"login": "user"}}
                ]
              }
            }
          ]
        }
      }
    }
  }
}
JSON

cat >"$PR_FILE" <<'JSON'
[
  {"number":20,"labels":[]},
  {"number":15,"labels":[]},
  {"number":30,"labels":[]}
]
JSON

assert_eq "next_pr_with_review_comments returns lowest-numbered eligible PR" \
  "$(next_pr_with_review_comments)" "15"

# --- claim_next_pr_with_review_comments: marks PR in-progress ----------------

cat >"$PR_FILE" <<'JSON'
[{"number":7,"labels":[]}, {"number":9,"labels":[]}]
JSON
: >"$EDITS_FILE"

claim1="$(claim_next_pr_with_review_comments)"
assert_eq "claim returns the lowest eligible PR"     "$claim1" "7"
assert_eq "claim marks that PR in-progress"          "$(cat "$EDITS_FILE")" "add:7:in-progress"

# Second claim skips PR 7 (now in-progress) and returns PR 9
claim2="$(claim_next_pr_with_review_comments)"
assert_eq "second claim skips already-claimed PR"    "$claim2" "9"

# Third claim finds nothing (both in-progress)
claim3="$(claim_next_pr_with_review_comments)"; claim3_rc=$?
assert_eq "third claim finds nothing"                "$claim3" ""
assert_eq "third claim returns non-zero" \
  "$([ "$claim3_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

# --- _post_review_thread_reply uses addPullRequestReviewThreadReply ----------
# and never calls resolveReviewThread (only the user resolves threads — rule 1).

: >"$GQL_QUERY_FILE"
_post_review_thread_reply "thread-abc" "42" "here is what was done"

assert_eq "_post_review_thread_reply calls addPullRequestReviewThreadReply" \
  "$(grep -c 'addPullRequestReviewThreadReply' "$GQL_QUERY_FILE")" "1"
assert_eq "_post_review_thread_reply never calls resolveReviewThread" \
  "$(grep -c 'resolveReviewThread' "$GQL_QUERY_FILE")" "0"

if [ "$fail" -eq 0 ]; then
  echo "All pr-review-comments tests passed."
else
  echo "Some pr-review-comments tests FAILED."
fi
exit "$fail"
