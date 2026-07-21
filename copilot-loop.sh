#!/usr/bin/env bash
#
# copilot-loop.sh
#
# Autonomous loop that pulls labelled GitHub issues and hands each one to the
# GitHub Copilot CLI to resolve, then opens a pull request. When no work is
# available it sleeps and checks again.
#
# MULTI-INSTANCE SUPPORT: Multiple instances of this script can run concurrently
# without interfering with each other. Each instance will work on a different issue,
# and synchronization is handled via a GitHub lock file (.copilot-loop/github.lock)
# that protects issue selection and claiming operations. This allows you to:
# - Run multiple instances on the same machine (with different REPO_DIR)
# - Run multiple instances in parallel for the same repository
# - Use git worktrees for each instance to avoid file system conflicts
#
# Example multi-instance setup with worktrees:
#   # Main working tree
#   ./copilot-loop.sh
#
#   # In another terminal, create a worktree and run another instance:
#   git worktree add ../instance-2
#   cd ../instance-2
#   ./copilot-loop.sh
#
# Before each iteration the loop keeps itself current: it pulls the default
# branch and, if this script changed upstream, re-execs so the loop always runs
# the latest code. Set SELF_UPDATE=0 to turn this off.
#
# Flow per iteration:
#   0. Turn any markdown files in issues/ into GitHub issues (labelled with the
#      trigger label, or per a "Label:" directive in the file) so file-based
#      tasks enter the queue below.
#   0b. Sync the local default branch with origin/<default> so the loop's
#      baseline matches the remote before any work. A clean update fast-forwards;
#      when the local default branch has diverged and the merge conflicts, the
#      conflicts are handed to Copilot to resolve so the loop can move forward
#      (the resolved merge is kept local, never pushed). Set SYNC_REMOTE=0 to
#      turn this off (see the "sync-default helpers").
#   1. Before starting any new task, check open PRs targeting the default branch
#      for merge conflicts. GitHub computes mergeability asynchronously, so the
#      loop first waits (bounded) for any PR still reported UNKNOWN to be
#      evaluated, then — if a PR is conflicting — merges the base branch into it
#      and lets Copilot resolve the conflicts, then pushes, so PRs stay mergeable.
#   1b. Still before starting new work, check those open PRs for failing CI checks
#      and, when one is found, hand its failing checks to Copilot to fix on the PR
#      branch, commit and push so CI re-runs. Only one PR is fixed per pass; a PR
#      Copilot cannot fix is labelled "checks-unresolved" so it is not retried
#      forever. Conflicts are handled first, so a conflicting PR is never grabbed
#      here (see the "failing-checks-pr helpers").
#   2. Pick the next issue to work on (protected by GitHub lock):
#        a. an issue awaiting a reply ("needs-info") or a failed issue
#           ("copilot-failed") whose latest comment came from a human (the user
#           answered a question or gave more guidance) -> resume it; else
#        b. an issue labelled for plan mode (default: "plan") -> draft an
#           implementation plan (no code changes) with Copilot, post it on the
#           issue for review, label it "plan-review" and wait for the user to add
#           the trigger label to run it (see plan_issue); else
#        c. the oldest open issue with the trigger label (default: "ready"). When
#           that issue was planned first, the approved plan is in its thread and
#           Copilot is told to follow it (see comments_have_plan).
#      Issues that declare a dependency ("Wait for: #N" in the body) are held
#      back (and labelled "pending" while they wait) until every issue they name
#      is closed (see "Issue dependencies: Wait for: #N" further down).
#   3. Claim it: add "in-progress", remove the trigger/"needs-info" labels
#      (done atomically by the claiming functions to prevent race conditions).
#   4. Create a fresh branch for the issue, based on the latest default branch.
#      The default branch (main/master) is never checked out for the work; by
#      default each issue also runs in its own git worktree (a different folder)
#      so the shared checkout is left untouched (disable with --no-worktrees).
#   5. Run `copilot -p` (all tools, file access restricted to this repo),
#      passing the issue's comment thread so any prior Q&A is available. When
#      triage is enabled (TRIAGE_MODEL) the issue is first classified by that
#      cheap model as trivial/normal/complex and the coding model is picked from
#      TRIAGE_MAP, so cheap issues run on a cheap model; any failure falls back
#      to the global COPILOT_MODEL. That same cheap model also checks the issue
#      is specified well enough to implement: a genuinely vague one is asked a
#      clarifying question via the needs-info flow (6a) and gets no coding run
#      (asked at most once, biased toward proceeding). Unless quality assurance
#      is disabled (QUALITY_ASSURANCE=0 / --no-quality-assurance) the prompt also
#      asks Copilot to add tests for the work, written from the user's perspective.
#   5b. Right after the run, post what that prompt cost (the "AI Credits" and
#      "Tokens" summary Copilot prints at the end, taken from the run's log) as a
#      comment on the issue/PR, tagged with the hidden "copilot-loop:usage"
#      marker. This is best-effort: it is skipped when no stats were captured and
#      never fails the run. The same happens after the conflict-resolution run in
#      resolve_pr_conflicts, so every prompt's cost is tracked.
#   6a. If Copilot needs more information it writes a question file; post the
#       question as an issue comment, label the issue "needs-info", and wait for
#       the user to reply (no PR opened, not counted as a failure).
#   6b. Otherwise stage and commit the work (the commit message is written from
#       the staged diff by the cheapest model, COMMIT_MODEL, with a deterministic
#       fallback). The commit must succeed, so a commit failure fails the issue
#       loudly instead of silently opening an empty PR. Then sync the branch with
#       the latest default branch and, only if commits remain after the sync,
#       push and open a PR that closes the issue. When --auto-merge is on the PR
#       is set to merge automatically (GitHub auto-merge when the repo allows it,
#       otherwise merged immediately) so no manual review is required.
#   7. On success label the issue "copilot-done", then post a short "what was
#      done" summary comment on it, written from the run's session log by the
#      light SUMMARY_MODEL (default on; --no-summary disables it). On failure
#      label it "copilot-failed" and stop — failures are never retried
#      automatically. A later user reply on a failed issue resumes it for another
#      attempt.
#   8. Sweep merged branches: each pass removes any local work branch and worktree
#      whose PR has merged and, when the repo does not auto-delete on merge,
#      deletes the merged remote branch too (CLEANUP_MERGED / DELETE_REMOTE_BRANCH).
#      Only the loop's own branches are touched, never the default branch or a
#      branch with un-pushed work.
#   9. If no issues are found, sleep and repeat. While sleeping, press 'f' to
#      wake immediately and check for work.
#
# Requirements: git, gh (authenticated), copilot.
#
# Usage:
#   ./copilot-loop.sh [options]
#
# Options (each is also settable via the matching environment variable; when
# both are given the command-line flag wins):
#   --trigger-label <label>  Label that marks an issue as ready   (default: ready)
#   --plan-label <label>     Label that puts an issue into plan mode: Copilot
#                            drafts an implementation plan (no code changes) which
#                            is posted for review, then the issue waits for the
#                            trigger label to run the plan          (default: plan)
#   --sleep-minutes <n>      Idle sleep, minutes, when no work     (default: 5)
#   --repo-dir <dir>         Repository to operate in              (default: current git repo)
#   --model <model>          Model passed to copilot --model       (default: unset/auto)
#   --copilot-timeout <dur>  Wall-clock limit for each Copilot run (issue resolve,
#                            PR conflict/checks fix, default-branch sync) so a stuck
#                            run cannot block the loop. Accepts seconds or an
#                            s/m/h/d suffix (e.g. 1800, 30m, 2h); "0"/"off" disables
#                            it                                      (default: 30m)
#   --commit-model <model>   Model used to write the commit message from the
#                            staged diff; unset/"off" uses a deterministic
#                            "Resolve #<n>: <title>" message        (default: off)
#   --summary-model <model>  Light model that writes the "what was done" summary
#                            posted on each resolved issue; "auto"/"off" lets
#                            Copilot pick its default            (default: gpt-5-mini)
#   --triage-model <model>   Cheap model that classifies each issue as
#                            trivial/normal/complex before coding, so the coding
#                            model can be chosen per difficulty; unset/"off"
#                            disables triage (current behaviour)     (default: off)
#   --triage-map <map>       class=model pairs (comma-separated) mapping a triage
#                            class to the coding model, e.g.
#                            "trivial=gpt-5-mini,complex=claude-opus-4.5"; an
#                            unmapped class falls back to --model. Defaults to
#                            "trivial=<triage-model>" when triage is on and this
#                            is unset                                (default: unset)
#   --cost-saver             Preset that enables smart model routing with built-in
#                            defaults: a cheap model classifies each issue, then
#                            trivial->cheap, normal->mid, complex->--model (or a
#                            strong default). A convenience layer over triage; an
#                            explicit --triage-model/--triage-map overrides it
#                                                                     (default: off)
#   --triage-timeout-map <m> class=factor pairs (comma-separated) scaling the
#                            --copilot-timeout by triage difficulty, factor a
#                            percent of the baseline ("33%") or an absolute
#                            duration ("10m"); normal/unmapped keep the baseline
#                            and a disabled timeout stays disabled. Defaults to
#                            "trivial=33%,complex=200%" when triage is on;
#                            "off" keeps a flat timeout                (default: unset)
#   --agents-model <model>   Model for the one-time AGENTS.md bootstrap: when the
#                            repo has no AGENTS.md / copilot-instructions.md a
#                            read-only pass writes a short AGENTS.md and opens it as
#                            a PR. Runs once, so it defaults to a capable mid model;
#                            "off" disables it                 (default: claude-sonnet)
#   --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
#   --quiet                  Do not stream Copilot's output to stdout; write it
#                            only to the per-run log files (the original
#                            behaviour). By default the loop streams Copilot's
#                            output live to stdout as well as the log files.
#   --worktrees / --no-worktrees
#                            Give each issue its own git worktree, or work in the
#                            current checkout (default: on — every task uses a new
#                            worktree so parallel runs never conflict).
#   --auto-merge / --no-auto-merge
#                            Merge each PR automatically instead of leaving it for
#                            review (default: off).
#   --quality-assurance / --no-quality-assurance
#                            Ask Copilot to add tests (from the user's perspective)
#                            for the work it did on each issue; disable to save cost
#                            (default: on). --qa / --no-qa are accepted aliases.
#   --summary / --no-summary Post a "what was done" summary comment on each issue
#                            the loop resolves, by the light SUMMARY_MODEL; disable
#                            to save cost                          (default: on).
#   --auto-fix / --no-auto-fix
#                            When the loop itself crashes, report the crash to the
#                            bot-loop repo so it can be self-improving: file a
#                            trigger-labelled fix issue there when you can push,
#                            otherwise write a report and email the maintainer
#                            (default: on).
#   --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
#                            (default: merge).
#   --cleanup-merged / --no-cleanup-merged
#                            Sweep merged issue branches and worktrees each pass
#                            (default: on).
#   --delete-remote-branch / --no-delete-remote-branch
#                            Delete a merged issue's remote branch (default: auto,
#                            on only when the repo does not auto-delete on merge).
#   -h, --help               Show help and exit.
#   -V, --version            Print the copilot-loop version and exit.
#
# Environment variables (equivalent to the flags above):
#   TRIGGER_LABEL, PLAN_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COPILOT_TIMEOUT,
#   COMMIT_MODEL, TRIAGE_MODEL, TRIAGE_MAP, COST_SAVER, TRIAGE_TIMEOUT_MAP, AGENTS_MODEL, ISSUES_DIR,
#   SUMMARY_MODEL, REPORT_SUMMARY,
#   QUIET, USE_WORKTREES,
#   VERBOSE,
#   AUTO_MERGE, QUALITY_ASSURANCE, MERGE_METHOD, CLEANUP_MERGED, DELETE_REMOTE_BRANCH,
#   AUTO_FIX
# Plus BOT_LOOP_REPO / BOT_LOOP_EMAIL (env-only, no flag): the repo auto-fix files
# loop-crash reports against (default AlienEngineer/bot-loop) and the maintainer
# address it emails when you cannot push there (default aimirim.software@gmail.com).
# Plus SELF_UPDATE (env-only, no flag): set to 0 to stop the loop pulling the
# default branch and restarting when this script changes upstream (default:
# auto, on when the script is tracked in the repo it operates on).
# Plus SYNC_REMOTE (env-only, no flag): set to 0 to stop the loop syncing the
# local default branch with the remote before each pass; on by default (see the
# flow's step 0b — a diverged merge conflict is handed to Copilot to resolve).
# Plus MERGEABILITY_WAIT_ATTEMPTS / MERGEABILITY_WAIT_SECONDS (env-only): bound
# the wait for GitHub to finish computing PR mergeability before the conflict
# check, so a still-UNKNOWN (not yet evaluated) conflict is not skipped. Defaults
# 5 attempts, 3s apart; set MERGEABILITY_WAIT_ATTEMPTS=0 to disable the wait.
#
set -uo pipefail

# Version of this script. Reported by -V/--version and bumped automatically by
# .github/workflows/release.yml on every push to main (kept in step with the
# Homebrew formula and the TUI). Keep this on its own line: the release workflow
# rewrites it with sed.
COPILOT_LOOP_VERSION="0.1.21"

# Preserve the original invocation so self-update can re-exec the loop with the
# same options after pulling a newer copy of this script (see self_update).
SELF_ARGS=("$@")

# Resolve this script to an absolute, symlink-free path now, before any later cd
# changes the working directory. self_update() compares this file against its
# upstream copy and overwrites it in place, so it must point at the real tracked
# file even when invoked via a relative path or a symlink on PATH.
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
  _link="$(readlink "$SCRIPT_PATH")"
  case "$_link" in
    /*) SCRIPT_PATH="$_link" ;;
    *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$_link" ;;
  esac
done
SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/$(basename "$SCRIPT_PATH")"

# --- Configuration -----------------------------------------------------------
# Every option below can be supplied two ways: as an environment variable, or as
# a command-line flag (see --help / usage). A flag always overrides the matching
# environment variable, which overrides the built-in default. Read the raw env
# values here and fill in defaults after argument parsing, so a flag such as
# --repo-dir can still influence the derived paths (ISSUES_DIR, WORK_DIR, ...).
REPO_DIR="${REPO_DIR:-}"
TRIGGER_LABEL="${TRIGGER_LABEL:-}"
# Label that puts an issue into plan mode: instead of implementing it straight
# away the loop asks Copilot for an implementation plan (no code changes), posts
# it for review, and waits for the user to add the trigger label to run it. Read
# raw here; the default ("plan") is filled after argument parsing so --plan-label
# can override it (mirrors TRIGGER_LABEL).
PLAN_LABEL="${PLAN_LABEL:-}"
SLEEP_MINUTES="${SLEEP_MINUTES:-}"
COPILOT_MODEL="${COPILOT_MODEL:-}"
# Wall-clock limit for each main Copilot run so a stuck run can never block the
# loop. Read raw here; normalised (to a timeout(1) duration, or empty=disabled)
# after argument parsing so a flag can still override it. Default 30m; "0"/"off"
# disables it.
COPILOT_TIMEOUT="${COPILOT_TIMEOUT:-}"
# Model used *only* to write the commit message from the staged diff. Kept
# separate from COPILOT_MODEL so the coding model is never spent on a commit
# message. Off by default (deterministic message); set a model such as the cheap
# gpt-5-mini to have the message written from the diff, or "off" to force the
# deterministic fallback.
COMMIT_MODEL="${COMMIT_MODEL:-}"
# Light model that writes the "what was done" summary posted on an issue once the
# loop resolves it (issue #161/#217). Kept separate from the coding model so the
# summary stays cheap. Empty defaults to a built-in light model (gpt-5-mini) so a
# summary is posted with zero configuration; "off"/"none"/"0"/"auto" let Copilot
# pick its default model instead. Read raw here; resolved after argument parsing.
SUMMARY_MODEL="${SUMMARY_MODEL:-}"
# Optional cheap model used to CLASSIFY each issue as trivial/normal/complex
# before coding, so the expensive coding model is reserved for hard issues (the
# COMMIT_MODEL idea applied to routing). The same model also gates genuinely
# vague issues: when it decides an issue is too under-specified to implement
# confidently it asks the author a clarifying question (via the needs-info flow)
# and skips the coding run, asking at most once and biased toward proceeding.
# Empty/"off" disables triage and every issue runs on COPILOT_MODEL exactly as
# before.
TRIAGE_MODEL="${TRIAGE_MODEL:-}"
# Maps a difficulty class to the coding model, as comma-separated "class=model"
# pairs, e.g. "trivial=gpt-5-mini,complex=claude-opus-4.5". A class with no entry
# (or an empty value) falls back to COPILOT_MODEL. When triage is enabled but
# this is unset it defaults to routing trivial issues to TRIAGE_MODEL so turning
# triage on lowers cost with zero extra configuration.
TRIAGE_MAP="${TRIAGE_MAP:-}"
# Cost-saver preset (issue #186): a single switch that turns on smart model
# routing with sensible built-in defaults, so most users stop overpaying by
# running one (often expensive) model on every issue. When on it enables triage
# with a cheap classifier and a default class->model map (trivial->cheap,
# normal->mid, complex->the configured --model or a strong default). It is a
# convenience layer over TRIAGE_MODEL/TRIAGE_MAP: an explicit --triage-model or
# --triage-map always overrides it. Off by default; 1/true/yes/on turn it on.
COST_SAVER="${COST_SAVER:-}"
# Scales the per-run COPILOT_TIMEOUT by triage difficulty (issue #190), as
# comma-separated "class=factor" pairs where factor is a percentage of the
# baseline ("33%" or bare "33") or an absolute duration ("10m"). A "normal" or
# unlisted class keeps the baseline COPILOT_TIMEOUT; a disabled timeout stays
# disabled. Read raw here; when triage is enabled but this is unset it defaults
# to "trivial=33%,complex=200%" so a stuck trivial issue is killed sooner and a
# complex one gets more time. "off"/"none"/"0" keeps a flat timeout across classes.
TRIAGE_TIMEOUT_MAP="${TRIAGE_TIMEOUT_MAP:-}"
# AGENTS.md nor .github/copilot-instructions.md, a single read-only Copilot pass
# writes a short AGENTS.md (auto-loaded into every later run) and opens it as a
# PR. This runs once and is high-leverage, so it defaults to a capable mid model
# rather than the cheapest one. Read raw here; the default is filled after
# argument parsing so --agents-model can override it. "off"/"none"/"0" disables
# the bootstrap entirely.
AGENTS_MODEL="${AGENTS_MODEL:-}"
ISSUES_DIR="${ISSUES_DIR:-}"
# Stream Copilot's output live to stdout in addition to the per-run log files.
# Set QUIET=1 (or pass --quiet) to keep the original log-file-only behaviour.
QUIET="${QUIET:-}"
# Emit extra, loop-level narration (each pass's phases: sync, sweep, PR scans,
# queue scan, claim, sleep) via vlog(), so the output shows what the loop itself
# is doing and not only Copilot's transcript (#214). Off by default to keep the
# log quiet; set VERBOSE=1 or pass --verbose/-v to turn it on.
VERBOSE="${VERBOSE:-}"
# When non-empty, log() also appends its line to this per-run log file, so the
# loop's own narration (branch creation, "running copilot", PR push, ...) lands
# in the same issue-<n>/pr-<n> log as Copilot's transcript. The TUI's per-issue
# output panel reads that file, so it then shows the full run — matching what the
# bash loop prints to the terminal instead of "just the copilot output" (#126).
CURRENT_RUN_LOG=""
# Why the loop is exiting, set by die() and the signal traps so the EXIT trap's
# "shutting down" line can explain the cause instead of leaving the operator
# guessing (#214). Empty means an unexplained exit (e.g. an unbound-variable
# error under `set -u`), which cleanup() flags with the exit code.
SHUTDOWN_REASON=""
# Scratch paths shared with the subshell EXIT trap inside guard() (see the main
# loop). They must be plain globals, not locals: a `set -u` crash unwinds the
# erroring frame's caller-locals before the trap runs, so a local would read back
# as "unbound" there. Overwritten on every guarded call (the loop is serial).
# shellcheck disable=SC2034  # consumed only inside guard()'s trap string
_GUARD_ERR=""
# shellcheck disable=SC2034  # consumed only inside guard()'s trap string
_GUARD_CRASHED=""
# Set SELF_UPDATE=0 to stop the loop pulling and restarting itself when this
# script changes upstream. Left unset it is auto-enabled whenever the script is
# a tracked file inside the repo it operates on.
SELF_UPDATE="${SELF_UPDATE:-}"
# Set SYNC_REMOTE=0 to stop the loop syncing the local default branch with the
# remote before each pass. On by default; when the default branch has diverged
# and the merge conflicts, Copilot is asked to resolve it so the loop can move on.
SYNC_REMOTE="${SYNC_REMOTE:-}"
# Whether each issue gets its own git worktree instead of switching branches in
# the shared checkout. On by default so every task runs in a different folder;
# set to 0 (or pass --no-worktrees) to work in place. 1/true/yes/on force it on.
# The default branch (main/master) is never checked out for work in either mode.
USE_WORKTREES="${USE_WORKTREES:-}"
# Merge each PR automatically instead of leaving it open for review. Off by
# default; set AUTO_MERGE=1 (or pass --auto-merge) to turn it on.
AUTO_MERGE="${AUTO_MERGE:-}"
# Ask Copilot to add tests (from the user's perspective) for the work it did on
# each issue. On by default (issue #162); set QUALITY_ASSURANCE=0 (or pass
# --no-quality-assurance) to turn it off and save the extra cost.
QUALITY_ASSURANCE="${QUALITY_ASSURANCE:-}"
# Post an auto-generated "what was done" summary comment on an issue once the loop
# resolves it and opens its PR (issue #161/#217), written from the session log by
# the light SUMMARY_MODEL. On by default; set REPORT_SUMMARY=0 (or pass
# --no-summary) to turn it off and save the extra cost.
REPORT_SUMMARY="${REPORT_SUMMARY:-}"
# Self-improving loop (issue #218): when the loop ITSELF crashes — a guarded unit
# (issue/plan/PR-fix) exits unexpectedly, i.e. a bug in the loop, not a handled
# failure — report the crash upstream so it can be fixed. On by default; set
# AUTO_FIX=0 (or pass --no-auto-fix) to only log crashes and never report them.
AUTO_FIX="${AUTO_FIX:-}"
# The loop's own upstream repo. auto-fix files a trigger-labelled fix issue here
# when the user can push to it (the loop then fixes it into a PR); otherwise the
# report the user is asked to forward names this repo. Override it for a fork.
BOT_LOOP_REPO="${BOT_LOOP_REPO:-AlienEngineer/bot-loop}"
# Maintainer contact for the auto-fix report path (user cannot push to
# BOT_LOOP_REPO): the crash report names this address and the loop emails it when
# a mailer (mail/sendmail) is available.
BOT_LOOP_EMAIL="${BOT_LOOP_EMAIL:-aimirim.software@gmail.com}"
# Merge method used when AUTO_MERGE is on: merge, squash or rebase.
MERGE_METHOD="${MERGE_METHOD:-}"
# Delete the remote head branch of an issue once its PR merges. Empty means
# auto-detect (on only when the repository does not already delete branches on
# merge, so we complement GitHub's own cleanup instead of duplicating it); 1/0
# force it on/off.
DELETE_REMOTE_BRANCH="${DELETE_REMOTE_BRANCH:-}"
# Periodically remove local branches, worktrees and remote branches whose PR has
# merged. On by default; set to 0 (or pass --no-cleanup-merged) to disable.
CLEANUP_MERGED="${CLEANUP_MERGED:-}"
# GitHub computes a PR's mergeable state asynchronously, so just after a push or a
# base-branch move it reports UNKNOWN for a while. Before the per-iteration
# conflict check the loop waits for that computation to settle, so a PR that is
# really in conflict but not yet evaluated is not skipped. Env-only (no flag):
# MERGEABILITY_WAIT_ATTEMPTS bounds the wait (0 disables it), and
# MERGEABILITY_WAIT_SECONDS is the pause between polls.
MERGEABILITY_WAIT_ATTEMPTS="${MERGEABILITY_WAIT_ATTEMPTS:-}"
MERGEABILITY_WAIT_SECONDS="${MERGEABILITY_WAIT_SECONDS:-}"

INPROGRESS_LABEL="in-progress"
DONE_LABEL="copilot-done"
FAILED_LABEL="copilot-failed"
NEEDS_INFO_LABEL="needs-info"
# Marks an open issue held back because it declares a still-open dependency
# ("Wait for: #N"), so the wait is visible in GitHub. Reconciled every pass and
# removed once every dependency closes (or the issue is claimed for work).
PENDING_LABEL="pending"
# Marks an issue whose implementation plan has been generated and posted for the
# user to review (see PLAN_LABEL / plan_issue). The loop leaves the issue alone
# while it carries this label; the user adds the trigger label once happy with
# the plan to have the loop execute it, and the label is dropped when claimed.
PLAN_REVIEW_LABEL="plan-review"
# Marks a PR whose conflicts the loop tried and failed to resolve, so it is not
# retried forever. Remove it by hand to let the loop try again.
CONFLICT_UNRESOLVED_LABEL="conflict-unresolved"
# Marks a PR whose failing CI checks the loop tried and failed to fix, so it is
# not retried forever. Remove it by hand to let the loop try again.
CHECKS_UNRESOLVED_LABEL="checks-unresolved"

# Prefix of every work branch the loop creates ("copilot/<num>-<slug>"). Used to
# recognise the loop's own branches when cleaning up so a sweep never touches the
# default branch or a branch a human created.
BRANCH_PREFIX="copilot/"

# Hidden marker appended to comments the loop posts when asking the user a
# question, so they are easy to recognise in the thread.
QUESTION_MARKER="<!-- copilot-loop:needs-info -->"

# Hidden marker appended to every failure comment so they are easy to recognise
# in the thread (mirrors QUESTION_MARKER).
FAILURE_MARKER="<!-- copilot-loop:failed -->"

# Hidden marker appended to every per-run cost/usage comment so they are easy to
# recognise (and filter) in the thread (mirrors QUESTION_MARKER).
USAGE_MARKER="<!-- copilot-loop:usage -->"

# Hidden marker appended to the "what was done" summary comment the loop posts
# when it resolves an issue (#161/#217), so the summary is easy to recognise (and
# filter) in the thread and mirrors the TUI's own summary marker.
SUMMARY_MARKER="<!-- copilot-loop:summary -->"

# Hidden marker appended to the plan comment the loop posts in plan mode, so the
# execution pass can tell the issue was planned (and the plan approved) and hand
# Copilot the approved plan to follow (mirrors QUESTION_MARKER).
PLAN_MARKER="<!-- copilot-loop:plan -->"

# Hidden marker on every auto-fix issue/report the loop files about its OWN
# crashes (issue #218), so they are easy to recognise in a thread and de-dupe.
AUTO_FIX_MARKER="<!-- copilot-loop:auto-fix -->"

# --- Helpers -----------------------------------------------------------------
# Emit a timestamped status line to stdout. When CURRENT_RUN_LOG is set (during a
# per-issue or per-PR run) the same line is also appended to that run's log file,
# so the loop's narration is interleaved with Copilot's transcript there and the
# TUI's output panel shows the full run, not just Copilot's output (#126). The
# mirror is best-effort: a write failure never breaks the loop.
log() {
  local line
  line="$(printf '%s | %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$line"
  if [ -n "${CURRENT_RUN_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$CURRENT_RUN_LOG" 2>/dev/null || true
  fi
}

# Verbose narration: like log(), but only emits when VERBOSE=1, and tags the line
# so the extra loop-level detail is easy to spot (and filter). Lets the operator
# opt into "more detail" about what the loop itself is doing without changing the
# default output (#214).
vlog() {
  [ "${VERBOSE:-0}" = 1 ] || return 0
  log "· $*"
}

die() {
  # Record why the loop is exiting so the EXIT trap explains the shutdown
  # instead of printing a bare "shutting down" (#214).
  SHUTDOWN_REASON="fatal: $*"
  log "FATAL: $*"
  exit 1
}

# Guard that a flag which expects a value was actually given one. Call as:
#   need_arg $# "$1"
# where the first argument is the remaining arg count (the flag plus anything
# after it) and the second is the flag name used in the error message.
need_arg() {
  [ "$1" -ge 2 ] || die "option $2 requires a value"
}

# Ensure a label exists (ignore "already exists" errors).
ensure_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" >/dev/null 2>&1 || true
}

# >>> gh-host helpers >>>
# Echo the hostname embedded in a git remote URL, for both SSH and HTTPS forms:
#   https://bmw.ghe.com/unit/x.git    -> bmw.ghe.com
#   git@bmw.ghe.com:unit/x.git        -> bmw.ghe.com
#   ssh://git@code.connected.bmw/o/r  -> code.connected.bmw
# Empty output when no host can be parsed. Used to target `gh` calls that do NOT
# resolve a host from the repo (e.g. `gh api user`) at the host that actually
# owns this repo, so a machine logged in to several hosts (a personal github.com
# account plus one or more enterprise hosts) never resolves the wrong account.
_gh_host_from_url() {
  printf '%s' "$1" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/@]*@##; s#[/:].*$##'
}
# <<< gh-host helpers <<<

# >>> gh-auth helpers >>>
# True iff `gh` has a usable login for the host that owns $1 (an origin remote
# URL). Scoping is the whole point: unscoped `gh auth status` inspects *every*
# logged-in host and exits non-zero when ANY of them has a broken/expired token,
# so a stale login on an unrelated host (a second enterprise account, say) must
# not decide whether THIS repo's account is authenticated. Defaults to github.com
# when the URL carries no parseable host.
_gh_authenticated_for_origin() {
  local host
  host="$(_gh_host_from_url "${1-}")"
  gh auth status --hostname "${host:-github.com}" >/dev/null 2>&1
}
# <<< gh-auth helpers <<<

# >>> terminal-title helpers >>>
# Emit the OSC escape that sets a terminal's window/tab title to $1. Pure (writes
# only the sequence to stdout), so it can be unit tested.
terminal_title_seq() {
  printf '\033]0;%s\007' "$1"
}

# Make the branch being worked on visible on the terminal tab/window title.
# Inside tmux, rename the current window (shown as a tab on the status line);
# otherwise emit an OSC escape to the attached terminal. Best-effort: only
# touches a real terminal (stdout is a TTY) and never fails the caller.
set_terminal_title() {
  local title="$1"
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux rename-window "$title" 2>/dev/null || true
    return 0
  fi
  [ -t 1 ] || return 0
  terminal_title_seq "$title"
}
# <<< terminal-title helpers <<<

usage() {
  cat <<'EOF'
Usage: ./copilot-loop.sh [options]

Autonomous loop that resolves labelled GitHub issues with the Copilot CLI.

Options (each is also settable via the matching environment variable; when both
are given the command-line flag wins). "--flag value" and "--flag=value" both
work:
  --trigger-label <label>  Label that marks an issue as ready    (default: ready)
  --plan-label <label>     Label that puts an issue into plan mode: Copilot
                           proposes an implementation plan (no code changes)
                           which is posted for review, then the issue waits for
                           the trigger label to run the plan     (default: plan)
  --sleep-minutes <n>      Idle sleep, in minutes, when no work   (default: 5)
  --repo-dir <dir>         Repository to operate in               (default: current git repo)
  --model <model>          Model passed to copilot --model        (default: unset/auto)
  --copilot-timeout <dur>  Wall-clock limit for each Copilot run (issue resolve,
                           PR conflict/checks fix, default-branch sync) so a stuck
                           run cannot block the loop. Accepts seconds or an s/m/h/d
                           suffix (e.g. 1800, 30m, 2h); "0"/"off" disables it
                                                                    (default: 30m)
  --commit-model <model>   Model used to write the commit message from the
                           staged diff; unset/"off" uses a deterministic
                           "Resolve #<n>: <title>" message         (default: off)
  --summary-model <model>  Light model that writes the "what was done" summary
                           posted on each resolved issue; "auto"/"off" lets
                           Copilot pick its default              (default: gpt-5-mini)
  --triage-model <model>   Cheap model that classifies each issue as
                           trivial/normal/complex before coding so the coding
                           model can be chosen per difficulty, and asks the
                           author to clarify an issue too vague to implement;
                           unset/"off" disables triage (current behaviour)
                                                                    (default: off)
  --triage-map <map>       Comma-separated class=model pairs mapping a triage
                           class to the coding model, e.g.
                           "trivial=gpt-5-mini,complex=claude-opus-4.5". An
                           unmapped class falls back to --model; defaults to
                           "trivial=<triage-model>" when triage is on and this is
                           unset                                    (default: unset)
  --cost-saver             Cost-saver preset: enable smart model routing with
                           sensible built-in defaults instead of hand-writing a
                           triage map. A cheap model classifies each issue, then
                           trivial runs on that cheap model, normal on a mid
                           model, and complex on --model (or a strong default) so
                           spend tracks difficulty. Convenience layer over triage:
                           an explicit --triage-model/--triage-map overrides it
                                                                    (default: off)
  --triage-timeout-map <m> Comma-separated class=factor pairs scaling the
                           --copilot-timeout by triage difficulty, so a stuck
                           trivial issue is killed sooner and a complex one gets
                           more time. Factor is a percent of the baseline ("33%")
                           or an absolute duration ("10m"); "normal"/unmapped keep
                           the baseline and a disabled timeout stays disabled.
                           Defaults to "trivial=33%,complex=200%" when triage is
                           on; "off" keeps a flat timeout            (default: unset)
  --agents-model <model>   Model for the one-time AGENTS.md bootstrap. When the
                           repo has no AGENTS.md / copilot-instructions.md, a
                           read-only pass writes a short AGENTS.md and opens it as
                           a PR before issues run. Runs once so it defaults to a
                           capable mid model; "off" disables it
                                                          (default: claude-sonnet-4.5)
  --issues-dir <dir>       Folder scanned for issue markdown files (default: <repo>/issues)
  --quiet                  Do not stream Copilot's output to stdout; write it
                           only to the per-run log files (the original
                           behaviour). By default the loop streams Copilot's
                           output live to stdout as well as the log files.
  -v, --verbose            Emit extra loop-level narration (each pass's phases:
                           sync, sweep, PR scans, queue scan, claim, sleep) so
                           the output shows what the loop itself is doing, not
                           only Copilot's transcript. Default: off.
  --worktrees              Give every issue its own git worktree (never touch
                           the shared checkout). This is the default, so each
                           task always works in a different folder.
  --no-worktrees           Work in the current checkout instead of per-issue
                           worktrees. The default branch is still never checked
                           out for work; the issue branch is created directly.
  --auto-merge             Merge every PR automatically (GitHub auto-merge when
                           the repo allows it, otherwise an immediate merge) so
                           no manual review is needed. Default: off.
  --no-auto-merge          Leave PRs open for manual review (the default).
  --quality-assurance      Ask Copilot to add tests for the work it did on each
                           issue, written from the user's perspective (the
                           default). Alias: --qa.
  --no-quality-assurance   Skip the quality-assurance tests to save cost.
                           Alias: --no-qa.
  --summary                Post a "what was done" summary comment on each issue
                           the loop resolves, by the light SUMMARY_MODEL (the
                           default).
  --no-summary             Skip the per-issue close summary to save cost.
  --auto-fix               Self-improving loop: when the loop ITSELF crashes,
                           report the crash to the bot-loop repo so it can be
                           fixed. When you can push to that repo a trigger-
                           labelled fix issue is filed (the loop resolves it into
                           a PR); otherwise a local report is written and emailed
                           to the maintainer. This is the default.
  --no-auto-fix            Only log loop crashes; never report them upstream.
  --merge-method <method>  Merge method for auto-merge: merge, squash or rebase
                           (default: merge).
  --cleanup-merged         Sweep merged issue branches and worktrees each pass
                           (the default).
  --no-cleanup-merged      Leave merged branches and worktrees in place.
  --delete-remote-branch   Delete a merged issue's remote branch. Default: auto —
                           on only when the repository does not already delete
                           head branches on merge.
  --no-delete-remote-branch
                           Never delete remote branches; leave that to GitHub.
  -h, --help               Show this help and exit.
  -V, --version            Print the copilot-loop version and exit.

Environment variables (equivalent to the flags above):
  TRIGGER_LABEL, PLAN_LABEL, SLEEP_MINUTES, REPO_DIR, COPILOT_MODEL, COPILOT_TIMEOUT,
  COMMIT_MODEL, TRIAGE_MODEL, TRIAGE_MAP, COST_SAVER, TRIAGE_TIMEOUT_MAP, AGENTS_MODEL, ISSUES_DIR,
  SUMMARY_MODEL, REPORT_SUMMARY,
  QUIET, USE_WORKTREES,
  VERBOSE,
  AUTO_MERGE, QUALITY_ASSURANCE, MERGE_METHOD, CLEANUP_MERGED, DELETE_REMOTE_BRANCH,
  AUTO_FIX, BOT_LOOP_REPO, BOT_LOOP_EMAIL
EOF
}

# Run copilot with the given args, always capturing output to $log_file. Unless
# QUIET is set, the output is also streamed live to stdout via tee. When
# COPILOT_TIMEOUT is set the run is time-boxed through _run_with_timeout, so a
# stuck run can never block the loop; on expiry COPILOT_RC is 124 (per timeout(1))
# and the caller treats it as a failed attempt. Sets the global COPILOT_RC to
# copilot's own exit code (not tee's).
run_copilot() {
  local log_file="$1"; shift
  local -a _timeout_guard=()
  [ -n "${COPILOT_TIMEOUT:-}" ] && _timeout_guard=(_run_with_timeout "$COPILOT_TIMEOUT")
  if [ "$QUIET" = 1 ]; then
    ${_timeout_guard[@]+"${_timeout_guard[@]}"} copilot "$@" >>"$log_file" 2>&1
    COPILOT_RC=$?
  else
    ${_timeout_guard[@]+"${_timeout_guard[@]}"} copilot "$@" 2>&1 | tee -a "$log_file"
    COPILOT_RC="${PIPESTATUS[0]}"
  fi
}

# >>> usage helpers >>>
# Extract the per-run cost/usage summary Copilot prints at the end of a run from
# its captured output (read on stdin). Copilot ends a run with lines like:
#     AI Credits 25.7 (8s)
#     Tokens     ↑ 40.2k (40.2k written) • ↓ 221 (217 reasoning)
# Echoes the LAST "AI Credits" (or legacy "Premium requests") line followed by
# the LAST "Tokens" line, each with indentation and any trailing CR/space
# stripped, as one multi-line summary. Taking the LAST occurrence ignores an
# earlier triage run's stats captured in the same log. Echoes nothing when
# neither line is present. Pure: reads only stdin, writes only stdout.
parse_usage_stats() {
  local input credits tokens
  input="$(cat)"
  credits="$(printf '%s\n' "$input" | sed 's/\r$//' \
    | grep -E '^[[:space:]]*(AI Credits|Premium requests)[[:space:]]' \
    | tail -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  tokens="$(printf '%s\n' "$input" | sed 's/\r$//' \
    | grep -E '^[[:space:]]*Tokens[[:space:]]' \
    | tail -n1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -n "$credits" ] && [ -n "$tokens" ]; then
    printf '%s\n%s\n' "$credits" "$tokens"
  elif [ -n "$credits" ]; then
    printf '%s\n' "$credits"
  elif [ -n "$tokens" ]; then
    printf '%s\n' "$tokens"
  fi
}

# Build the header line for a usage comment, always naming the model used so
# every issue/PR records which model resolved it (#208). An empty model means
# Copilot's default was used, reported as "auto" (mirrors the TUI's label).
# Pure: no I/O, echoes the header on stdout.
_usage_header() {
  local model="${1:-}"
  [ -n "$model" ] || model="auto"
  printf '**copilot-loop usage** (model: %s)' "$model"
}
# <<< usage helpers <<<

# >>> summary helpers >>>
# Pure helpers for the "what was done" summary the loop posts on an issue once it
# resolves it (#161/#217). Extracted verbatim by tests/close-summary.test.sh
# between these markers, so keep the marker comments intact. They mirror the TUI's
# own summary code (tui/src/reporter.rs, tui/src/github.rs, tui/src/models.rs) so
# both surfaces post the same kind of comment with the same defaults.

# The built-in light model the summary uses when SUMMARY_MODEL is unset, so a
# summary is posted cheaply with zero configuration (mirrors the TUI's
# DEFAULT_SUMMARY_MODEL).
DEFAULT_SUMMARY_MODEL="gpt-5-mini"

# Decide whether the close summary is on from a raw config value. On by default
# (issue #161 asked for it on by default), so only the explicit falsy spellings
# turn it off; anything else -- including unset/empty -- is on. Echoes 1/0.
summary_enabled() {
  case "$1" in
    0|false|no|off|disable|disabled) printf '0\n' ;;
    *)                               printf '1\n' ;;
  esac
}

# Resolve the light summary model from a raw SUMMARY_MODEL value. Empty falls back
# to the built-in DEFAULT_SUMMARY_MODEL so the summary stays cheap by default;
# "auto"/"off"/"none"/"0" (case-insensitive) echo nothing so Copilot picks its
# own default; any other value is used verbatim (trimmed). Mirrors the TUI's
# resolve_summary_model. Pure: echoes the model on stdout.
resolve_summary_model() {
  local raw trimmed lower
  raw="${1:-}"
  trimmed="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  lower="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    '')                 printf '%s' "$DEFAULT_SUMMARY_MODEL" ;;
    auto|off|none|0)    : ;;
    *)                  printf '%s' "$trimmed" ;;
  esac
}

# Build the header line for the summary comment, naming which model wrote it so
# every summary records its (cheap) model, "auto" when Copilot's default was used.
# Mirrors the TUI's summary header. Pure: echoes the header on stdout.
_summary_header() {
  local model="${1:-}"
  [ -n "$model" ] || model="auto"
  # shellcheck disable=SC2016  # backticks/%s are literal printf format, not expansions
  printf '🤖 **Closing summary** — what the loop did, per its session (model: `%s`).' "$model"
}

# Build the prompt asking the light model to summarize the work done on an issue
# from its session-log tail. Mirrors the TUI's summary_prompt. Pure: reads its
# arguments, echoes the prompt on stdout.
build_summary_prompt() {
  local num="$1" title="$2" context="$3"
  cat <<EOF
You are writing a closing comment for GitHub issue #${num} ("${title}").
Below is the tail of the autonomous coding agent's session log for this issue — its own narration (branch, PR) interleaved with the Copilot transcript.
From it, summarize what was actually done to resolve the issue: the key changes and the outcome (e.g. the PR that was raised or merged).
Reply with ONLY the summary in GitHub-flavoured Markdown — a short paragraph or a few bullet points. No preamble, no headings, and do not wrap the whole reply in code fences.

--- session log ---
${context}
EOF
}

# Tidy a model's summary reply (read on stdin) for posting: drop a leading/trailing
# run of code-fence lines (models sometimes wrap the whole answer), trim blank
# edges, and cap the length so a runaway reply cannot post a wall of text. Mirrors
# the TUI's clean_summary. Pure: reads only stdin, writes only stdout.
clean_summary() {
  local text
  text="$(cat)"
  text="$(printf '%s' "$text" | awk '
    { lines[NR] = $0 }
    END {
      s = 1; e = NR
      while (s <= e) { t = lines[s]; sub(/^[[:space:]]+/, "", t); if (t ~ /^```/) s++; else break }
      while (e >= s) { t = lines[e]; sub(/^[[:space:]]+/, "", t); if (t ~ /^```/) e--; else break }
      while (s <= e && lines[s] ~ /^[[:space:]]*$/) s++
      while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print lines[i]
    }')"
  printf '%s' "${text:0:4000}"
}

# Assemble the summary comment body posted on the issue: the header naming the
# model, the summary itself, and a hidden marker so the comment is easy to spot
# and filter. The marker is passed in (the loop passes $SUMMARY_MARKER) so this
# stays pure and self-contained. Pure: echoes the body on stdout.
build_summary_comment() {
  local summary="$1" model="$2" marker="$3" header
  header="$(_summary_header "$model")"
  printf '%s\n\n%s\n\n%s' "$header" "$summary" "$marker"
}
# <<< summary helpers <<<

# Post the per-run cost/usage summary Copilot printed (parsed out of $log_file)
# as a comment on the issue or PR, tagged with USAGE_MARKER so it is easy to spot
# and filter in the thread. The header always records which model resolved the
# run ("auto" when none was pinned, #208). Skips silently when the log held no
# usage stats, and never fails the loop (every failure is swallowed) so cost
# tracking can never block or break a run.
# Usage: _report_usage <issue|pr> <num> <log_file> <model>
_report_usage() {
  local kind="$1" num="$2" log_file="$3" model="${4:-}" summary header body
  [ -f "$log_file" ] || return 0
  summary="$(parse_usage_stats <"$log_file" 2>/dev/null)"
  [ -n "$summary" ] || return 0
  header="$(_usage_header "$model")"
  # shellcheck disable=SC2016  # backticks/%s are literal printf format, not expansions
  body="$(printf '%s\n\n```\n%s\n```\n\n%s' "$header" "$summary" "$USAGE_MARKER")"
  case "$kind" in
    pr) gh pr comment "$num" --body "$body" >/dev/null 2>&1 || true ;;
    *)  gh issue comment "$num" --body "$body" >/dev/null 2>&1 || true ;;
  esac
  return 0
}

# >>> summary report helpers >>>
# Ask the light SUMMARY_MODEL to write a short "what was done" summary for issue
# $num from its session log ($log_file), mirroring the TUI's summarize_session.
# Only a bounded, ANSI-stripped tail of the log is sent to the model (no tools, no
# repo access), and the call is time-boxed so a hung model can never stall the
# loop. Echoes the tidied summary, or nothing when the log is missing/empty or the
# model fails so the caller simply posts no summary. Never fails.
# Usage: build_issue_summary <num> <title> <log_file> <model>
build_issue_summary() {
  local num="$1" title="$2" log_file="$3" model="${4:-}" context prompt msg esc
  [ -f "$log_file" ] || return 0

  # Feed the model only the tail of the log (capped like the TUI's 16 KiB context),
  # with colour/CSI escape sequences and stray control characters stripped so the
  # transcript reads cleanly and no spinner noise wastes the prompt. The ESC byte
  # is built with printf so the strip works on both GNU and BSD sed; the tr range
  # removes any remaining control bytes (including a lone ESC) but keeps TAB/LF.
  esc="$(printf '\033')"
  context="$(tail -c 16384 "$log_file" 2>/dev/null \
             | LC_ALL=C sed "s/${esc}\\[[0-9;?]*[A-Za-z]//g" \
             | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  [ -n "${context//[[:space:]]/}" ] || return 0

  prompt="$(build_summary_prompt "$num" "$title" "$context")"

  # Light model, no color/logs, time-boxed; discard stderr so provider noise can
  # never leak into the summary. An optional --model (empty means Copilot picks).
  local -a args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
  [ -n "$model" ] && args+=(--model "$model")
  msg="$(_run_with_timeout 120 copilot "${args[@]}" 2>/dev/null | clean_summary)"

  [ -n "$msg" ] && printf '%s' "$msg"
  return 0
}

# Post the "what was done" summary on the issue the loop just resolved (#161/#217),
# tagged with SUMMARY_MARKER so it is easy to spot and filter. Skips silently when
# the feature is off (REPORT_SUMMARY=0) or the model produced nothing, and never
# fails the loop (every failure is swallowed) so summarising can never block or
# break a run — the issue is already resolved.
# Usage: _report_summary <num> <title> <log_file> <model>
_report_summary() {
  local num="$1" title="$2" log_file="$3" model="${4:-}" summary body
  [ "${REPORT_SUMMARY:-1}" = 1 ] || return 0
  [ -f "$log_file" ] || return 0
  summary="$(build_issue_summary "$num" "$title" "$log_file" "$model")"
  [ -n "$summary" ] || return 0
  body="$(build_summary_comment "$summary" "$model" "$SUMMARY_MARKER")"
  gh issue comment "$num" --body "$body" >/dev/null 2>&1 || true
  return 0
}
# <<< summary report helpers <<<

# Run a command with a wall-clock limit when a timeout utility is available so a
# hung helper (e.g. the commit-message model) can never stall the whole loop.
# Uses timeout/gtimeout if present, otherwise runs the command unguarded. Passes
# through the command's exit status (124 on timeout, per timeout(1)).
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# --- Copilot run timeout -----------------------------------------------------
# Pure helpers that normalise the COPILOT_TIMEOUT setting and detect a timed-out
# run. Extracted between the markers by tests/timeout.test.sh, so keep the marker
# comments intact.
# >>> copilot-timeout helpers >>>
# True (rc 0) when a COPILOT_TIMEOUT spec means "no timeout": an empty value, one
# of the disable words (off/none/false/no/disable/disabled), or a zero-magnitude
# duration (0, 0s, 0m, 0h, 0d). Case- and whitespace-insensitive. Anything else (a
# real duration, or garbage) returns rc 1. Pure: reads only $1.
copilot_timeout_disabled() {
  local raw num
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$raw" in
    ''|off|none|false|no|disable|disabled) return 0 ;;
    *[!0-9smhd]*)                          return 1 ;;
  esac
  num="${raw%[smhd]}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$num))" -eq 0 ] 2>/dev/null && return 0
  return 1
}

# Echo a duration usable by timeout(1) for a COPILOT_TIMEOUT spec, or nothing when
# the spec is not a valid duration. Accepts bare seconds ("1800") or an integer
# with a single s/m/h/d suffix ("30m", "2h"). Case- and whitespace-insensitive.
# Pure: reads only $1; callers treat empty output as "unparseable".
normalize_copilot_timeout() {
  local raw num
  raw="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$raw" in
    ''|*[!0-9smhd]*) return 0 ;;
  esac
  num="${raw%[smhd]}"
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$raw"
}

# True (rc 0) when a run guarded by COPILOT_TIMEOUT was killed for exceeding it:
# timeout(1) exits 124 on expiry, so treat that code as a timeout only when a
# timeout was actually in force ($1, the effective spec, is non-empty). Pure:
# reads $1 (spec) and $2 (exit code).
copilot_run_timed_out() {
  [ -n "${1:-}" ] || return 1
  [ "${2:-}" = "124" ]
}

# Convert a normalized COPILOT_TIMEOUT spec (bare integer seconds, or an integer
# with a single s/m/h/d suffix) to whole seconds. Echoes the seconds, or nothing
# when the spec is not a recognised duration. Pure: reads only $1.
_copilot_timeout_to_secs() {
  local spec num unit
  spec="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$spec" in ''|*[!0-9smhd]*) return 0 ;; esac
  num="${spec%[smhd]}"
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  unit="${spec#"$num"}"
  case "$unit" in
    ''|s) printf '%s' "$((10#$num))" ;;
    m)    printf '%s' "$((10#$num * 60))" ;;
    h)    printf '%s' "$((10#$num * 3600))" ;;
    d)    printf '%s' "$((10#$num * 86400))" ;;
  esac
}

# Format a whole-seconds count as a timeout(1)-valid, readable spec: whole minutes
# ("45m") when evenly divisible by 60, otherwise seconds ("594s"). Pure: reads $1.
_copilot_timeout_fmt_secs() {
  local s="${1:-0}"
  if [ "$s" -ge 60 ] && [ "$((s % 60))" -eq 0 ]; then
    printf '%sm' "$((s / 60))"
  else
    printf '%ss' "$s"
  fi
}

# Scale a baseline COPILOT_TIMEOUT spec ($1) by a per-difficulty factor ($2) so a
# trivial issue is killed sooner and a complex one gets more time (issue #190).
# The factor is either a percentage of the baseline (a bare integer "33" or "33%")
# or an absolute timeout(1) duration ("10m", "45m", "1800s"). Echoes the resulting
# timeout(1) spec:
#   - baseline empty (timeout disabled) -> empty, so a disabled timeout stays off
#     regardless of triage ("0"/"off" always wins);
#   - factor empty, "100"/"100%", or unparseable -> the baseline unchanged;
#   - percentage -> baseline_seconds * pct / 100, clamped to >=1s and formatted;
#   - absolute duration -> that duration, normalised.
# Pure: reads $1 (baseline) and $2 (factor) only; depends only on the helpers in
# this block. Never fails: an unusable factor falls back to the baseline.
scale_copilot_timeout() {
  local base="$1" factor pct base_secs secs abs
  factor="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  # A disabled baseline stays disabled: triage can never re-enable a timeout the
  # user turned off entirely.
  [ -n "$base" ] || return 0
  # No factor configured for this class -> keep the baseline.
  [ -n "$factor" ] || { printf '%s' "$base"; return 0; }

  case "$factor" in
    *%)      pct="${factor%\%}" ;;                 # explicit percentage: "33%"
    *[smhd]) # ends in a duration unit -> treat as an absolute override
             abs="$(normalize_copilot_timeout "$factor")"
             printf '%s' "${abs:-$base}"; return 0 ;;
    *)       pct="$factor" ;;                      # bare integer -> percentage
  esac

  # Validate the percentage; anything non-numeric or 0/100 keeps the baseline.
  case "$pct" in ''|*[!0-9]*) printf '%s' "$base"; return 0 ;; esac
  pct="$((10#$pct))"
  { [ "$pct" -eq 0 ] || [ "$pct" -eq 100 ]; } && { printf '%s' "$base"; return 0; }

  base_secs="$(_copilot_timeout_to_secs "$base")"
  case "$base_secs" in ''|*[!0-9]*) printf '%s' "$base"; return 0 ;; esac
  secs="$(( base_secs * pct / 100 ))"
  [ "$secs" -lt 1 ] && secs=1
  _copilot_timeout_fmt_secs "$secs"
}
# <<< copilot-timeout helpers <<<

# Echo a commit message for the staged changes in WORKSPACE_DIR. Tries to have
# the cheapest model (COMMIT_MODEL) summarise the staged diff, and always falls
# back to a deterministic "Resolve #<n>: <title>" so a missing, disabled, slow or
# failing model never blocks the commit. Only the diff is sent to the model (no
# tools, no repo access needed), and the call is time-boxed. Never fails.
build_commit_message() {
  local num="$1" title="$2"
  local fallback="Resolve #${num}: ${title}"
  local diff prompt msg

  # Model generation disabled -> deterministic message.
  [ -n "$COMMIT_MODEL" ] || { printf '%s' "$fallback"; return 0; }

  # Feed the model a bounded view of the staged diff (name-status + patch),
  # capped so a huge change set cannot blow up the prompt or the cost.
  diff="$(git -C "$WORKSPACE_DIR" diff --cached --stat 2>/dev/null)"$'\n\n'"$(git -C "$WORKSPACE_DIR" diff --cached 2>/dev/null | head -c 12000)"
  [ -n "${diff// /}" ] || { printf '%s' "$fallback"; return 0; }

  prompt="$(cat <<EOF
Write a git commit message for the staged changes below, which resolve GitHub issue #${num} ("${title}").
Reply with ONLY the commit message and nothing else: a single subject line of at most 72 characters in the imperative mood, optionally followed by a blank line and a short body. Do not wrap it in code fences or add any preamble.

${diff}
EOF
)"

  # Cheapest model, no tools, no color/logs; time-boxed. Discard stderr so any
  # provider noise cannot leak into the message. Fall back on any failure.
  msg="$(cd "$WORKSPACE_DIR" 2>/dev/null \
         && _run_with_timeout 120 copilot -p "$prompt" \
              --model "$COMMIT_MODEL" --allow-all-tools --no-color --log-level none 2>/dev/null)"
  # Trim leading/trailing blank lines and strip stray surrounding code fences.
  msg="$(printf '%s\n' "$msg" | sed -e 's/^```.*$//' -e '/^[[:space:]]*$/d' | head -c 500)"

  if [ -n "$msg" ]; then
    printf '%s' "$msg"
  else
    printf '%s' "$fallback"
  fi
}

# --- Triage: pick the coding model per issue difficulty ----------------------
# normalize_triage_class and parse_triage_map are pure and covered by
# tests/triage.test.sh (extracted between the markers), so keep the marker
# comments intact.
# >>> triage helpers >>>
# Normalize a raw difficulty answer (possibly multi-word, mixed case, punctuated,
# or using a synonym) to one canonical class: trivial, normal, or complex. Echoes
# the class, or nothing when no known keyword is present so the caller can fall
# back to the default model.
normalize_triage_class() {
  local raw="$1" word
  word="$(printf '%s' "$raw" \
          | tr '[:upper:]' '[:lower:]' \
          | grep -oE 'trivial|simple|easy|complex|complicated|hard|difficult|normal|medium|moderate|standard' \
          | head -n1)"
  case "$word" in
    trivial|simple|easy)                printf 'trivial\n' ;;
    complex|complicated|hard|difficult) printf 'complex\n' ;;
    normal|medium|moderate|standard)    printf 'normal\n' ;;
    *)                                  return 0 ;;
  esac
}

# Look up the coding model for a difficulty class in a TRIAGE_MAP string of
# comma-separated "class=model" pairs (e.g. "trivial=gpt-5-mini, complex=o1").
# Class keys match case-insensitively; the model value is echoed verbatim (model
# ids are case-sensitive) with surrounding whitespace trimmed. The first entry
# for a class wins. Echoes nothing when the class is absent or its value is
# empty, so the caller falls back to the global default model.
# Usage: parse_triage_map <map> <class>
parse_triage_map() {
  local map="$1" class="$2" lc_class pair key val
  lc_class="$(printf '%s' "$class" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r pair; do
    case "$pair" in *=*) ;; *) continue ;; esac
    key="$(printf '%s' "${pair%%=*}" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    val="$(printf '%s' "${pair#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ "$key" = "$lc_class" ]; then
      [ -n "$val" ] && printf '%s\n' "$val"
      return 0
    fi
  done < <(printf '%s\n' "$map" | tr ',' '\n')
  return 0
}
# <<< triage helpers <<<

# --- Cost-saver preset: one flag turns on smart model routing ----------------
# cost_saver_enabled, cost_saver_triage_model and cost_saver_triage_map are pure
# and covered by tests/cost-saver.test.sh (extracted between the markers), so
# keep the marker comments intact.
# >>> cost-saver helpers >>>
# Built-in models the cost-saver preset routes to when the user supplies no
# triage model/map of their own. Kept inside the marker block so the tests pin
# the exact defaults a user gets from the preset alone.
COST_SAVER_CHEAP_MODEL="gpt-5-mini"        # classify + trivial issues
COST_SAVER_MID_MODEL="claude-sonnet-4.5"   # normal issues
COST_SAVER_STRONG_MODEL="claude-opus-4.5"  # complex issues when --model is unset

# Whether the cost-saver preset is switched on. Accepts the usual truthy
# spellings; anything else (including unset/empty) is off. Reports via exit
# status.
cost_saver_enabled() {
  case "${1:-}" in
    1|true|yes|on) return 0 ;;
    *)             return 1 ;;
  esac
}

# Resolve the triage model under the preset. The preset only fills in the cheap
# default when it is on AND the user gave no --triage-model/TRIAGE_MODEL, so an
# explicit triage model (or an explicit "off") always wins. Echoes the model.
# Usage: cost_saver_triage_model <cost_saver> <current_triage_model>
cost_saver_triage_model() {
  local on="$1" current="$2"
  if cost_saver_enabled "$on" && [ -z "$current" ]; then
    printf '%s\n' "$COST_SAVER_CHEAP_MODEL"
  else
    printf '%s\n' "$current"
  fi
}

# Resolve the triage map under the preset. Only fills in the built-in
# trivial/normal/complex routing when the preset is on AND the user supplied
# neither a --triage-map nor a --triage-model, so any explicit triage
# configuration (a custom map, a custom classifier, or an explicit "off") always
# wins: an explicit map is used verbatim, and an explicit model keeps the
# existing "trivial=<model>" default instead of the preset's map. Complex routes
# to the configured coding model when one is set, otherwise to a strong built-in
# default, so hard issues escalate rather than dropping to "auto". Echoes the map.
# Usage: cost_saver_triage_map <cost_saver> <current_map> <current_triage_model> <copilot_model>
cost_saver_triage_map() {
  local on="$1" current="$2" tmodel="$3" model="$4" complex
  if cost_saver_enabled "$on" && [ -z "$current" ] && [ -z "$tmodel" ]; then
    complex="${model:-$COST_SAVER_STRONG_MODEL}"
    printf 'trivial=%s,normal=%s,complex=%s\n' \
      "$COST_SAVER_CHEAP_MODEL" "$COST_SAVER_MID_MODEL" "$complex"
  else
    printf '%s\n' "$current"
  fi
}
# <<< cost-saver helpers <<<

# --- Vagueness triage: ask before coding an under-specified issue ------------
# comments_have_question and parse_vague_question are pure and covered by
# tests/vague-triage.test.sh (extracted between the markers), so keep the marker
# comments intact.
# >>> vagueness helpers >>>
# Whether an issue's comment thread already carries a question the loop posted
# (the hidden QUESTION_MARKER string), i.e. we have already asked the author for
# more information at least once. Used to ask at most once: the vagueness gate is
# skipped when this is true, so an author's reply resumes the issue best-effort
# instead of being asked again. Pure (reads the comments string on $1).
comments_have_question() {
  case "$1" in
    *"<!-- copilot-loop:needs-info -->"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse the clarity verdict the cheap triage model returns into the clarifying
# question to ask, or nothing when the issue should proceed to coding. Biased
# toward proceeding: only an explicit "VAGUE" verdict (the first non-blank line)
# followed by a non-empty question asks; a "CLEAR" verdict, an empty answer, or
# any unrecognised text all proceed. Echoes the question (possibly multi-line),
# or nothing. Pure (reads only $1).
parse_vague_question() {
  local raw="$1" body first q
  # Drop leading blank lines so the verdict keyword is the first thing seen.
  body="$(printf '%s' "$raw" | sed -e '/[^[:space:]]/,$!d')"
  first="$(printf '%s\n' "$body" | head -n1 | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//')"
  case "$first" in
    vague*)
      # Strip the leading VAGUE token (and an optional :/-/. separator) from the
      # first line; the rest of that line plus any following lines is the question.
      q="$(printf '%s' "$body" | sed -E '1s/^[[:space:]]*[Vv][Aa][Gg][Uu][Ee][[:space:]]*[:.-]?[[:space:]]*//')"
      # Drop any blank lines the strip left at the front; the trailing newlines
      # are removed by the command substitution below.
      q="$(printf '%s' "$q" | sed -e '/[^[:space:]]/,$!d')"
      [ -n "$q" ] && printf '%s' "$q"
      ;;
    *) return 0 ;;
  esac
}
# <<< vagueness helpers <<<

# >>> quality-assurance helpers >>>
# Decide whether quality assurance is on from a raw config value. QA is ON by
# default (issue #162 asked for it to run by default), so only the explicit falsy
# spellings turn it off; anything else -- including unset/empty -- is on. Echoes
# 1 (on) or 0 (off).
qa_enabled() {
  case "$1" in
    0|false|no|off|disable|disabled) printf '0\n' ;;
    *)                               printf '1\n' ;;
  esac
}

# The quality-assurance instruction appended to the issue prompt so Copilot adds
# tests covering the work it just did. Tests are asked for from the user's
# perspective (observable behaviour/outcomes), dropping to technical/unit tests
# only when a user-level test is impractical or makes no sense. Echoes the
# instruction paragraph when enabled ("1"), or nothing when disabled so the
# prompt is left unchanged.
qa_instruction() {
  [ "${1:-1}" = 1 ] || return 0
  cat <<'EOF'
Quality assurance: after implementing the change, add automated tests that cover
everything you did. Write the tests from the perspective of the user -- exercise
the behaviour and outcomes a user would observe, not internal implementation
details. Only fall back to technical/unit tests when testing from the user's
perspective is too complex or does not make sense for the change. Use the
project's existing test framework and conventions, and run the tests to verify
they pass.
EOF
}
# <<< quality-assurance helpers <<<

# Classify an issue's difficulty with the cheap TRIAGE_MODEL so the coding model
# can be chosen per difficulty (see parse_triage_map / TRIAGE_MAP). Echoes one
# normalized class (trivial|normal|complex) on success, or nothing when triage is
# disabled, the model is unavailable, times out, or its answer is unrecognised --
# the caller then falls back to the global model. Only the issue text is sent (no
# repo access needed) and the call is time-boxed, so triage can never block or
# fail the loop. Never returns non-zero.
triage_issue() {
  local num="$1" title="$2" body="$3" log_file="${4:-/dev/null}"
  local prompt raw class capped

  [ -n "$TRIAGE_MODEL" ] || return 0

  # Cap the body so a huge issue cannot blow up the triage prompt or its cost;
  # the difficulty is clear from the opening description.
  capped="$(printf '%s' "$body" | head -c 4000)"

  prompt="$(cat <<EOF
Classify the difficulty of this software task for an autonomous coding agent.
Answer with ONE word only, no punctuation or explanation, exactly one of:
  trivial - a tiny, low-risk change (typo, doc tweak, one-line or config fix)
  normal  - an average change with clear scope touching a few files
  complex - a large, ambiguous, or cross-cutting change needing careful design

Issue #${num}: ${title}

${capped}
EOF
)"

  # Cheapest model, no color/logs; time-boxed. Pin to the issue workspace (when
  # one exists) so triage never runs against the shared checkout. Append provider
  # noise to the log for debugging but keep stdout to just the class. Fall back
  # on any failure.
  local -a _ws_args=()
  [ -n "${WORKSPACE_DIR:-}" ] && _ws_args=(-C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR")
  raw="$(_run_with_timeout 60 copilot -p "$prompt" \
           ${_ws_args[@]+"${_ws_args[@]}"} \
           --model "$TRIAGE_MODEL" --allow-all-tools --no-color --log-level none 2>>"$log_file")"
  class="$(normalize_triage_class "$raw")"
  [ -n "$class" ] && printf '%s' "$class"
  return 0
}

# Judge with the cheap TRIAGE_MODEL whether an issue is specified well enough for
# an autonomous coding agent to implement confidently. Echoes the clarifying
# question(s) to ask when the issue is genuinely too vague, or nothing when it is
# clear enough to proceed (see parse_vague_question). Biased toward proceeding so
# it rarely stalls the backlog. Mirrors triage_issue: only the issue text is sent
# (no repo access needed), the call is time-boxed and pinned to the issue
# workspace, and every failure/timeout/unrecognised answer falls back to
# proceeding, so the check can never block or fail the loop. Never returns
# non-zero. Extracted verbatim by tests/vague-triage.test.sh -- keep the markers.
# >>> triage-vagueness helper >>>
triage_vagueness() {
  local num="$1" title="$2" body="$3" log_file="${4:-/dev/null}"
  local prompt raw capped question

  [ -n "$TRIAGE_MODEL" ] || return 0

  # Cap the body like triage_issue so a huge issue cannot blow up the prompt/cost.
  capped="$(printf '%s' "$body" | head -c 4000)"

  prompt="$(cat <<EOF
You are triaging a GitHub issue for an autonomous coding agent that will
implement it in one shot, with no chance to ask follow-up questions mid-run.
Decide whether the issue is specified well enough to implement confidently.

Bias STRONGLY toward proceeding. Only flag an issue when it is genuinely too
ambiguous to know what to build: the core what or where is missing, it is
self-contradictory, or it could reasonably be built in several incompatible ways
with no way to choose. Do NOT flag an issue merely because it omits minor
detail, edge cases, naming, or polish -- a capable agent fills those in.

Answer in ONE of these two forms and nothing else:
  CLEAR
    (the issue is clear enough to implement)
  VAGUE: <one or two specific clarifying questions>
    (genuinely too vague; ask only what you must know to start)

Issue #${num}: ${title}

${capped}
EOF
)"

  # Cheapest model, no color/logs, time-boxed. Pin to the issue workspace (when
  # one exists) so the check never runs against the shared checkout. Append
  # provider noise to the log for debugging but keep stdout to just the verdict.
  local -a _ws_args=()
  [ -n "${WORKSPACE_DIR:-}" ] && _ws_args=(-C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR")
  raw="$(_run_with_timeout 60 copilot -p "$prompt" \
           ${_ws_args[@]+"${_ws_args[@]}"} \
           --model "$TRIAGE_MODEL" --allow-all-tools --no-color --log-level none 2>>"$log_file")"
  question="$(parse_vague_question "$raw")"
  [ -n "$question" ] && printf '%s' "$question"
  return 0
}
# <<< triage-vagueness helper <<<

# Sleep for the given number of seconds, but wake early if the user presses
# 'f'. Returns 0 if the full time elapsed, 1 if the user asked to start now.
# Falls back to a plain sleep when stdin is not a terminal (e.g. detached or
# piped), where keypresses cannot be read.
interruptible_sleep() {
  local seconds="$1"
  if [ ! -t 0 ]; then
    sleep "$seconds"
    return 0
  fi
  local key
  local end=$(( $(date +%s) + seconds ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if read -rsn1 -t 1 key && [ "$key" = "f" ]; then
      return 1
    fi
  done
  return 0
}

# --- Argument parsing --------------------------------------------------------
# Flags override the matching environment variables read above. Both
# "--flag value" and "--flag=value" forms are accepted.
while [ $# -gt 0 ]; do
  case "$1" in
    --trigger-label)   need_arg $# "$1"; TRIGGER_LABEL="$2"; shift ;;
    --trigger-label=*) TRIGGER_LABEL="${1#*=}" ;;
    --plan-label)      need_arg $# "$1"; PLAN_LABEL="$2"; shift ;;
    --plan-label=*)    PLAN_LABEL="${1#*=}" ;;
    --sleep-minutes)   need_arg $# "$1"; SLEEP_MINUTES="$2"; shift ;;
    --sleep-minutes=*) SLEEP_MINUTES="${1#*=}" ;;
    --repo-dir)        need_arg $# "$1"; REPO_DIR="$2"; shift ;;
    --repo-dir=*)      REPO_DIR="${1#*=}" ;;
    --model)           need_arg $# "$1"; COPILOT_MODEL="$2"; shift ;;
    --model=*)         COPILOT_MODEL="${1#*=}" ;;
    --copilot-timeout)   need_arg $# "$1"; COPILOT_TIMEOUT="$2"; shift ;;
    --copilot-timeout=*) COPILOT_TIMEOUT="${1#*=}" ;;
    --commit-model)    need_arg $# "$1"; COMMIT_MODEL="$2"; shift ;;
    --commit-model=*)  COMMIT_MODEL="${1#*=}" ;;
    --summary-model)   need_arg $# "$1"; SUMMARY_MODEL="$2"; shift ;;
    --summary-model=*) SUMMARY_MODEL="${1#*=}" ;;
    --summary)         REPORT_SUMMARY=1 ;;
    --no-summary)      REPORT_SUMMARY=0 ;;
    --triage-model)    need_arg $# "$1"; TRIAGE_MODEL="$2"; shift ;;
    --triage-model=*)  TRIAGE_MODEL="${1#*=}" ;;
    --triage-map)      need_arg $# "$1"; TRIAGE_MAP="$2"; shift ;;
    --triage-map=*)    TRIAGE_MAP="${1#*=}" ;;
    --cost-saver)      COST_SAVER=1 ;;
    --no-cost-saver)   COST_SAVER=0 ;;
    --triage-timeout-map)   need_arg $# "$1"; TRIAGE_TIMEOUT_MAP="$2"; shift ;;
    --triage-timeout-map=*) TRIAGE_TIMEOUT_MAP="${1#*=}" ;;
    --agents-model)    need_arg $# "$1"; AGENTS_MODEL="$2"; shift ;;
    --agents-model=*)  AGENTS_MODEL="${1#*=}" ;;
    --issues-dir)      need_arg $# "$1"; ISSUES_DIR="$2"; shift ;;
    --issues-dir=*)    ISSUES_DIR="${1#*=}" ;;
    --quiet)           QUIET=1 ;;
    --verbose|-v)      VERBOSE=1 ;;
    --worktrees)       USE_WORKTREES=1 ;;
    --no-worktrees)    USE_WORKTREES=0 ;;
    --auto-merge)      AUTO_MERGE=1 ;;
    --no-auto-merge)   AUTO_MERGE=0 ;;
    --quality-assurance|--qa)       QUALITY_ASSURANCE=1 ;;
    --no-quality-assurance|--no-qa) QUALITY_ASSURANCE=0 ;;
    --auto-fix)        AUTO_FIX=1 ;;
    --no-auto-fix)     AUTO_FIX=0 ;;
    --merge-method)    need_arg $# "$1"; MERGE_METHOD="$2"; shift ;;
    --merge-method=*)  MERGE_METHOD="${1#*=}" ;;
    --delete-remote-branch)    DELETE_REMOTE_BRANCH=1 ;;
    --no-delete-remote-branch) DELETE_REMOTE_BRANCH=0 ;;
    --cleanup-merged)          CLEANUP_MERGED=1 ;;
    --no-cleanup-merged)       CLEANUP_MERGED=0 ;;
    -h|--help)         usage; exit 0 ;;
    -V|--version)      printf 'copilot-loop %s\n' "$COPILOT_LOOP_VERSION"; exit 0 ;;
    *)                 die "unknown argument: $1 (use --help)" ;;
  esac
  shift
done

# --- Apply configuration defaults --------------------------------------------
# Fill in anything left unset by both the environment and the flags. Done after
# parsing so a --repo-dir flag feeds the derived paths below.
# Operate on the current directory's repository by default, not the script's
# install location (it may be a symlink on PATH). Resolve to the git top-level
# so running from a subdirectory still targets the whole repo.
REPO_DIR="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TRIGGER_LABEL="${TRIGGER_LABEL:-ready}"
# Label that routes an issue through plan mode before it is implemented. Kept
# distinct from the trigger label so the same issue can be planned first
# (labelled PLAN_LABEL) and then run (labelled TRIGGER_LABEL) after review.
PLAN_LABEL="${PLAN_LABEL:-plan}"
SLEEP_MINUTES="${SLEEP_MINUTES:-5}"
QUIET="${QUIET:-0}"
VERBOSE="${VERBOSE:-0}"
ISSUES_DIR="${ISSUES_DIR:-$REPO_DIR/issues}"
# Commit messages use a deterministic "Resolve #<n>: <title>" by default so the
# loop spends Copilot only on implementing issues, not on writing commit
# messages. Opt in to model-written messages with --commit-model <model> (e.g.
# the cheap gpt-5-mini); an unset value or "off"/"none" keeps the deterministic
# message.
COMMIT_MODEL="${COMMIT_MODEL:-}"
case "$COMMIT_MODEL" in off|none|0) COMMIT_MODEL="" ;; esac

# Close summary: once the loop resolves an issue and opens its PR it posts a short
# "what was done" summary comment on the issue (#161/#217), written from the
# session log by the light SUMMARY_MODEL. On by default; --no-summary
# (REPORT_SUMMARY=0) turns it off. SUMMARY_MODEL defaults to a cheap built-in
# model so the summary is cheap with no config; "auto"/"off"/"none"/"0" let
# Copilot pick its default model instead.
REPORT_SUMMARY="$(summary_enabled "${REPORT_SUMMARY:-}")"
SUMMARY_MODEL="$(resolve_summary_model "${SUMMARY_MODEL:-}")"

# Wall-clock limit for each main Copilot run (issue resolve, PR conflict fix, PR
# checks fix, default-branch sync) so a stuck run can never block the loop.
# Default 30m; "0"/"off" (and other disable spellings) turn it off. An unparseable
# value falls back to the default so protection is never silently lost. Stored
# normalised: a timeout(1) duration, or empty when disabled.
COPILOT_TIMEOUT="${COPILOT_TIMEOUT:-30m}"
if copilot_timeout_disabled "$COPILOT_TIMEOUT"; then
  COPILOT_TIMEOUT=""
else
  _ct_norm="$(normalize_copilot_timeout "$COPILOT_TIMEOUT")"
  COPILOT_TIMEOUT="${_ct_norm:-30m}"
fi

# Triage: a cheap model classifies each issue and a class->model map routes the
# coding model per difficulty. "off"/"none"/"0" disables triage (current
# behaviour). When triage is on but no map was given, default to sending trivial
# issues to the triage model itself so enabling triage lowers cost with zero
# extra config; normal/complex then fall back to COPILOT_MODEL.
TRIAGE_MODEL="${TRIAGE_MODEL:-}"
TRIAGE_MAP="${TRIAGE_MAP:-}"
# Cost-saver preset (#186): before normalising triage, let the preset fill in a
# cheap triage model and a trivial/normal/complex default map when the user gave
# none. Applied here -- ahead of the off-normalisation below and before the
# empty-map default -- so an explicit --triage-model/--triage-map (or an explicit
# --triage-model off) always overrides the preset, and the preset never blocks a
# run: it only ever routes to cheaper models, falling back exactly as triage does.
COST_SAVER="${COST_SAVER:-}"
TRIAGE_MAP="$(cost_saver_triage_map "$COST_SAVER" "$TRIAGE_MAP" "$TRIAGE_MODEL" "$COPILOT_MODEL")"
TRIAGE_MODEL="$(cost_saver_triage_model "$COST_SAVER" "$TRIAGE_MODEL")"
case "$TRIAGE_MODEL" in off|none|0) TRIAGE_MODEL="" ;; esac
if [ -n "$TRIAGE_MODEL" ] && [ -z "$TRIAGE_MAP" ]; then
  TRIAGE_MAP="trivial=${TRIAGE_MODEL}"
fi

# Per-difficulty run-timeout scaling (#190): a class->factor map scales the
# baseline COPILOT_TIMEOUT so a stuck trivial issue is killed sooner and a complex
# one gets more time. Factors are a percentage of the baseline ("33%"/"33") or an
# absolute duration ("10m"); "normal"/unlisted classes keep the baseline, and a
# disabled COPILOT_TIMEOUT stays disabled. When triage is on but no map was given,
# default to trivial=33%,complex=200% so enabling triage caps easy issues and
# frees hard ones with zero extra config. "off"/"none"/"0" keeps a flat timeout.
# Only applied when triage produced a class, so triage off leaves the flat timeout.
TRIAGE_TIMEOUT_MAP="${TRIAGE_TIMEOUT_MAP:-}"
if [ -n "$TRIAGE_MODEL" ] && [ -z "$TRIAGE_TIMEOUT_MAP" ]; then
  TRIAGE_TIMEOUT_MAP="trivial=33%,complex=200%"
fi
case "$TRIAGE_TIMEOUT_MAP" in off|none|0|disable|disabled) TRIAGE_TIMEOUT_MAP="" ;; esac

# AGENTS.md bootstrap model. Defaults to a capable mid model because it runs once
# per repo and every later run benefits from a good AGENTS.md, so this is not the
# place to save on model quality. "off"/"none"/"0" (and other disable spellings)
# turn the bootstrap off; any other value is used verbatim as the --model.
AGENTS_MODEL="${AGENTS_MODEL:-claude-sonnet-4.5}"
case "$AGENTS_MODEL" in off|none|no|0|false) AGENTS_MODEL="" ;; esac

# Auto-merge each PR instead of leaving it for review. Normalise the various
# truthy/falsy spellings to 1/0; anything unset or unrecognised means off.
case "$AUTO_MERGE" in
  1|true|yes|on)  AUTO_MERGE=1 ;;
  *)              AUTO_MERGE=0 ;;
esac
# Quality assurance: ask Copilot to add user-perspective tests for the work.
# On by default (issue #162); only the explicit falsy spellings turn it off.
QUALITY_ASSURANCE="$(qa_enabled "$QUALITY_ASSURANCE")"
# Loop auto-fix (issue #218): report the loop's own crashes upstream so it can
# self-improve. On by default; only the explicit falsy spellings turn it off.
case "$AUTO_FIX" in
  0|false|no|off) AUTO_FIX=0 ;;
  *)              AUTO_FIX=1 ;;
esac
# Merge method used by auto-merge. Default to a merge commit; reject anything
# other than the three methods gh understands so a typo fails loudly at startup.
MERGE_METHOD="${MERGE_METHOD:-merge}"
case "$MERGE_METHOD" in
  merge|squash|rebase) ;;
  *) die "invalid --merge-method: $MERGE_METHOD (use merge, squash or rebase)" ;;
esac

# Periodic cleanup of merged issue branches/worktrees. On unless explicitly
# disabled; DELETE_REMOTE_BRANCH (auto-detected further below, once gh is known
# to be available) then decides whether remote branches are removed too.
case "$CLEANUP_MERGED" in
  0|false|no|off) CLEANUP_MERGED=0 ;;
  *)              CLEANUP_MERGED=1 ;;
esac

# Bounded wait for GitHub's async mergeability computation before the conflict
# check (see the "mergeability helpers"). Defaults give a freshly updated PR time
# to be evaluated without stalling the loop; 0 attempts disables the wait. Force
# both to non-negative integers so a bad value never breaks the arithmetic.
MERGEABILITY_WAIT_ATTEMPTS="${MERGEABILITY_WAIT_ATTEMPTS:-5}"
case "$MERGEABILITY_WAIT_ATTEMPTS" in ''|*[!0-9]*) MERGEABILITY_WAIT_ATTEMPTS=5 ;; esac
MERGEABILITY_WAIT_SECONDS="${MERGEABILITY_WAIT_SECONDS:-3}"
case "$MERGEABILITY_WAIT_SECONDS" in ''|*[!0-9]*) MERGEABILITY_WAIT_SECONDS=3 ;; esac

WORK_DIR="$REPO_DIR/.copilot-loop"
LOG_DIR="$WORK_DIR/logs"
# Per-worker state the TUI reads to show which bot (its process id) is working
# which issue in its issues table (#214). One file per loop process,
# workers/worker-<pid>.issue, holds the issue number this process is currently
# working, or is absent between issues. The pid matches what the TUI records for
# the worker it spawned (this script's $$), so it can label the issue row.
WORKER_STATE_DIR="$WORK_DIR/workers"
# Where auto-fix keeps its per-crash de-dup markers and any crash reports it
# writes (issue #218), so a recurring loop crash is reported once, not every pass.
AUTO_FIX_STATE_DIR="$WORK_DIR/auto-fix"

# Record the issue this worker is currently working ($1 = issue number), so the
# TUI can show this process's pid against that issue (#214). Best-effort: a write
# failure never affects the run.
set_worker_issue() {
  local num="$1"
  mkdir -p "$WORKER_STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$num" >"$WORKER_STATE_DIR/worker-$$.issue" 2>/dev/null || true
}

# Drop this worker's issue assignment (between issues and on shutdown), so the
# TUI stops attributing an issue to this pid (#214). Best-effort.
clear_worker_issue() {
  rm -f "${WORKER_STATE_DIR:-}/worker-$$.issue" 2>/dev/null || true
}

# --- Preflight ---------------------------------------------------------------
for bin in git gh copilot; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH"
done

cd "$REPO_DIR" || die "cannot cd into REPO_DIR: $REPO_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository: $REPO_DIR"
_pf_origin_url="$(git remote get-url origin 2>/dev/null)"
[ -n "$_pf_origin_url" ] || die "no 'origin' remote configured"
# Scope the "is gh authenticated?" gate to this repo's origin host. Unscoped
# `gh auth status` fails when ANY logged-in host has a broken/expired token, so a
# stale login on an unrelated host would make an otherwise-authenticated machine
# look logged out and keep demanding `gh auth login`. (The gh repo view check
# below then confirms the account can actually see the repo.)
if ! _gh_authenticated_for_origin "$_pf_origin_url"; then
  _pf_host="$(_gh_host_from_url "$_pf_origin_url")"
  die "gh is not authenticated for ${_pf_host:-github.com} (run: gh auth login --hostname ${_pf_host:-github.com})"
fi

# A passing auth check only proves the origin host has a logged-in account; it
# does not prove that account can see THIS repo. The resolved account can still
# lack access, or the origin may be an SSH host alias gh cannot map to a login.
# When that happens `gh repo view` fails, yet the loop used to carry on: REPO_SLUG
# became "unknown" and every `gh issue list` silently returned nothing, so the
# loop just slept forever and looked "broken". Fail fast instead, naming the
# host and account so the mismatch is obvious and actionable.
if ! gh repo view --json nameWithOwner >/dev/null 2>&1; then
  _pf_url="$(git remote get-url origin 2>/dev/null)"
  _pf_host="$(_gh_host_from_url "$_pf_url")"
  log "FATAL: gh cannot access this repository from $REPO_DIR"
  log "  origin remote: ${_pf_url:-<none>}"
  log "  repo host:     ${_pf_host:-<unknown>}"
  log "  gh account:    $(gh api --hostname "${_pf_host:-github.com}" user --jq '.login' 2>/dev/null || echo '<no access on this host>')"
  log "  The gh account for this host cannot see the repo (wrong account, missing access, or the host is not logged in)."
  log "  Fix: run 'gh auth status' to list hosts/accounts, then 'gh auth login --hostname ${_pf_host:-HOST}'"
  log "       (or 'gh auth switch') for an account that can access this repo."
  exit 1
fi

mkdir -p "$LOG_DIR"

# Lock file for GitHub operations (issue fetching/claiming).
# Multiple instances can run concurrently but must synchronize around GitHub API calls.
GITHUB_LOCK_FILE="$WORK_DIR/github.lock"

# Best-effort modification time (epoch seconds) of a path. Portable across the
# BSD stat on macOS (-f %m) and GNU stat on Linux (-c %Y); echoes 0 when it
# cannot tell.
_lock_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Acquire the GitHub lock (a directory created with mkdir). Waits up to max_wait
# real seconds, then gives up (returns 1) so a busy peer never stalls the loop
# for long. A lock left behind by a crashed instance is reclaimed once it is
# older than stale_after seconds, so a hard-killed holder cannot wedge every
# instance forever. Caller must release with release_github_lock().
acquire_github_lock() {
  local max_wait=30 stale_after=600 start now lock_mtime
  start="$(date +%s)"
  while ! mkdir "$GITHUB_LOCK_FILE" 2>/dev/null; do
    now="$(date +%s)"
    # Reclaim a stale lock from a crashed holder (skip when mtime is unknown).
    lock_mtime="$(_lock_mtime "$GITHUB_LOCK_FILE")"
    if [ "$lock_mtime" -gt 0 ] 2>/dev/null && [ $(( now - lock_mtime )) -ge "$stale_after" ]; then
      log "WARNING: breaking stale GitHub lock (older than ${stale_after}s)"
      rm -rf "$GITHUB_LOCK_FILE" 2>/dev/null || true
      continue
    fi
    if [ $(( now - start )) -ge "$max_wait" ]; then
      log "WARNING: GitHub lock busy after ${max_wait}s; skipping this pass"
      return 1
    fi
    sleep 0.2
  done
  return 0
}

# Release the GitHub lock.
release_github_lock() {
  rm -rf "$GITHUB_LOCK_FILE" 2>/dev/null || true
}

cleanup() {
  # Capture the exit status first: any command below (release_github_lock, the
  # worker-state removal) would otherwise overwrite $? before we can report it.
  local rc=$?
  release_github_lock
  clear_worker_issue
  if [ -n "${SHUTDOWN_REASON:-}" ]; then
    log "shutting down: ${SHUTDOWN_REASON} (exit $rc)"
  elif [ "$rc" -eq 0 ]; then
    log "shutting down: loop exited normally (exit 0)"
  else
    log "shutting down: unexpected exit $rc — see the error above (often a failed git/gh command or a bug); re-run with --verbose for more detail"
  fi
}
trap cleanup EXIT
trap 'SHUTDOWN_REASON="interrupted by a signal (Ctrl-C or stop)"; log "interrupted"; exit 130' INT TERM

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)"
# Host that owns this repo, used to pin repo-independent `gh` calls (below) to
# the right account when several hosts are logged in.
GH_HOST_ORIGIN="$(_gh_host_from_url "$ORIGIN_URL")"
REPO_SLUG="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"
[ -n "$REPO_SLUG" ] || REPO_SLUG="unknown"
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"
# Linked worktrees (and some manually-added remotes) can have no fetch refspec,
# so `git fetch origin` never populates origin/* remote-tracking refs and every
# `origin/<branch>` reference fails with "invalid upstream". Restore the standard
# refspec so remote-tracking refs always resolve.
if ! git config --get-all remote.origin.fetch 2>/dev/null | grep -q .; then
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
    && log "restored missing fetch refspec for origin"
fi

# Decide whether to delete an issue's remote branch once its PR merges. When not
# forced with 1/0, auto-detect from the repository: skip it when GitHub already
# deletes head branches on merge (it cleans up for us) and enable it otherwise,
# so a repo without that setting no longer accumulates merged branches.
case "$DELETE_REMOTE_BRANCH" in
  1|true|yes|on)  DELETE_REMOTE_BRANCH=1 ;;
  0|false|no|off) DELETE_REMOTE_BRANCH=0 ;;
  *)
    if [ "$(gh repo view --json deleteBranchOnMerge --jq '.deleteBranchOnMerge' 2>/dev/null)" = "true" ]; then
      DELETE_REMOTE_BRANCH=0
    else
      DELETE_REMOTE_BRANCH=1
    fi
    ;;
esac

# --- Self-update setup -------------------------------------------------------
# Decide whether the loop keeps itself current by pulling the default branch and
# re-execing when this script changed upstream (see self_update, called at the
# top of the main loop). Auto-enable when the script is a tracked file in the
# repo we operate on; an explicit SELF_UPDATE=1/0 always wins.
case "$SELF_UPDATE" in
  1|true|yes|on)   SELF_UPDATE=1 ;;
  0|false|no|off)  SELF_UPDATE=0 ;;
  *)
    if git -C "$REPO_DIR" ls-files --error-unmatch -- "$SCRIPT_PATH" >/dev/null 2>&1; then
      SELF_UPDATE=1
    else
      SELF_UPDATE=0
    fi
    ;;
esac
# Path of the running script relative to the repo root, used to read its upstream
# version. Empty (self-update off) when the script is not tracked in this repo.
SCRIPT_REL=""
if [ "$SELF_UPDATE" = 1 ]; then
  SCRIPT_REL="$(git -C "$REPO_DIR" ls-files --full-name -- "$SCRIPT_PATH" 2>/dev/null | head -1)"
  [ -n "$SCRIPT_REL" ] || SELF_UPDATE=0
fi

# Whether to sync the local default branch with origin/<default> before each pass
# (see sync_default_branch, called at the top of the main loop). On unless an
# explicit 0/false/no/off turns it off.
case "$SYNC_REMOTE" in
  0|false|no|off) SYNC_REMOTE=0 ;;
  *)              SYNC_REMOTE=1 ;;
esac

# Decide whether to isolate each issue in its own git worktree. On by default so
# every task works in a different folder and parallel instances never touch the
# same checkout; pass --no-worktrees (or USE_WORKTREES=0) to work in place
# instead. This keeps the shared checkout untouched and guarantees the default
# branch is never used for the work. Each issue still gets its own branch in
# either mode.
# >>> worktree-default helpers >>>
case "$USE_WORKTREES" in
  0|false|no|off) USE_WORKTREES=0 ;;
  *)              USE_WORKTREES=1 ;;
esac
# <<< worktree-default helpers <<<
# Where per-issue worktrees are created (only used when USE_WORKTREES=1). In a
# bare-repo worktree workflow (git clone --bare + linked worktrees, e.g. the
# cw/aw/sw shell helpers) they live directly under the bare root, named after the
# branch with slashes flattened to dashes — exactly what `sw <branch>` creates —
# so the loop shares one worktree namespace with any created by hand and the two
# never collide. In an ordinary (non-bare) checkout they are grouped in a
# copilot-loop-worktrees sibling of REPO_DIR so they never land inside the
# tracked working tree.
_common_dir="$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null || echo .)"
case "$_common_dir" in /*) : ;; *) _common_dir="$REPO_DIR/$_common_dir" ;; esac
_common_dir="$(cd "$_common_dir" 2>/dev/null && pwd)" || _common_dir=""
if [ -n "$_common_dir" ] && [ "$(git --git-dir="$_common_dir" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
  WORKTREE_BASE="$_common_dir"
else
  WORKTREE_BASE="$(dirname "$REPO_DIR")/copilot-loop-worktrees"
fi
unset _common_dir

# Our own login, used to tell the user's replies apart from the loop's own
# comments when deciding whether a "needs-info" issue is ready to resume. Pin the
# query to the repo's host so a machine logged in to several hosts reports the
# identity that actually comments on this repo (github.com's `gh api user` would
# otherwise be returned for an enterprise repo, breaking reply detection).
if [ -n "$GH_HOST_ORIGIN" ]; then
  BOT_LOGIN="$(gh api --hostname "$GH_HOST_ORIGIN" user --jq '.login' 2>/dev/null)"
else
  BOT_LOGIN="$(gh api user --jq '.login' 2>/dev/null)"
fi
[ -n "$BOT_LOGIN" ] || log "WARNING: could not determine gh login; reply detection disabled"

log "starting copilot-loop"
log "============================================================"
log "  GitHub repo: $REPO_SLUG"
log "  gh account:  ${BOT_LOGIN:-<unknown>} @ ${GH_HOST_ORIGIN:-github.com}"
log "  origin url:  $ORIGIN_URL"
log "  local dir:   $REPO_DIR"
log "============================================================"
log "default_branch=$DEFAULT_BRANCH trigger_label=$TRIGGER_LABEL plan_label=$PLAN_LABEL sleep=${SLEEP_MINUTES}m"
if [ "$USE_WORKTREES" = 1 ]; then
  log "isolation: per-issue git worktrees under $WORKTREE_BASE (default branch never checked out)"
else
  log "isolation: per-issue branches in the current checkout (default branch never checked out)"
fi
if [ "$QUIET" = 1 ]; then
  log "copilot output: log files only (--quiet); stdout hidden"
else
  log "copilot output: streamed to stdout and log files (pass --quiet to hide)"
fi
if [ "$VERBOSE" = 1 ]; then
  log "verbosity: on (--verbose) — narrating each loop phase"
else
  log "verbosity: normal — pass --verbose for per-phase loop detail"
fi
if [ "$AUTO_MERGE" = 1 ]; then
  log "auto-merge: on (method=$MERGE_METHOD) — PRs merge without review"
else
  log "auto-merge: off — PRs are left open for review (pass --auto-merge to enable)"
fi
if [ "$QUALITY_ASSURANCE" = 1 ]; then
  log "quality assurance: on — Copilot adds user-perspective tests per issue (pass --no-quality-assurance to disable)"
else
  log "quality assurance: off — no tests requested (pass --quality-assurance to enable)"
fi
if [ "$REPORT_SUMMARY" = 1 ]; then
  log "close summary: on — a '${SUMMARY_MODEL:-auto}' summary of what was done is posted per resolved issue (pass --no-summary to disable)"
else
  log "close summary: off — no summary posted on resolved issues (pass --summary to enable)"
fi
if [ "$AUTO_FIX" = 1 ]; then
  log "auto-fix: on — loop crashes are reported to $BOT_LOOP_REPO so the loop can self-improve (pass --no-auto-fix to disable)"
else
  log "auto-fix: off — loop crashes are only logged (pass --auto-fix to enable)"
fi
if [ "$CLEANUP_MERGED" = 1 ]; then
  if [ "$DELETE_REMOTE_BRANCH" = 1 ]; then
    log "cleanup: on — merged branches and worktrees removed, remote branches deleted"
  else
    log "cleanup: on — merged branches and worktrees removed (remote branches left to GitHub)"
  fi
else
  log "cleanup: off — merged branches and worktrees are not swept (pass --cleanup-merged to enable)"
fi

ensure_label "$TRIGGER_LABEL"    "0e8a16" "Ready for the copilot loop to pick up"
ensure_label "$PLAN_LABEL"       "5319e7" "Ask the copilot loop for an implementation plan before running it"
ensure_label "$PLAN_REVIEW_LABEL" "5319e7" "A plan was posted; waiting for the user to review it and add the trigger label"
ensure_label "$INPROGRESS_LABEL" "fbca04" "Currently being worked by the copilot loop"
ensure_label "$DONE_LABEL"       "1d76db" "A PR was opened by the copilot loop"
ensure_label "$FAILED_LABEL"     "b60205" "The copilot loop failed to produce changes"
ensure_label "$NEEDS_INFO_LABEL" "d93f0b" "Waiting for the issue author to answer a question"
ensure_label "$PENDING_LABEL"    "d4c5f9" "Waiting for another issue to be resolved before it can start"
ensure_label "$CONFLICT_UNRESOLVED_LABEL" "b60205" "The copilot loop could not resolve this PR's merge conflicts"
ensure_label "$CHECKS_UNRESOLVED_LABEL" "b60205" "The copilot loop could not fix this PR's failing checks"

# --- Workspace isolation -----------------------------------------------------
# Every issue (and every PR conflict fix) runs in its own branch, prepared here.
# The default branch (main/master) is NEVER checked out for the work: the branch
# is created directly from a start commit-ish (normally origin/<default>).
#
# Two modes, selected by USE_WORKTREES:
#   1 -> a dedicated git worktree per branch, so the shared checkout is untouched
#        (the default: every task works in a different folder, and it is required
#        when the repo is used with git worktrees, where the default branch may
#        already be checked out elsewhere and cannot be switched to).
#   0 -> the branch is checked out in REPO_DIR itself (opt in with --no-worktrees).
# Both set WORKSPACE_DIR to the directory Copilot and git should operate in.
WORKSPACE_DIR=""

# Map a branch name to its worktree directory (slashes flattened to dashes).
# >>> workspace helpers >>>
_worktree_path() {
  printf '%s/%s' "$WORKTREE_BASE" "$(printf '%s' "$1" | tr '/' '-')"
}

# _worktree_lock_state <branch>
# Classify the lock on the worktree that has <branch> checked out, so cleanup
# can tell its own (reclaimable) worktree from one a *different* live run still
# owns (#106):
#   unlocked  -> not locked
#   pid:<N>   -> locked by a copilot-loop run whose pid is <N> (see the reason
#                prepare_workspace writes)
#   locked    -> locked without our pid marker (e.g. a manual `git worktree lock`)
# Matches on the branch ref rather than the path so it stays correct when git
# reports a resolved path (e.g. macOS /var -> /private/var); the lock reason is
# emitted on the `locked` line, unquoted for our plain reason.
_worktree_lock_state() {
  local branch="$1" line target=0 pid
  [ -n "$branch" ] || { printf 'unlocked'; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) target=0 ;;
      "branch refs/heads/$branch") target=1 ;;
      locked|"locked "*)
        if [ "$target" = 1 ]; then
          pid="$(printf '%s\n' "$line" | sed -n 's/.*pid \([0-9][0-9]*\).*/\1/p')"
          if [ -n "$pid" ]; then printf 'pid:%s' "$pid"; else printf 'locked'; fi
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  printf 'unlocked'
}

# prepare_workspace <branch> <start-ref>
# Create (or reset) <branch> at <start-ref> and set WORKSPACE_DIR. Returns 1 if
# the branch/worktree could not be created.
prepare_workspace() {
  local branch="$1" start="$2"
  cleanup_workspace "$branch"
  if [ "$USE_WORKTREES" = 1 ]; then
    local wt; wt="$(_worktree_path "$branch")"
    mkdir -p "$WORKTREE_BASE" 2>/dev/null || true
    if ! git worktree add --force -B "$branch" "$wt" "$start" >/dev/null 2>&1; then
      return 1
    fi
    # Lock the worktree for as long as this run owns it so a concurrent cleanup
    # pass in another bot (sweep_merged_branches / git worktree prune) can never
    # remove the folder out from under a live Copilot session — the race that
    # left sessions with a dead working directory. cleanup_workspace unlocks it.
    git worktree lock --reason "copilot-loop: $branch in progress (pid $$)" "$wt" >/dev/null 2>&1 || true
    WORKSPACE_DIR="$wt"
  else
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    if ! git -C "$REPO_DIR" switch -C "$branch" "$start" >/dev/null 2>&1; then
      return 1
    fi
    WORKSPACE_DIR="$REPO_DIR"
  fi
}

# cleanup_workspace <branch>
# Tear down the workspace for <branch> and delete the local branch. Never checks
# out the default branch; in-place mode parks on a detached HEAD so the branch
# can be deleted.
cleanup_workspace() {
  local branch="$1"
  if [ "$USE_WORKTREES" = 1 ]; then
    local wt; wt="$(_worktree_path "$branch")"
    # Never tear down a worktree a *different* live run still owns: removing it
    # would delete an active Copilot session's working directory — the #106
    # race. Our own lock (pid $$) and a crashed run's stale lock (a pid no
    # longer alive) are safe to reclaim; a foreign live lock, or one placed by
    # hand (no pid marker), is left strictly alone so the session survives.
    local lock_state; lock_state="$(_worktree_lock_state "$branch")"
    case "$lock_state" in
      "pid:$$") : ;;                                   # our own lock -> reclaim
      pid:*)
        if kill -0 "${lock_state#pid:}" 2>/dev/null; then
          WORKSPACE_DIR=""
          return 0                                     # another live run owns it
        fi
        ;;                                             # dead pid -> reclaim
      locked)
        WORKSPACE_DIR=""
        return 0                                       # locked by hand -> leave it
        ;;
    esac
    # Unlock first: prepare_workspace locked it while the run was live, and a
    # locked worktree cannot be removed with a single --force.
    git worktree unlock "$wt" >/dev/null 2>&1 || true
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
  else
    git -C "$REPO_DIR" reset --hard >/dev/null 2>&1 || true
    git -C "$REPO_DIR" clean -fd >/dev/null 2>&1 || true
    git -C "$REPO_DIR" switch --detach >/dev/null 2>&1 || true
  fi
  git branch -D "$branch" >/dev/null 2>&1 || true
  WORKSPACE_DIR=""
}
# <<< workspace helpers <<<

# --- Core: enable auto-merge on a freshly opened PR --------------------------
# When AUTO_MERGE is on, ask GitHub to merge the PR without manual review.
# Prefer GitHub's native auto-merge (it waits for any required status checks);
# when the repository does not allow auto-merge, fall back to merging right now.
# Best effort: a failure here never fails the issue, it just leaves the PR open.
try_auto_merge() {
  local pr="$1" num="$2" log_file="$3"
  [ "$AUTO_MERGE" = 1 ] || return 0
  if gh pr merge "$pr" --auto "--$MERGE_METHOD" >>"$log_file" 2>&1; then
    log "issue #$num: auto-merge enabled (method=$MERGE_METHOD) on $pr"
    return 0
  fi
  # Auto-merge is likely not enabled on the repository; merge immediately.
  if gh pr merge "$pr" "--$MERGE_METHOD" >>"$log_file" 2>&1; then
    log "issue #$num: merged immediately (method=$MERGE_METHOD) $pr"
    return 0
  fi
  log "issue #$num: WARNING could not auto-merge $pr; left open for manual merge"
  return 0
}

# --- Core: branch & worktree cleanup ----------------------------------------
# Once an issue's PR is merged its work branch and worktree are dead weight. The
# helpers below remove them safely: only ever the loop's own branches
# ("$BRANCH_PREFIX"*, never the default branch), and never a branch that still
# has commits which are neither merged into the default branch nor pushed to its
# own remote branch (so un-pushed work is always preserved).
#
# branch_is_ours is pure (string logic only) and, with the rest of this block, is
# covered by tests/cleanup-branches.test.sh between the markers — keep them intact.
# >>> cleanup helpers >>>
# branch_is_ours <branch>
# True (0) only for a non-empty branch that is one of the loop's own work
# branches (matches "$BRANCH_PREFIX"*) and is not the default branch. Guards
# every destructive cleanup so it can never delete main/master or a branch a
# human created.
branch_is_ours() {
  local branch="$1"
  [ -n "$branch" ] || return 1
  [ "$branch" != "$DEFAULT_BRANCH" ] || return 1
  case "$branch" in
    "$BRANCH_PREFIX"?*) return 0 ;;
    *) return 1 ;;
  esac
}

# _worktree_dir_for_branch <branch>
# Echo the path of the linked worktree that currently has <branch> checked out,
# or nothing if none does. Reads `git worktree list` so the worktree is found
# wherever it lives, not only at the loop's own _worktree_path.
_worktree_dir_for_branch() {
  local branch="$1"
  git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    /^worktree /  { wt = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == b) { print wt; exit } }'
}

# _worktree_is_locked <path>
# True (0) when the worktree at <path> is currently locked, i.e. a live
# copilot-loop run owns it (see prepare_workspace). The sweep uses this to never
# remove or delete a worktree/branch that a running Copilot session still needs.
_worktree_is_locked() {
  local target="$1" line wt=""
  [ -n "$target" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      locked|"locked "*) [ "$wt" = "$target" ] && return 0 ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}

# branch_has_unpushed_work <branch> <base-ref>
# True (0) when <branch> has commits that are neither contained in <base-ref>
# (merged) nor in its own pushed remote ref (origin/<branch>) — i.e. deleting it
# would lose un-pushed work. Errs on the side of caution: any failure to tell is
# treated as "has un-pushed work" so the branch is preserved.
branch_has_unpushed_work() {
  local branch="$1" base="$2" n
  if git rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    n="$(git rev-list --count "$branch" --not "$base" "origin/$branch" 2>/dev/null || echo 1)"
  else
    n="$(git rev-list --count "$branch" --not "$base" 2>/dev/null || echo 1)"
  fi
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -gt 0 ]
}

# remove_local_branch <branch>
# Remove <branch>'s worktree (if any) and delete the local branch. Safe no-op for
# a branch that is not the loop's own; never checks out the default branch.
remove_local_branch() {
  local branch="$1" wt
  branch_is_ours "$branch" || return 0
  wt="$(_worktree_dir_for_branch "$branch")"
  if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
    # Defence-in-depth (#106): a locked worktree belongs to a live Copilot
    # session. Never remove it — nor delete its branch — even when this is
    # reached directly or the lock was taken after the sweep's own guard ran.
    log "cleanup: keeping $branch (worktree in use)"
    return 0
  fi
  if [ -n "$wt" ]; then
    git worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  git worktree prune >/dev/null 2>&1 || true
  git branch -D "$branch" >/dev/null 2>&1 || true
}

# delete_remote_branch <branch>
# Delete <branch> on origin when remote-branch cleanup is enabled. Safe no-op for
# a foreign/default branch or when the remote branch is already gone.
delete_remote_branch() {
  local branch="$1"
  [ "$DELETE_REMOTE_BRANCH" = 1 ] || return 0
  branch_is_ours "$branch" || return 0
  git push origin --delete "$branch" >/dev/null 2>&1 || true
}

# _branch_is_merged <ref> <base-ref> <merged-list> [name]
# True (0) when <ref>'s work is merged: <ref> is an ancestor of <base-ref> (the
# merge-commit method), or its branch <name> appears in <merged-list> (a merged
# PR, covering squash/rebase merges whose commits are not ancestors of the base).
# <name> defaults to <ref>.
_branch_is_merged() {
  local ref="$1" base="$2" merged_list="$3" name="${4:-$1}"
  if git merge-base --is-ancestor "$ref" "$base" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$merged_list" | grep -qxF -- "$name"
}

# sweep_merged_branches
# Periodic safety net: remove local branches/worktrees whose PR has merged, and
# delete the remote branches that linger after a merge. Only ever touches the
# loop's own branches and never one with un-pushed work. Best effort — every
# operation is guarded so a hiccup never interrupts the loop. Assumes the current
# directory is inside the repository (true in the main loop).
sweep_merged_branches() {
  [ "$CLEANUP_MERGED" = 1 ] || return 0

  # Refresh remote-tracking refs and drop ones already deleted upstream so the
  # merge checks below see the true remote state.
  git fetch --prune origin >/dev/null 2>&1 || true

  local base="origin/${DEFAULT_BRANCH}"
  git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="$DEFAULT_BRANCH"

  # One API call for the set of merged issue-branch names so squash/rebase merges
  # (whose commits are not ancestors of the base) are recognised too.
  local merged_prs
  merged_prs="$(gh pr list --state merged --base "$DEFAULT_BRANCH" --limit 200 \
                  --json headRefName --jq '.[].headRefName' 2>/dev/null)"

  local removed=0 b wt
  # Local branches: remove merged ones together with their worktree.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    branch_is_ours "$b" || continue
    _branch_is_merged "$b" "$base" "$merged_prs" || continue
    if branch_has_unpushed_work "$b" "$base"; then
      log "cleanup: keeping $b (has un-pushed work)"
      continue
    fi
    # Never pull a worktree out from under a live run: a locked worktree means a
    # Copilot session still owns it. Leave it — a later pass sweeps it once the
    # run finishes and cleanup_workspace unlocks it.
    wt="$(_worktree_dir_for_branch "$b")"
    if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
      log "cleanup: keeping $b (worktree in use)"
      continue
    fi
    remove_local_branch "$b"
    delete_remote_branch "$b"
    log "cleanup: removed merged branch $b"
    removed=$(( removed + 1 ))
  done < <(git for-each-ref --format='%(refname:short)' "refs/heads/${BRANCH_PREFIX}" 2>/dev/null)

  # Remote branches: delete ones whose PR merged but that still linger on origin
  # (the local branch was often already removed inline when its PR was opened).
  if [ "$DELETE_REMOTE_BRANCH" = 1 ]; then
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      branch_is_ours "$b" || continue
      _branch_is_merged "origin/$b" "$base" "$merged_prs" "$b" || continue
      # A live run may still push to this remote branch; if its local worktree is
      # locked (in use), leave the remote alone until the run finishes.
      wt="$(_worktree_dir_for_branch "$b")"
      if [ -n "$wt" ] && _worktree_is_locked "$wt"; then
        log "cleanup: keeping remote $b (worktree in use)"
        continue
      fi
      delete_remote_branch "$b"
      log "cleanup: deleted merged remote branch $b"
      removed=$(( removed + 1 ))
    done < <(git for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/origin/${BRANCH_PREFIX}" 2>/dev/null)
  fi

  [ "$removed" -gt 0 ] && log "cleanup: swept $removed merged branch(es)"
  return 0
}
# <<< cleanup helpers <<<

# --- Core: process a single issue -------------------------------------------
# Whether an issue's comment thread already carries a posted plan (the hidden
# PLAN_MARKER), i.e. the issue went through plan mode and the user approved the
# plan by adding the trigger label. Pure (reads the comments string on $1), so it
# is extracted verbatim by tests/plan-mode.test.sh — keep the markers intact.
# >>> plan-detect helpers >>>
comments_have_plan() {
  case "$1" in
    *"<!-- copilot-loop:plan -->"*) return 0 ;;
    *) return 1 ;;
  esac
}
# <<< plan-detect helpers <<<

# --- Rebase conflict resolution ----------------------------------------------
# When the pre-PR sync rebase (process_issue) conflicts, we do not fail the issue
# and interrupt the loop (#193): instead we hand the conflicted files to Copilot,
# continue the rebase, and repeat until it finishes. Extracted between the markers
# so tests/rebase-conflict.test.sh can source these verbatim.
# >>> rebase-conflict helpers >>>
# Continue an in-progress rebase in <dir>, appending git's output to <log_file>.
# core.editor=true keeps git from opening an editor for the reworded commit.
# Returns: 0 = rebase fully finished; 2 = stopped again on a fresh conflict (the
# caller resolves and calls again); 1 = failed for some other reason. A resolution
# that leaves the commit empty (its change already upstream) is skipped so the
# rebase can carry on rather than dead-ending on "No changes".
_rebase_continue() {
  local dir="$1" log_file="$2" out
  if out="$(git -C "$dir" -c core.editor=true rebase --continue 2>&1)"; then
    printf '%s\n' "$out" >>"$log_file"
    return 0
  fi
  printf '%s\n' "$out" >>"$log_file"
  if [ -n "$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    return 2
  fi
  # Continue failed with no conflicts and nothing staged: the resolved commit is
  # empty because its change already landed upstream. Drop it and keep going.
  if git -C "$dir" diff --cached --quiet 2>/dev/null; then
    if out="$(git -C "$dir" rebase --skip 2>&1)"; then
      printf '%s\n' "$out" >>"$log_file"
      return 0
    fi
    printf '%s\n' "$out" >>"$log_file"
    [ -n "$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null)" ] && return 2
  fi
  return 1
}

# Resolve the conflicts of an in-progress rebase in WORKSPACE_DIR by handing the
# conflicted files to Copilot, then continue the rebase — looping so a rebase that
# stops on several commits is carried all the way through. Returns 0 when the
# rebase completes cleanly, 1 when it cannot be resolved (Copilot times out, leaves
# markers, or the rebase fails for another reason); the caller aborts + fails then.
# Usage: resolve_rebase_conflicts <num> <log_file> <upstream>
resolve_rebase_conflicts() {
  local num="$1" log_file="$2" upstream="$3"
  local conflicts copilot_rc f unresolved cont_rc prompt

  while true; do
    conflicts="$(git -C "$WORKSPACE_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
    if [ -z "$conflicts" ]; then
      # Called with no unmerged paths (e.g. a non-conflict pause): try to advance.
      _rebase_continue "$WORKSPACE_DIR" "$log_file"; cont_rc=$?
      case "$cont_rc" in 0) return 0 ;; 2) continue ;; *) return 1 ;; esac
    fi

    log "issue #$num: resolving rebase conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')"

    prompt="$(cat <<EOF
You are working in a git repository. Rebasing this branch onto "${upstream}"
produced conflicts that must be resolved before the work can be pushed.

These files contain git conflict markers (<<<<<<<, =======, >>>>>>>):
${conflicts}

Resolve every conflict so the result is correct and preserves the intent of both
sides, then remove all conflict markers. Run any build or test commands needed to
verify your work. Do NOT run git commit, git rebase, git push, or create
branches — those steps are handled automatically outside this session. Only edit
files to resolve the conflicts and verify.
EOF
)"
    local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
    [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

    log "issue #$num: running copilot to resolve rebase conflicts (log: $log_file)"
    if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
      return 1
    fi
    run_copilot "$log_file" "${copilot_args[@]}"
    copilot_rc=$COPILOT_RC
    cd "$REPO_DIR" 2>/dev/null || true
    log "issue #$num: copilot exited with code $copilot_rc while resolving rebase conflicts"

    # Each resolution run is a separate Copilot invocation, so account for its cost.
    _report_usage issue "$num" "$log_file" "$COPILOT_MODEL"

    if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
      return 1
    fi

    # Bail if Copilot left conflict markers behind in any conflicted file.
    unresolved=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$WORKSPACE_DIR/$f" ] && grep -qE '^(<{7}|>{7})' "$WORKSPACE_DIR/$f" && unresolved="$unresolved $f"
    done <<< "$conflicts"
    if [ -n "$unresolved" ]; then
      return 1
    fi

    git -C "$WORKSPACE_DIR" add -A >>"$log_file" 2>&1
    _rebase_continue "$WORKSPACE_DIR" "$log_file"; cont_rc=$?
    case "$cont_rc" in 0) return 0 ;; 2) continue ;; *) return 1 ;; esac
  done
}
# <<< rebase-conflict helpers <<<

# Returns 0 on success (PR opened), 1 on failure.
process_issue() {
  local num="$1"
  local title body slug branch commit_msg commit_text commit_out pr_body log_file ahead pr_url
  local question_file comments comments_block qa_block plan_block

  # One API round-trip for everything we need from the issue (title, body, and
  # the comment thread) instead of three separate `gh issue view` calls. Fields
  # are NUL-separated so multi-line bodies and comments survive intact.
  { IFS= read -r -d '' title; IFS= read -r -d '' body; IFS= read -r -d '' comments; } < <(
    gh issue view "$num" --json title,body,comments \
      --jq '[.title, (.body // ""), ([.comments[] | "--- @" + (.author.login // "ghost") + " wrote:\n" + (.body // "")] | join("\n"))] | join("\u0000")' 2>/dev/null)
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="issue"
  branch="${BRANCH_PREFIX}${num}-${slug}"
  commit_msg="Resolve #${num}: ${title}"
  pr_body="Closes #${num}"$'\n\n'"Automated by copilot-loop."
  log_file="$LOG_DIR/issue-${num}-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-issue log so the TUI's output
  # panel shows the branch creation and the rest of the loop's narration, not
  # just Copilot's transcript (#126). Cleared at the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  # Publish which issue this worker (pid) is on so the TUI can show its pid on
  # that issue's row (#214). Cleared at the top of the main loop.
  set_worker_issue "$num"

  log "issue #$num on $REPO_SLUG: $title"

  # Note: the issue has already been claimed atomically under the GitHub lock by
  # claim_next_ready_issue() / claim_next_reply_issue() in the main loop
  # (in-progress added; the trigger, needs-info, or copilot-failed label
  # removed). We don't re-claim here to avoid redundant API calls.

  # Base the issue branch on the latest default branch WITHOUT checking the
  # default branch out (it may be checked out in another worktree, and the issue
  # requires we never work on main/master). Fetch first so origin/<default> is
  # current, then create the branch/worktree straight from it.
  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  local start="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$start" >/dev/null 2>&1 || start="FETCH_HEAD"
  if ! prepare_workspace "$branch" "$start"; then
    _fail_issue "$num" "$log_file" "could not create work branch $branch"
    return 1
  fi

  # Copilot writes here when it needs to ask the user something instead of
  # coding. Kept inside the per-issue workspace (never the shared checkout) under
  # its gitignored control dir; the ask-path returns before any commit, so it is
  # never included in a PR. A fresh worktree carries no stale copy, but clear it
  # defensively.
  question_file="$WORKSPACE_DIR/.copilot-loop/issue-${num}.question"
  mkdir -p "$(dirname "$question_file")" 2>/dev/null || true
  rm -f "$question_file"

  # Surface the freshly created branch before Copilot starts: log it and set the
  # terminal tab/window title (and tmux window name) to the branch name.
  log "issue #$num: working on branch $branch"
  set_terminal_title "$branch"

  # Include the existing comment thread (fetched above) so any earlier
  # question/answer exchange is available to Copilot as context.
  comments_block=""
  [ -n "$comments" ] && comments_block=$'\n\nConversation so far (most recent last):\n'"$comments"

  # Quality assurance: unless disabled, append an instruction asking Copilot to
  # add user-perspective tests for the work. Wrapped in blank lines so it reads
  # as its own paragraph; empty (no extra blank line) when QA is off.
  qa_block=""
  [ "$QUALITY_ASSURANCE" = 1 ] && qa_block=$'\n'"$(qa_instruction "$QUALITY_ASSURANCE")"$'\n'

  # Plan mode follow-up: if this issue was planned first (its thread carries the
  # posted plan) the user approved that plan by adding the trigger label to run
  # it. Tell Copilot to follow the approved plan — the latest one, so any changes
  # the user made in a later comment win — instead of re-deciding the approach.
  plan_block=""
  if comments_have_plan "$comments"; then
    plan_block=$'\n'"An implementation plan for this issue was proposed earlier in the conversation above and approved by the user. Follow that plan. If the user amended it in a later comment, follow the most recent version of the plan."$'\n'
  fi

  # Vagueness gate (#188): before spending a coding run, let the cheap
  # TRIAGE_MODEL judge whether the issue is specified well enough to implement. If
  # it is genuinely too vague, ask the author the clarifying question(s) via the
  # needs-info flow and stop here (no coding run); the issue resumes normally once
  # they reply. A no-op when triage is off, when we already asked this issue (ask
  # at most once), or for an approved plan.
  if maybe_ask_when_vague "$num" "$title" "$body" "$comments" "$question_file" "$log_file"; then
    return 0
  fi

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository to resolve a GitHub issue.

Issue #${num}: ${title}

${body}${comments_block}
${plan_block}
Implement the necessary code changes in the current working directory to fully
resolve this issue. Run any build or test commands needed to verify your work.
Do NOT run git commit, git push, create branches, or open pull requests — those
steps are handled automatically outside this session. Only edit files and verify.
${qa_block}
If you are blocked and need more information or a decision from the user, do NOT
guess. Write your question(s) for the user to this file and stop without making
code changes:
  ${question_file}
Whatever you write there is posted as a comment on the issue; once the user
replies you will be run again with their answer included above. Only do this
when you genuinely cannot proceed without their input.
EOF
)"

  # Run Copilot non-interactively, pinned to the issue's workspace: -C makes that
  # worktree Copilot's working directory and --add-dir keeps file access
  # restricted to it (we deliberately do not pass --allow-all-paths), so Copilot
  # only ever edits the created folder and never the shared checkout. The
  # question file lives inside that workspace, so no other directory is granted.
  # Choose the coding model. When triage is enabled, classify the issue with the
  # cheap TRIAGE_MODEL and map the class to a coding model via TRIAGE_MAP; on any
  # failure, or a class with no mapping, fall back to the global COPILOT_MODEL so
  # triage can only ever lower cost, never break or block the run.
  # Initialise triage_class/mapped_model to empty: when triage is off (the
  # default, TRIAGE_MODEL unset) the block below is skipped, yet the run-timeout
  # scaling further down still reads $triage_class. Under `set -u` an unset
  # local there aborts the whole loop right after "working on branch" with a bare
  # "unbound variable", which surfaced as the loop just "shutting down" (#216).
  local coding_model="$COPILOT_MODEL" triage_class="" mapped_model=""
  if [ -n "$TRIAGE_MODEL" ]; then
    log "issue #$num: triaging with $TRIAGE_MODEL"
    triage_class="$(triage_issue "$num" "$title" "$body" "$log_file")"
    if [ -n "$triage_class" ]; then
      mapped_model="$(parse_triage_map "$TRIAGE_MAP" "$triage_class")"
      if [ -n "$mapped_model" ]; then
        coding_model="$mapped_model"
        log "issue #$num: triaged as '$triage_class' -> model '$mapped_model'"
      else
        log "issue #$num: triaged as '$triage_class' -> default model ${COPILOT_MODEL:-auto}"
      fi
    else
      log "issue #$num: triage inconclusive -> default model ${COPILOT_MODEL:-auto}"
    fi
  fi

  # Scale the run timeout by triage difficulty (#190): a trivial issue is killed
  # sooner and a complex one gets more time, while "normal"/unknown keep the
  # baseline --copilot-timeout and a disabled timeout stays disabled. Shadow
  # COPILOT_TIMEOUT for this run so run_copilot's guard and the timeout
  # check/message below all use the per-issue value (bash dynamic scope carries
  # the local into run_copilot); the global baseline is restored on return.
  local COPILOT_TIMEOUT="$COPILOT_TIMEOUT"
  if [ -n "$triage_class" ] && [ -n "$TRIAGE_TIMEOUT_MAP" ]; then
    local scaled_timeout
    scaled_timeout="$(scale_copilot_timeout "$COPILOT_TIMEOUT" "$(parse_triage_map "$TRIAGE_TIMEOUT_MAP" "$triage_class")")"
    if [ "$scaled_timeout" != "$COPILOT_TIMEOUT" ]; then
      log "issue #$num: run timeout for '$triage_class' -> ${scaled_timeout:-off} (baseline ${COPILOT_TIMEOUT:-off})"
    fi
    COPILOT_TIMEOUT="$scaled_timeout"
  fi

  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  [ -n "$coding_model" ] && copilot_args+=(--model "$coding_model")

  log "issue #$num: running copilot (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    _fail_issue "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
    return 1
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  local copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "issue #$num: copilot exited with code $copilot_rc"

  # Track what this prompt cost on the issue (AI Credits + Tokens Copilot
  # printed), before any early return, so every run is accounted for.
  _report_usage issue "$num" "$log_file" "$coding_model"

  # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt: fail
  # the issue so the retry / copilot-failed path applies and it is recorded in the
  # issue log, instead of committing whatever partial work was left behind.
  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    _fail_issue "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
    return 1
  fi

  # Copilot asked for more information instead of coding: relay the question to
  # the user and wait for their reply (handled, so return success without a PR).
  if [ -s "$question_file" ]; then
    _ask_issue "$num" "$question_file"
    return 0
  fi

  # Stage everything Copilot produced. It is told not to commit, but if it did
  # anyway `add -A` is a harmless no-op for already-committed files.
  git -C "$WORKSPACE_DIR" add -A

  # Ensure the work is committed *before* we ever try to open a PR. A commit can
  # fail in ways easy to miss when the output is discarded (no git identity, a
  # rejecting pre-commit hook, ...), which only later surfaces as the confusing
  # "No commits between main and <branch>" error from `gh pr create`. So commit
  # explicitly, capture the output, and fail the issue loudly if it does not
  # succeed rather than pressing on with nothing committed.
  if ! git -C "$WORKSPACE_DIR" diff --cached --quiet; then
    commit_text="$(build_commit_message "$num" "$title")"
    if ! commit_out="$(git -C "$WORKSPACE_DIR" commit -m "$commit_text" 2>&1)"; then
      printf '%s\n' "$commit_out" >>"$log_file"
      _fail_issue "$num" "$log_file" "git commit failed" "$commit_out"
      return 1
    fi
    printf '%s\n' "$commit_out" >>"$log_file"
  fi

  # Refresh our view of the default branch so we can sync against any work that
  # landed on it while Copilot was running.
  git -C "$WORKSPACE_DIR" fetch origin "$DEFAULT_BRANCH" >>"$log_file" 2>&1 || true

  ahead="$(git -C "$WORKSPACE_DIR" rev-list --count "origin/${DEFAULT_BRANCH}..HEAD" 2>/dev/null \
          || git -C "$WORKSPACE_DIR" rev-list --count "${DEFAULT_BRANCH}..HEAD" 2>/dev/null || echo 0)"

  if [ "${ahead:-0}" -gt 0 ]; then
    # Sync onto the latest default branch before pushing so the PR merges
    # cleanly and does not fall behind commits that landed during the run.
    # Prefer the remote-tracking ref, but fall back to FETCH_HEAD if it is
    # missing (e.g. a worktree with no fetch refspec) so we never rebase onto a
    # ref that does not exist.
    local sync_target="origin/${DEFAULT_BRANCH}" rebase_out reason detail
    git -C "$WORKSPACE_DIR" rev-parse --verify --quiet "$sync_target" >/dev/null 2>&1 || sync_target="FETCH_HEAD"
    if ! rebase_out="$(git -C "$WORKSPACE_DIR" rebase "$sync_target" 2>&1)"; then
      printf '%s\n' "$rebase_out" >>"$log_file"
      # A rebase conflict is not fatal (#193): unmerged paths mean the rebase
      # stopped on a real conflict, so hand those files to Copilot to resolve and
      # continue the rebase instead of failing the issue and interrupting the loop.
      # Anything else (an invalid upstream, a lock error, ...) never leaves
      # unmerged paths, so it is a genuine failure and still aborts + fails.
      if [ -n "$(git -C "$WORKSPACE_DIR" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        if resolve_rebase_conflicts "$num" "$log_file" "$sync_target"; then
          log "issue #$num: resolved rebase conflicts while syncing with ${DEFAULT_BRANCH}"
        else
          git -C "$WORKSPACE_DIR" rebase --abort >/dev/null 2>&1 || true
          _fail_issue "$num" "$log_file" \
            "failed to resolve rebase conflicts while syncing with ${DEFAULT_BRANCH}" "$rebase_out"
          return 1
        fi
      else
        git -C "$WORKSPACE_DIR" rebase --abort >/dev/null 2>&1 || true
        # Report the actual git error rather than a generic message.
        detail="$(printf '%s' "$rebase_out" | grep -iE 'fatal|error' | tail -n1)"
        if [ -n "$detail" ]; then
          reason="failed to sync with ${DEFAULT_BRANCH}: ${detail}"
        else
          reason="failed to sync with ${DEFAULT_BRANCH}"
        fi
        _fail_issue "$num" "$log_file" "$reason" "$rebase_out"
        return 1
      fi
    fi
    # The rebase may have dropped our commits entirely (their work already
    # landed on the default branch, or the commit turned out empty). Re-count
    # what is unique to the branch *after* syncing so we never push an empty
    # branch and then hit "No commits between main and <branch>" at PR creation.
    ahead="$(git -C "$WORKSPACE_DIR" rev-list --count "${sync_target}..HEAD" 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -le 0 ]; then
      _fail_issue "$num" "$log_file" "no commits to open a PR with after syncing with ${DEFAULT_BRANCH}"
      return 1
    fi
    log "issue #$num: $ahead commit(s), pushing branch $branch"
    if ! git -C "$WORKSPACE_DIR" push -u origin "$branch" >>"$log_file" 2>&1; then
      _fail_issue "$num" "$log_file" "git push failed"
      return 1
    fi
    pr_url="$(gh pr create --base "$DEFAULT_BRANCH" --head "$branch" \
                --title "$commit_msg" --body "$pr_body" 2>>"$log_file")"
    if [ -z "$pr_url" ]; then
      _fail_issue "$num" "$log_file" "gh pr create failed"
      return 1
    fi
    try_auto_merge "$pr_url" "$num" "$log_file"
    gh issue edit "$num" --add-label "$DONE_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
    log "issue #$num: DONE -> $pr_url"
    # Post a short "what was done" summary on the issue, written from this run's
    # session log by the light SUMMARY_MODEL (#161/#217). Best-effort and after the
    # DONE label so the log already records the branch/PR; never blocks the loop.
    _report_summary "$num" "$title" "$log_file" "$SUMMARY_MODEL"
    # If the PR already merged (auto-merge did an immediate merge) the remote
    # branch is dead weight; drop it now when configured. PRs that merge later
    # (GitHub native auto-merge, or a human merge) are handled by the periodic
    # sweep in the main loop instead.
    if [ "$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" = "MERGED" ]; then
      delete_remote_branch "$branch"
    fi
    cleanup_workspace "$branch"
    return 0
  fi

  _fail_issue "$num" "$log_file" "copilot produced no changes (rc=$copilot_rc)"
  return 1
}

# Handle a failed issue: comment with the error details (or a log tail as a
# fallback), mark it "copilot-failed", and clean up the branch. Failures are not
# retried automatically — the issue stays failed until a later user reply resumes
# it for a fresh attempt (see claim_next_reply_issue).
_fail_issue() {
  local num="$1" log_file="$2" reason="$3" details="${4:-}"
  # Prefer explicit details (the exact failing command's output) over the raw
  # log tail, which is mostly Copilot chatter and buries the real cause.
  local block
  if [ -n "$details" ]; then
    block="$details"
  else
    block="$(tail -n 20 "$log_file" 2>/dev/null)"
  fi

  log "issue #$num: FAILED - $reason"

  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh issue comment "$num" --body "$(printf 'copilot-loop failed: %s\n\n```\n%s\n```\n\n%s' \
    "$reason" "$block" "$FAILURE_MARKER")" >/dev/null 2>&1 || true

  # Stop here: mark the issue failed instead of re-queuing it, so a repeatedly
  # failing issue can never be retried in an endless loop.
  gh issue edit "$num" --add-label "$FAILED_LABEL" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1
  cleanup_workspace "$branch"
}

# --- Core: bootstrap a repo-level AGENTS.md ----------------------------------
# A fresh Copilot session has no memory, so without a repo-level AGENTS.md every
# run re-discovers the layout, build/test commands and conventions — repeated
# input-token cost across the whole backlog. Once per repo, when neither AGENTS.md
# nor .github/copilot-instructions.md exists, a single read-only Copilot pass
# writes a SHORT AGENTS.md (Copilot CLI auto-loads it into every later run) and
# opens it as its own PR, so future runs — and humans — start with that context.
# The generation is time-boxed (via run_copilot/COPILOT_TIMEOUT) and fully
# failure-safe: any problem is logged and swallowed so it can never block issue
# work.
# >>> agents-md helpers >>>
# True (rc 0) when the AGENTS.md bootstrap is disabled: an empty model or one of
# the explicit off spellings (so --agents-model off turns it off). Pure.
agents_md_disabled() {
  case "${1:-}" in
    ''|off|none|no|0|false) return 0 ;;
    *) return 1 ;;
  esac
}

# Generate AGENTS.md when the repo has none. Never returns non-zero and never
# leaves an uncommitted file behind: it either opens a PR with the new AGENTS.md
# or does nothing. Reads AGENTS_MODEL / DEFAULT_BRANCH / REPO_DIR / BRANCH_PREFIX
# and the workspace + run_copilot helpers, exactly like process_issue.
generate_agents_md() {
  # Opt-out (or no model configured): do nothing.
  agents_md_disabled "$AGENTS_MODEL" && return 0

  # Work from the latest default branch without checking it out. Fetch first so
  # the presence check and the new branch both see current state; fall back to
  # HEAD/FETCH_HEAD when origin/<default> cannot be resolved (e.g. a worktree
  # with no fetch refspec).
  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  local ref="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || ref="HEAD"

  # Skip entirely when the repo already ships agent context — either file is
  # auto-loaded by Copilot CLI, so generating another would only add cost.
  if git -C "$REPO_DIR" cat-file -e "${ref}:AGENTS.md" 2>/dev/null \
     || git -C "$REPO_DIR" cat-file -e "${ref}:.github/copilot-instructions.md" 2>/dev/null; then
    log "AGENTS.md: repo already has AGENTS.md or copilot-instructions.md; skipping bootstrap"
    return 0
  fi

  local branch="${BRANCH_PREFIX}agents-md"

  # Idempotent across passes and restarts: if the bootstrap branch is already on
  # origin, an earlier run opened its PR and it is just waiting to merge. Don't
  # open a duplicate.
  if [ -n "$(git -C "$REPO_DIR" ls-remote --heads origin "$branch" 2>/dev/null)" ]; then
    log "AGENTS.md: bootstrap branch $branch already on origin (PR open); skipping"
    return 0
  fi

  local log_file
  log_file="$LOG_DIR/agents-md-$(date '+%Y%m%d-%H%M%S').log"
  CURRENT_RUN_LOG="$log_file"
  log "AGENTS.md: none found; generating a concise one with ${AGENTS_MODEL} before working issues"

  local start="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$start" >/dev/null 2>&1 || start="FETCH_HEAD"
  if ! prepare_workspace "$branch" "$start"; then
    log "AGENTS.md: could not create work branch $branch; skipping bootstrap"
    CURRENT_RUN_LOG=""
    return 0
  fi

  local prompt
  prompt="$(cat <<'EOF'
You are bootstrapping this repository for autonomous coding agents.

Inspect the repository (read-only) and write a single, concise AGENTS.md file at
its root. AGENTS.md is auto-loaded into EVERY future agent run, so keep it SHORT:
aim for well under ~150 lines. Bloat here becomes a fixed per-run cost, so include
only high-signal, durable facts:
  - what the project is and its high-level architecture,
  - where the important code lives (key directories and files),
  - the exact build, test, and lint/format commands,
  - project-specific conventions an agent must follow.

Omit anything obvious, transient, or trivially rediscovered, and never include
secrets. Only create/write the AGENTS.md file — do NOT modify any other file, and
do NOT run git or gh (no commits, branches, or PRs); that is handled for you.
EOF
)"

  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  copilot_args+=(--model "$AGENTS_MODEL")

  log "AGENTS.md: running copilot (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    log "AGENTS.md: workspace '$WORKSPACE_DIR' vanished; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  local copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "AGENTS.md: copilot exited with code $copilot_rc"

  # A pinned model the CLI doesn't recognise (a typo, or one since retired) makes
  # copilot exit at once without writing anything, which would otherwise skip the
  # bootstrap silently on every pass. Retry once letting Copilot pick a model, so
  # a bad --agents-model degrades to "auto" instead of disabling the bootstrap.
  if [ "$copilot_rc" -ne 0 ] && [ "$AGENTS_MODEL" != "auto" ] \
     && grep -q 'from --model flag is not available' "$log_file" 2>/dev/null; then
    log "AGENTS.md: model '$AGENTS_MODEL' is not available; retrying with --model auto"
    copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none --model auto)
    if cd "$WORKSPACE_DIR" 2>/dev/null; then
      run_copilot "$log_file" "${copilot_args[@]}"
      copilot_rc=$COPILOT_RC
      cd "$REPO_DIR" 2>/dev/null || true
      log "AGENTS.md: copilot (--model auto) exited with code $copilot_rc"
    fi
  fi

  # A timed-out run (COPILOT_TIMEOUT exceeded) or one that produced no AGENTS.md
  # is not a failure of the loop — just skip so issue work is never blocked.
  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    log "AGENTS.md: generation timed out after ${COPILOT_TIMEOUT}; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  if [ ! -s "$WORKSPACE_DIR/AGENTS.md" ]; then
    log "AGENTS.md: copilot produced no AGENTS.md; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi

  # Commit only the AGENTS.md the run was asked for, then push and open a PR. Any
  # failure is logged and swallowed so the bootstrap can never block issue work.
  git -C "$WORKSPACE_DIR" add AGENTS.md >/dev/null 2>&1
  if git -C "$WORKSPACE_DIR" diff --cached --quiet 2>/dev/null; then
    log "AGENTS.md: nothing staged after generation; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  if ! git -C "$WORKSPACE_DIR" commit -m "Add AGENTS.md to front-load repo context for copilot-loop" >>"$log_file" 2>&1; then
    log "AGENTS.md: git commit failed; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  if ! git -C "$WORKSPACE_DIR" push -u origin "$branch" >>"$log_file" 2>&1; then
    log "AGENTS.md: git push failed; skipping bootstrap"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  local pr_url
  pr_url="$(gh pr create --base "$DEFAULT_BRANCH" --head "$branch" \
              --title "Add AGENTS.md to cut per-run exploration cost" \
              --body "$(printf 'Auto-generated by copilot-loop: a concise AGENTS.md so every future run — and humans — start with the repo layout, build/test/lint commands and conventions instead of re-discovering them each run.\n\nGenerated with model: %s.' "$AGENTS_MODEL")" 2>>"$log_file")"
  if [ -z "$pr_url" ]; then
    log "AGENTS.md: gh pr create failed; branch pushed but no PR opened"
    cleanup_workspace "$branch"
    CURRENT_RUN_LOG=""
    return 0
  fi
  try_auto_merge "$pr_url" "AGENTS.md" "$log_file"
  # Best-effort cost tracking on the bootstrap PR, mirroring the per-issue report.
  _report_usage pr "$pr_url" "$log_file" "$AGENTS_MODEL" 2>/dev/null || true
  log "AGENTS.md: bootstrap PR opened -> $pr_url"
  cleanup_workspace "$branch"
  CURRENT_RUN_LOG=""
  return 0
}
# <<< agents-md helpers <<<

# --- Issue files: create GitHub issues from markdown in issues/ --------------
# Each *.md file in ISSUES_DIR becomes one GitHub issue: the first H1 line is
# the title and everything after it is the body. A file is claimed by renaming
# "<name>.md" -> "<name>_pushing.md" before the issue is created, then deleted
# once the issue exists. By default created issues get the trigger label so the
# loop below picks them up; a "Label:" directive in the body overrides this (see
# issue_labels), including "Label: none" to file an unlabelled backlog issue that
# the loop leaves alone. If ISSUES_DIR is missing it is created with a
# TEMPLATE.md example, which is never turned into an issue.
#
# issue_labels is pure and covered by tests/issue-labels.test.sh (extracted
# between the markers), so keep the marker comments intact.
# >>> issue-label helpers >>>
# Decide the label(s) for an issue created from a markdown file. Reads an
# optional "Label:"/"Labels:" directive (first matching line wins, the key is
# case-insensitive) from the body and echoes the labels to apply as a
# comma-separated list. With no directive it echoes the given default (the
# trigger label) so existing files keep entering the queue. A value of "none",
# "no-label", "no_label", "nolabel", "-", or empty means "create with no label"
# and echoes nothing. Label values are kept verbatim because GitHub label names
# are case-sensitive.
# Usage: issue_labels <body> <default-label>
issue_labels() {
  local body="$1" default="$2" line val
  line="$(printf '%s\n' "$body" | grep -m1 -iE '^[[:space:]]*labels?[[:space:]]*:' 2>/dev/null)"
  if [ -z "$line" ]; then
    printf '%s\n' "$default"
    return
  fi
  val="$(printf '%s\n' "$line" \
         | sed -E 's/^[[:space:]]*[Ll][Aa][Bb][Ee][Ll][Ss]?[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//')"
  case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
    ''|none|no-label|no_label|nolabel|-) return ;;
    *) printf '%s\n' "$val" ;;
  esac
}
# <<< issue-label helpers <<<

process_issue_files() {
  if [ ! -d "$ISSUES_DIR" ]; then
    mkdir -p "$ISSUES_DIR" || { log "issue files: could not create $ISSUES_DIR"; return; }
    cat >"$ISSUES_DIR/TEMPLATE.md" <<'EOF'
# Title

Describe the task here. The first "# " heading becomes the issue title and
everything below it becomes the issue body.

Copy this file to a new name ending in .md and edit it; the copilot loop opens
a GitHub issue from it (labelled "ready") and then deletes the file.

Add a line like "Label: bug" to override the label, or "Label: none" to file the
issue with no label at all (an unlabelled backlog item the loop leaves alone).
List several with "Labels: bug, enhancement".

Add a line like "Wait for: #1" to hold this issue until issue #1 is closed
(resolved and merged). List several ("Wait for: #1, #2") and use "Blocked by:"
or "Depends on:" if you prefer. While it waits the issue is labelled "pending".
EOF
    log "issue files: created $ISSUES_DIR with TEMPLATE.md"
    return
  fi

  local f base pushing title body
  for f in "$ISSUES_DIR"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"

    # Never turn the template into an issue.
    [ "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" = "template.md" ] && continue

    # Claim the file by renaming it, unless a previous run already claimed it.
    case "$base" in
      *_pushing.md) pushing="$f" ;;
      *)
        pushing="${f%.md}_pushing.md"
        if ! mv "$f" "$pushing" 2>/dev/null; then
          log "issue files: could not claim $base"
          continue
        fi
        log "issue files: claimed $base -> $(basename "$pushing")"
        ;;
    esac

    # Title: first H1 heading; fall back to the file name.
    title="$(grep -m1 -E '^#[[:space:]]+' "$pushing" | sed -E 's/^#[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$title" ]; then
      title="$(basename "$pushing" .md)"
      title="${title%_pushing}"
    fi

    # Body: everything after the first H1; the whole file if there is no H1.
    if grep -qE '^#[[:space:]]+' "$pushing"; then
      body="$(awk 'seen{print} /^#[[:space:]]+/{seen=1}' "$pushing")"
    else
      body="$(cat "$pushing")"
    fi
    # Drop leading blank lines from the body.
    body="$(printf '%s\n' "$body" | sed -e '/./,$!d')"

    # Labels: honour an optional "Label:"/"Labels:" directive, defaulting to the
    # trigger label so existing files still enter the queue. An empty result
    # means the issue is created with no label at all. Custom labels are ensured
    # up front so gh does not fail on a not-yet-existing label.
    local labels l
    local -a label_args=()
    labels="$(issue_labels "$body" "$TRIGGER_LABEL")"
    if [ -n "$labels" ]; then
      local OLDIFS="$IFS"; IFS=','
      for l in $labels; do
        l="$(printf '%s' "$l" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [ -n "$l" ] || continue
        ensure_label "$l" "ededed" "Applied by copilot-loop from an issue file"
        label_args+=(--label "$l")
      done
      IFS="$OLDIFS"
    fi

    local created=0
    if [ "${#label_args[@]}" -gt 0 ]; then
      gh issue create --title "$title" --body "$body" "${label_args[@]}" >/dev/null 2>&1 && created=1
    else
      gh issue create --title "$title" --body "$body" >/dev/null 2>&1 && created=1
    fi
    if [ "$created" -eq 1 ]; then
      rm -f "$pushing"
      log "issue files: created issue \"$title\" and removed $(basename "$pushing")"
    else
      log "issue files: FAILED to create issue for \"$title\" (kept $(basename "$pushing"))"
    fi
  done
}

# Mark a PR conflict-resolution attempt failed: comment a log tail, label the PR
# so it is not retried forever, and tear down the workspace.
_fail_pr() {
  local num="$1" log_file="$2" reason="$3" tail_out
  log "PR #$num: FAILED to resolve conflicts - $reason"
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh pr comment "$num" --body "$(printf 'copilot-loop could not resolve merge conflicts: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  cleanup_workspace "$head"
}

# Mark a PR failing-checks fix attempt failed: comment a log tail, label the PR
# so it is not retried forever, and tear down the workspace. Mirrors _fail_pr.
_fail_pr_checks() {
  local num="$1" log_file="$2" reason="$3" tail_out
  log "PR #$num: FAILED to fix failing checks - $reason"
  tail_out="$(tail -n 20 "$log_file" 2>/dev/null)"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh pr comment "$num" --body "$(printf 'copilot-loop could not fix the failing checks: %s\n\n```\n%s\n```' \
    "$reason" "$tail_out")" >/dev/null 2>&1 || true
  gh pr edit "$num" --add-label "$CHECKS_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  cleanup_workspace "$head"
}

# Copilot needs more information: post its question to the issue, mark it
# "needs-info", and leave it for the user to answer. Discards any work in
# progress so the branch is clean for the eventual resume. maybe_ask_when_vague
# reuses this same needs-info flow, so tests/vague-triage.test.sh sources both
# verbatim -- keep the markers intact.
# >>> needs-info helpers >>>
_ask_issue() {
  local num="$1" qf="$2" question
  question="$(cat "$qf" 2>/dev/null)"
  log "issue #$num: needs more info, asking the user on the issue"
  gh issue comment "$num" \
    --body "$(printf '**copilot-loop needs more information to continue:**\n\n%s\n\n%s' \
      "$question" "$QUESTION_MARKER")" >/dev/null 2>&1 || true
  gh issue edit "$num" --add-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  rm -f "$qf"
  cleanup_workspace "$branch"
}

# Vagueness gate (issue #188), triage's "tight issues" cost lever automated.
# Before spending a coding run, let the cheap TRIAGE_MODEL judge whether the issue
# is specified well enough to implement; if it is genuinely too vague, post the
# clarifying question(s) via the existing needs-info flow (_ask_issue) and signal
# the caller to stop, so no coding run happens and the issue resumes normally once
# the author replies. Guardrails: it is a no-op (returns 1 -> proceed) when triage
# is off, when the thread already carries a question we posted (ask at most once,
# so a reply proceeds best-effort and never loops), or when an approved plan
# already pins the approach. Returns 0 when it asked (caller must stop, no coding
# run), 1 when the issue should proceed to coding.
maybe_ask_when_vague() {
  local num="$1" title="$2" body="$3" comments="$4" qf="$5" log_file="${6:-/dev/null}"
  local question

  [ -n "$TRIAGE_MODEL" ] || return 1
  comments_have_question "$comments" && return 1
  comments_have_plan "$comments" && return 1

  log "issue #$num: checking clarity with $TRIAGE_MODEL"
  question="$(triage_vagueness "$num" "$title" "$body" "$log_file")"
  if [ -z "$question" ]; then
    log "issue #$num: clear enough to implement -> proceeding"
    return 1
  fi

  log "issue #$num: too vague to implement confidently -> asking the author"
  printf '%s\n' "$question" >"$qf"
  _ask_issue "$num" "$qf"
  return 0
}
# <<< needs-info helpers <<<

# --- Core: plan a single issue (plan mode) ----------------------------------
# Instead of implementing the issue, ask Copilot for an implementation plan and
# post it on the issue for the user to review. No branch is pushed and no PR is
# opened: Copilot runs in the issue's workspace (so it can read the real code to
# ground the plan) but is told to make no code changes and to write only the plan
# to a dedicated file, which the loop then posts as a comment. The issue is then
# labelled PLAN_REVIEW_LABEL and left alone until the user adds the trigger label
# to run the approved plan (process_issue picks it up and follows it — see
# comments_have_plan). Returns 0 when a plan was posted, 1 on failure. Mirrors
# process_issue's setup so the two stay consistent.
plan_issue() {
  local num="$1"
  local title body slug branch log_file comments comments_block plan_file plan
  local coding_model copilot_rc

  { IFS= read -r -d '' title; IFS= read -r -d '' body; IFS= read -r -d '' comments; } < <(
    gh issue view "$num" --json title,body,comments \
      --jq '[.title, (.body // ""), ([.comments[] | "--- @" + (.author.login // "ghost") + " wrote:\n" + (.body // "")] | join("\n"))] | join("\u0000")' 2>/dev/null)
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  [ -n "$slug" ] || slug="issue"
  branch="${BRANCH_PREFIX}${num}-${slug}"
  log_file="$LOG_DIR/issue-${num}-plan-$(date '+%Y%m%d-%H%M%S').log"
  CURRENT_RUN_LOG="$log_file"

  # Publish which issue this worker (pid) is on so the TUI can show its pid on
  # that issue's row while it drafts the plan (#214).
  set_worker_issue "$num"

  log "issue #$num on $REPO_SLUG: planning: $title"

  # Prepare a workspace so Copilot can read the repository while drafting the
  # plan. The branch is never pushed; it (and its worktree) is cleaned up below.
  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  local start="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$start" >/dev/null 2>&1 || start="FETCH_HEAD"
  if ! prepare_workspace "$branch" "$start"; then
    _fail_issue "$num" "$log_file" "could not create plan workspace $branch"
    return 1
  fi

  # Copilot writes the plan here (inside the gitignored control dir of the
  # workspace, so it is never part of any diff). Cleared defensively.
  plan_file="$WORKSPACE_DIR/.copilot-loop/issue-${num}.plan.md"
  mkdir -p "$(dirname "$plan_file")" 2>/dev/null || true
  rm -f "$plan_file"

  log "issue #$num: drafting plan on branch $branch"
  set_terminal_title "$branch (plan)"

  comments_block=""
  [ -n "$comments" ] && comments_block=$'\n\nConversation so far (most recent last):\n'"$comments"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository. Your task is to PLAN the work for a GitHub
issue — not to implement it.

Issue #${num}: ${title}

${body}${comments_block}

Investigate the repository as needed to understand the code, then write a clear,
actionable implementation plan for resolving this issue. Do NOT make any code
changes, do NOT run git, and do NOT open a pull request — this is a planning step
only. The plan will be posted on the issue for a human to review before any code
is written, so make it self-contained and easy to follow: summarise the approach,
list the concrete steps and the files/functions each step touches, note the tests
to add, and call out risks, assumptions, or open questions.

Write the plan as GitHub-flavoured Markdown to this file (create it, overwriting
any existing content) and write nothing else to disk:
  ${plan_file}
EOF
)"

  coding_model="$COPILOT_MODEL"
  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  [ -n "$coding_model" ] && copilot_args+=(--model "$coding_model")

  log "issue #$num: running copilot to draft plan (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    _fail_issue "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run"
    return 1
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "issue #$num: copilot (plan) exited with code $copilot_rc"

  _report_usage issue "$num" "$log_file" "$coding_model"

  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    _fail_issue "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} while planning (rc=$copilot_rc)"
    return 1
  fi

  if [ ! -s "$plan_file" ]; then
    _fail_issue "$num" "$log_file" "copilot produced no plan (rc=$copilot_rc)"
    return 1
  fi

  plan="$(cat "$plan_file" 2>/dev/null)"
  log "issue #$num: plan drafted, posting for review"
  # shellcheck disable=SC2016  # %s/\n are printf specifiers, single quotes intended
  gh issue comment "$num" --body "$(printf '**copilot-loop drafted an implementation plan for this issue.**\n\nReview the plan below. When you are happy with it, add the `%s` label and the loop will implement it. To change the plan, leave a comment with your adjustments before adding `%s` — the most recent plan in the thread is what gets executed.\n\n---\n\n%s\n\n%s' \
    "$TRIGGER_LABEL" "$TRIGGER_LABEL" "$plan" "$PLAN_MARKER")" >/dev/null 2>&1 || true
  gh issue edit "$num" --add-label "$PLAN_REVIEW_LABEL" >/dev/null 2>&1 || true
  gh issue edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  log "issue #$num: PLAN posted -> waiting for user to add '$TRIGGER_LABEL'"
  cleanup_workspace "$branch"
  return 0
}

# --- Issue dependencies: "Wait for: #N" --------------------------------------
# An issue can declare that it must not be started until one or more other
# issues are finished by putting a line like "Wait for: #1" in its body. The
# loop then keeps that issue in the queue until every issue it names is CLOSED.
# A PR that closes the blocker, once merged, closes the issue, so CLOSED is
# exactly "resolved and merged". "Blocked by:" and "Depends on:" are accepted
# as synonyms, several "#N" may be listed on one line, and matching is
# case-insensitive. While an issue is held back this way it is labelled
# "pending" so the wait is visible in GitHub; the label is removed once every
# dependency closes (or the issue is claimed for work).
#
# The two functions below are covered by tests/wait-for.test.sh, which extracts
# them between the markers, so keep the marker comments intact.
# >>> wait-for helpers >>>
# Echo, one per line (ascending, de-duplicated), the issue numbers a body
# declares it is waiting for. Empty output means no declared dependencies.
issue_wait_for() {
  local body="$1"
  printf '%s\n' "$body" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -nE 's/^.*(wait[[:space:]]+for|blocked[[:space:]]+by|depends[[:space:]]+on)[[:space:]]*:?[[:space:]]*//p' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | sort -n -u
}

# Echo, one per line, the still-open issues that block the given issue: those it
# declares it is waiting for that are not yet CLOSED. Self-references and issue
# numbers that cannot be looked up are ignored so the queue can never wedge on a
# stale or bad reference. Empty output means nothing is blocking.
# Usage: issue_open_blockers <self-number> <body>
issue_open_blockers() {
  local self="$1" body="$2" dep state
  for dep in $(issue_wait_for "$body"); do
    [ "$dep" = "$self" ] && continue
    state="$(gh issue view "$dep" --json state --jq '.state' 2>/dev/null)"
    [ "$state" = "OPEN" ] && printf '%s\n' "$dep"
  done
}
# <<< wait-for helpers <<<

# Format a whitespace-separated list of issue numbers as "#1, #2" for logs.
_fmt_blockers() {
  local b out=""
  for b in $1; do
    if [ -n "$out" ]; then out="$out, #$b"; else out="#$b"; fi
  done
  printf '%s' "$out"
}

# --- Pending label: mark issues waiting on a dependency ----------------------
# An issue held back by an open dependency ("Wait for: #N") is labelled
# "pending" so the wait is visible in GitHub without reading the body. The
# label is reconciled every loop pass and removed as soon as every dependency
# has closed (or the issue is claimed for work).
#
# pending_action is pure and covered by tests/pending-label.test.sh (extracted
# between the markers), so keep the marker comments intact.
# >>> pending-label helpers >>>
# Decide what to do with the pending label for one issue. Inputs: <blockers>
# (non-empty when the issue is waiting on at least one open dependency) and
# <has_pending> ("true" when it already carries the label). Echoes "add" when
# it should gain the label, "remove" when it should lose it, and nothing when
# it is already in the right state.
pending_action() {
  local blockers="$1" has_pending="$2"
  if [ -n "$blockers" ] && [ "$has_pending" != "true" ]; then
    printf 'add\n'
  elif [ -z "$blockers" ] && [ "$has_pending" = "true" ]; then
    printf 'remove\n'
  fi
}
# <<< pending-label helpers <<<

# Reconcile the pending label across the whole open working set (issues carrying
# the trigger, plan, needs-info or failed label) so it always reflects reality:
# mark an issue "pending" while it waits for an open dependency and unmark it once
# nothing blocks it. Only issues whose state actually changed are edited, and gh
# failures never abort the loop. Relies on issue_open_blockers and pending_action.
reconcile_pending_labels() {
  local nums n body blockers has_pending
  nums="$( { gh issue list --state open --label "$TRIGGER_LABEL"    --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$PLAN_LABEL"       --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$NEEDS_INFO_LABEL" --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$FAILED_LABEL"     --limit 1000 --json number --jq '.[].number' 2>/dev/null; } \
           | sort -n -u )"
  for n in $nums; do
    body="$(gh issue view "$n" --json body --jq '.body' 2>/dev/null)"
    blockers="$(issue_open_blockers "$n" "$body")"
    has_pending="$(gh issue view "$n" --json labels \
                    --jq 'any(.labels[]; .name == "'"$PENDING_LABEL"'")' 2>/dev/null)"
    case "$(pending_action "$blockers" "$has_pending")" in
      add)
        gh issue edit "$n" --add-label "$PENDING_LABEL" >/dev/null 2>&1 || true
        log "issue #$n: waiting for $(_fmt_blockers "$blockers") to close; marked $PENDING_LABEL" ;;
      remove)
        gh issue edit "$n" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
        log "issue #$n: dependencies resolved; removed $PENDING_LABEL" ;;
    esac
  done
}

# Atomically find and claim the next ready issue, protected by GitHub lock.
# Returns the issue number on success, empty string if none available.
# This prevents multiple instances from selecting the same issue.
claim_next_ready_issue() {
  local n body blockers issue=""
  acquire_github_lock || return 1

  # Ready issues oldest first (lowest number == earliest created). Fetch each
  # issue's body in the same list call (NUL-separated number/body pairs) so we no
  # longer spend one `gh issue view` per queued issue. Walk them in order and
  # claim the first that is not blocked by an unresolved dependency (see
  # issue_open_blockers). A blocked issue keeps its trigger label so it is
  # reconsidered on a later pass once its blockers close.
  while IFS= read -r -d '' n && IFS= read -r -d '' body; do
    blockers="$(issue_open_blockers "$n" "$body")"
    if [ -n "$blockers" ]; then
      log "issue #$n: blocked, waiting for $(_fmt_blockers "$blockers") to close; skipping" >&2
      continue
    fi
    # Claim it immediately: add in-progress, remove trigger labels.
    # Do this WHILE HOLDING THE LOCK so no other instance can select it.
    issue="$n"
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$TRIGGER_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
    # If this issue was planned first, the trigger label the user added to run the
    # plan is what got us here; drop the now-stale review label as we start work.
    gh issue edit "$issue" --remove-label "$PLAN_REVIEW_LABEL" >/dev/null 2>&1 || true
    break
  # Emit one joined string, not a stream: gh/jq append a newline after every
  # streamed result, and with NUL-delimited records that newline leaks into the
  # front of the next number field ("\n12"), corrupting the branch name and
  # failing every issue after the first. join("") keeps the stream NUL-only.
  done < <(gh issue list --state open --label "$TRIGGER_LABEL" --limit 1000 \
             --json number,body \
             --jq 'sort_by(.number) | [.[] | (.number|tostring) + "\u0000" + (.body // "") + "\u0000"] | join("")' 2>/dev/null)

  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}

# Atomically find and claim the next issue that should be PLANNED (carries the
# plan label), protected by the GitHub lock. Mirrors claim_next_ready_issue but
# for PLAN_LABEL: oldest first, skipping issues blocked by an open dependency,
# and claims by adding "in-progress" and removing the plan/pending labels so no
# other instance grabs the same one. Returns the issue number on success, empty
# string if none available. Extracted verbatim by tests/plan-mode.test.sh, so
# keep the marker comments intact.
# >>> plan-issue helpers >>>
claim_next_plan_issue() {
  local n body blockers issue=""
  acquire_github_lock || return 1

  while IFS= read -r -d '' n && IFS= read -r -d '' body; do
    blockers="$(issue_open_blockers "$n" "$body")"
    if [ -n "$blockers" ]; then
      log "issue #$n: blocked, waiting for $(_fmt_blockers "$blockers") to close; skipping" >&2
      continue
    fi
    # Claim it while HOLDING THE LOCK: add in-progress and drop the plan label so
    # the plan is generated exactly once and no other instance re-plans it. The
    # review label is added later, once the plan has been posted.
    issue="$n"
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PLAN_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
    break
  # See claim_next_ready_issue for why the records are emitted as one NUL-only
  # joined string rather than a newline-terminated stream.
  done < <(gh issue list --state open --label "$PLAN_LABEL" --limit 1000 \
             --json number,body \
             --jq 'sort_by(.number) | [.[] | (.number|tostring) + "\u0000" + (.body // "") + "\u0000"] | join("")' 2>/dev/null)

  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}
# <<< plan-issue helpers <<<

# Log the open issues currently carrying the trigger label (the ready queue),
# oldest first, so the operator can see the backlog before the next issue is
# claimed. Informational only and silent when the queue is empty (the later
# "no ready issues" message covers that case); safe to call without the lock.
log_ready_issues() {
  local lines count
  lines="$(gh issue list --state open --label "$TRIGGER_LABEL" \
             --limit 1000 --json number,title \
             --jq 'sort_by(.number) | .[] | "#\(.number) \(.title)"' 2>/dev/null)"
  [ -n "$lines" ] || return 0
  count="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
  log "ready issues ($count):"
  printf '%s\n' "$lines" | while IFS= read -r line; do
    log "  $line"
  done
}

# Atomically find and claim the next reply issue, protected by GitHub lock.
# Handles both "needs-info" (a pending question) and "copilot-failed" (a failed
# issue) whose latest comment came from a human. Returns the issue number on
# success, empty string if none available.
claim_next_reply_issue() {
  [ -n "$BOT_LOGIN" ] || return 1
  
  local nums n last_author body blockers issue=""
  acquire_github_lock || return 1
  
  # Both labels mean "blocked, waiting on the user"; a human reply resumes them.
  # Sorted ascending (by number == creation order) so oldest replied issue first.
  nums="$( { gh issue list --state open --label "$NEEDS_INFO_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null;
             gh issue list --state open --label "$FAILED_LABEL" \
               --limit 1000 --json number --jq '.[].number' 2>/dev/null; } \
           | sort -n -u )"
  for n in $nums; do
    # One view call per candidate for both the last comment's author and the
    # body (NUL-separated) instead of two separate `gh issue view` calls.
    { IFS= read -r -d '' last_author; IFS= read -r -d '' body; } < <(
      gh issue view "$n" --json comments,body \
        --jq '[(.comments[-1].author.login // ""), (.body // "")] | join("\u0000")' 2>/dev/null)
    if [ -z "$last_author" ] || [ "$last_author" = "$BOT_LOGIN" ]; then continue; fi
    # Honour the same dependency gate as fresh issues: do not resume an issue
    # while an issue it declares it is waiting for is still open.
    blockers="$(issue_open_blockers "$n" "$body")"
    if [ -n "$blockers" ]; then
      log "issue #$n: replied but blocked, waiting for $(_fmt_blockers "$blockers") to close; skipping" >&2
      continue
    fi
    # Found one; claim it before releasing the lock
    issue="$n"
    gh issue edit "$issue" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$NEEDS_INFO_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$FAILED_LABEL" >/dev/null 2>&1 || true
    gh issue edit "$issue" --remove-label "$PENDING_LABEL" >/dev/null 2>&1 || true
    break
  done
  
  release_github_lock
  [ -n "$issue" ] && printf '%s\n' "$issue"
  [ -n "$issue" ]
}

# --- Core: resolve merge conflicts on a single PR ---------------------------
# Merges the PR's base branch into its head branch; if that conflicts, hands the
# conflicted files to Copilot to resolve, then commits and pushes so the PR
# becomes mergeable again. Returns 0 on success, 1 on failure.
resolve_pr_conflicts() {
  local num="$1"
  local head base title log_file conflicts copilot_rc

  # One API round-trip for the PR's head branch, base branch and title (all
  # single-line) instead of three separate `gh pr view` calls.
  { IFS= read -r -d '' head; IFS= read -r -d '' base; IFS= read -r -d '' title; } < <(
    gh pr view "$num" --json headRefName,baseRefName,title \
      --jq '[.headRefName, .baseRefName, .title] | join("\u0000")' 2>/dev/null)
  [ -n "$base" ] || base="$DEFAULT_BRANCH"
  log_file="$LOG_DIR/pr-${num}-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-PR log so the TUI's output panel
  # shows the loop's narration alongside Copilot's transcript (#126). Cleared at
  # the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  if [ -z "$head" ]; then
    log "PR #$num: could not determine head branch, skipping"
    gh pr edit "$num" --add-label "$CONFLICT_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
    gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    return 1
  fi

  log "PR #$num has conflicts with $base: $title"

  # Base a fresh workspace on the PR head branch, without ever checking out the
  # default branch. Then merge the base branch into it so any conflicts surface
  # here for Copilot to resolve.
  git -C "$REPO_DIR" fetch origin >>"$log_file" 2>&1 || true
  if ! prepare_workspace "$head" "origin/$head"; then
    _fail_pr "$num" "$log_file" "could not check out PR head branch '$head'"
    return 1
  fi

  # Surface the PR branch on the terminal tab/window title before Copilot starts.
  log "PR #$num: working on branch $head"
  set_terminal_title "$head"

  # Merge the base branch. A clean merge means the conflict was already resolved
  # upstream; otherwise git leaves conflict markers for Copilot to fix.
  if git -C "$WORKSPACE_DIR" merge --no-edit "origin/$base" >>"$log_file" 2>&1; then
    log "PR #$num: merged $base with no conflicts to resolve"
  else
    conflicts="$(git -C "$WORKSPACE_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
    log "PR #$num: resolving conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')"

    local prompt
    prompt="$(cat <<EOF
You are working in a git repository. Merging branch "${base}" into branch
"${head}" (pull request #${num}) produced conflicts that must be resolved.

These files contain git conflict markers (<<<<<<<, =======, >>>>>>>):
${conflicts}

Resolve every conflict so the result is correct and preserves the intent of both
branches, then remove all conflict markers. Run any build or test commands needed
to verify your work. Do NOT run git commit, git merge, git push, or create
branches — those steps are handled automatically outside this session. Only edit
files to resolve the conflicts and verify.
EOF
)"
    local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
    [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

    log "PR #$num: running copilot to resolve conflicts (log: $log_file)"
    if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
      _fail_pr "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
      return 1
    fi
    run_copilot "$log_file" "${copilot_args[@]}"
    copilot_rc=$COPILOT_RC
    cd "$REPO_DIR" 2>/dev/null || true
    log "PR #$num: copilot exited with code $copilot_rc"

    # Track what this conflict-resolution prompt cost on the PR.
    _report_usage pr "$num" "$log_file" "$COPILOT_MODEL"

    # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt.
    if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
      _fail_pr "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
      return 1
    fi

    # Bail out if Copilot left conflict markers behind in any conflicted file.
    local f unresolved=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$WORKSPACE_DIR/$f" ] && grep -qE '^(<{7}|>{7})' "$WORKSPACE_DIR/$f" && unresolved="$unresolved $f"
    done <<< "$conflicts"
    if [ -n "$unresolved" ]; then
      _fail_pr "$num" "$log_file" "conflict markers still present in:$unresolved"
      return 1
    fi

    git -C "$WORKSPACE_DIR" add -A
    git -C "$WORKSPACE_DIR" commit --no-edit >/dev/null 2>&1 \
      || git -C "$WORKSPACE_DIR" commit -m "Merge $base into $head to resolve conflicts (#$num)" >/dev/null 2>&1
  fi

  if ! git -C "$WORKSPACE_DIR" push origin "HEAD:$head" >>"$log_file" 2>&1; then
    _fail_pr "$num" "$log_file" "git push failed"
    return 1
  fi

  gh pr comment "$num" \
    --body "copilot-loop resolved the merge conflicts with \`$base\`." >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  log "PR #$num: conflicts resolved and pushed"
  cleanup_workspace "$head"
  return 0
}

# Echo, comma-joined, the names of a PR's failing CI checks (an empty string when
# none). A check is failing when it is a completed CheckRun with a failing
# conclusion or a StatusContext in a failing state — the same predicate
# next_failing_checks_pr selects on.
pr_failing_check_names() {
  local num="$1"
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell expansion — keep single quotes
  gh pr view "$num" --json statusCheckRollup --jq '
    [ .statusCheckRollup[]? as $c
      | select(
          ($c.__typename == "CheckRun" and (["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c.conclusion)))
          or ($c.__typename == "StatusContext" and (["FAILURE","ERROR"] | index($c.state)))
        )
      | ($c.name // $c.context // "check")
    ] | unique | join(", ")' 2>/dev/null
}

# --- Core: fix a single PR's failing CI checks ------------------------------
# Checks out the PR head branch and hands Copilot the list of failing checks to
# investigate and fix (verifying locally), then commits and pushes so CI re-runs.
# If Copilot makes no changes it cannot fix them, so the PR is labelled
# "checks-unresolved" rather than pushed empty and re-grabbed forever. Returns 0
# on success, 1 on failure.
resolve_pr_check_failures() {
  local num="$1"
  local head base title log_file failing copilot_rc

  # One API round-trip for the PR's head branch, base branch and title.
  { IFS= read -r -d '' head; IFS= read -r -d '' base; IFS= read -r -d '' title; } < <(
    gh pr view "$num" --json headRefName,baseRefName,title \
      --jq '[.headRefName, .baseRefName, .title] | join("\u0000")' 2>/dev/null)
  [ -n "$base" ] || base="$DEFAULT_BRANCH"
  log_file="$LOG_DIR/pr-${num}-checks-$(date '+%Y%m%d-%H%M%S').log"
  # Mirror this run's status lines into the per-PR log so the TUI's output panel
  # shows the loop's narration alongside Copilot's transcript (#126). Cleared at
  # the top of the main loop.
  CURRENT_RUN_LOG="$log_file"

  if [ -z "$head" ]; then
    log "PR #$num: could not determine head branch, skipping"
    gh pr edit "$num" --add-label "$CHECKS_UNRESOLVED_LABEL" >/dev/null 2>&1 || true
    gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
    return 1
  fi

  failing="$(pr_failing_check_names "$num")"
  log "PR #$num has failing checks (${failing:-unknown}): $title"

  # Base a fresh workspace on the PR head branch, without ever checking out the
  # default branch, so Copilot fixes the failures on the PR's own branch.
  git -C "$REPO_DIR" fetch origin >>"$log_file" 2>&1 || true
  if ! prepare_workspace "$head" "origin/$head"; then
    _fail_pr_checks "$num" "$log_file" "could not check out PR head branch '$head'"
    return 1
  fi

  # Surface the PR branch on the terminal tab/window title before Copilot starts.
  log "PR #$num: working on branch $head"
  set_terminal_title "$head"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository on branch "${head}" (pull request #${num}).
Its continuous-integration checks are failing: ${failing:-unknown}.

Investigate why these checks fail and fix the code so they pass. Run the relevant
build, test, or lint commands locally to reproduce each failure and confirm your
fix. Do NOT run git commit, git push, or create branches — those steps are handled
automatically outside this session. Only edit files and verify.
EOF
)"
  local -a copilot_args=(-p "$prompt" --allow-all-tools -C "$WORKSPACE_DIR" --add-dir "$WORKSPACE_DIR" --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  log "PR #$num: running copilot to fix failing checks (log: $log_file)"
  if ! cd "$WORKSPACE_DIR" 2>/dev/null; then
    _fail_pr_checks "$num" "$log_file" "workspace '$WORKSPACE_DIR' vanished before copilot could run (refusing to edit $REPO_DIR)"
    return 1
  fi
  run_copilot "$log_file" "${copilot_args[@]}"
  copilot_rc=$COPILOT_RC
  cd "$REPO_DIR" 2>/dev/null || true
  log "PR #$num: copilot exited with code $copilot_rc"

  # Track what this fix prompt cost on the PR.
  _report_usage pr "$num" "$log_file" "$COPILOT_MODEL"

  # A timed-out run (COPILOT_TIMEOUT exceeded, rc 124) is a failed attempt.
  if copilot_run_timed_out "$COPILOT_TIMEOUT" "$copilot_rc"; then
    _fail_pr_checks "$num" "$log_file" "copilot timed out after ${COPILOT_TIMEOUT} (rc=$copilot_rc)"
    return 1
  fi

  # No changes means Copilot could not fix the checks. Give up (label so it is not
  # retried forever) instead of pushing an empty commit and re-grabbing next pass.
  if [ -z "$(git -C "$WORKSPACE_DIR" status --porcelain 2>/dev/null)" ]; then
    _fail_pr_checks "$num" "$log_file" "copilot made no changes to fix the failing checks"
    return 1
  fi

  git -C "$WORKSPACE_DIR" add -A
  if ! git -C "$WORKSPACE_DIR" commit -m "Fix failing checks on $head (#$num)" >/dev/null 2>&1; then
    _fail_pr_checks "$num" "$log_file" "git commit failed"
    return 1
  fi

  if ! git -C "$WORKSPACE_DIR" push origin "HEAD:$head" >>"$log_file" 2>&1; then
    _fail_pr_checks "$num" "$log_file" "git push failed"
    return 1
  fi

  gh pr comment "$num" \
    --body "copilot-loop pushed a fix for the failing checks (${failing:-unknown})." >/dev/null 2>&1 || true
  gh pr edit "$num" --remove-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  log "PR #$num: pushed a fix for failing checks"
  cleanup_workspace "$head"
  return 0
}

# >>> mergeability helpers >>>
# GitHub computes a PR's mergeable state asynchronously: right after a PR is
# opened, pushed to, or its base branch moves, `mergeable` is reported as UNKNOWN
# until a background job finishes. next_conflicted_pr only matches CONFLICTING, so
# a PR that is really in conflict but not yet evaluated would be skipped and the
# loop would start a ready issue with the conflict still open. Waiting here for
# GitHub to finish computing makes the "resolve conflicts before picking up new
# work" guarantee reliable instead of racing the evaluation.

# Echo the numbers (one per line) of open PRs targeting the default branch whose
# mergeability GitHub has not finished computing (UNKNOWN). Empty output means
# every open PR has been evaluated.
unknown_mergeability_prs() {
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable \
    --jq '.[] | select(.mergeable == "UNKNOWN") | .number' 2>/dev/null
}

# Block (bounded) until no open PR is left with UNKNOWN mergeability, so the
# conflict check that follows sees accurate state. Each pass nudges GitHub to
# (re)compute every still-unknown PR by viewing it — the documented way to force
# the background evaluation. MERGEABILITY_WAIT_ATTEMPTS=0 disables the wait and a
# PR stuck UNKNOWN never blocks the loop past the attempt budget.
ensure_pr_mergeability_known() {
  local attempts="$MERGEABILITY_WAIT_ATTEMPTS" delay="$MERGEABILITY_WAIT_SECONDS"
  local i unknown count n
  [ "$attempts" -gt 0 ] 2>/dev/null || return 0
  for (( i=1; i<=attempts; i++ )); do
    unknown="$(unknown_mergeability_prs)"
    [ -n "$unknown" ] || return 0
    count="$(printf '%s\n' "$unknown" | grep -c .)"
    log "waiting for GitHub to compute mergeability of $count open PR(s) before the conflict check (attempt $i/$attempts)"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      gh pr view "$n" --json mergeable >/dev/null 2>&1 || true
    done <<< "$unknown"
    [ "$i" -lt "$attempts" ] && sleep "$delay"
  done
  return 0
}
# <<< mergeability helpers <<<

# >>> conflict-pr helpers >>>
# Echo the number of the lowest-numbered open PR targeting the default branch
# whose merge is CONFLICTING, skipping any already marked unresolved or already
# claimed (in-progress) by another instance. Returns 1 (no output) when no PR
# needs conflict resolution.
next_conflicted_pr() {
  local jq_filter
  jq_filter='[.[] | select(.mergeable == "CONFLICTING")'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CONFLICT_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$INPROGRESS_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | .number] | sort | .[0] // empty'
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable,labels --jq "$jq_filter" 2>/dev/null
}

# Atomically select and claim the next conflicted PR, protected by the GitHub
# lock, so two instances never resolve the same PR (which would collide on the
# shared worktree path and race each other's pushes). Marks the PR in-progress
# while holding the lock; the resolve/fail paths clear that label. Echoes the PR
# number on success, nothing when there is no PR to work.
claim_next_conflicted_pr() {
  local pr=""
  acquire_github_lock || return 1
  pr="$(next_conflicted_pr)"
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  fi
  release_github_lock
  [ -n "$pr" ] && printf '%s\n' "$pr"
  [ -n "$pr" ]
}
# <<< conflict-pr helpers <<<

# >>> failing-checks-pr helpers >>>
# Echo the number of the lowest-numbered open PR targeting the default branch
# whose CI checks are failing, skipping any that is conflicting (handled by the
# conflict path first), already marked unresolved (conflict or checks), or already
# claimed (in-progress) by another instance. A check is failing when it is a
# completed CheckRun with a failing conclusion or a StatusContext in a failing
# state — pending/successful/skipped checks are ignored so a PR whose CI is still
# running is left alone. Returns 1 (no output) when no PR needs a check fix.
next_failing_checks_pr() {
  local jq_filter
  jq_filter='[.[] | select(.mergeable != "CONFLICTING")'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CHECKS_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$CONFLICT_UNRESOLVED_LABEL"'")) | not)'
  jq_filter="$jq_filter"' | select(([.labels[].name] | index("'"$INPROGRESS_LABEL"'")) | not)'
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell expansion — keep single quotes
  jq_filter="$jq_filter"' | select([.statusCheckRollup[]? as $c | select(($c.__typename == "CheckRun" and (["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c.conclusion))) or ($c.__typename == "StatusContext" and (["FAILURE","ERROR"] | index($c.state))))] | length > 0)'
  jq_filter="$jq_filter"' | .number] | sort | .[0] // empty'
  gh pr list --state open --base "$DEFAULT_BRANCH" \
    --json number,mergeable,labels,statusCheckRollup --jq "$jq_filter" 2>/dev/null
}

# Atomically select and claim the next PR with failing checks, protected by the
# GitHub lock, so two instances never fix the same PR (which would collide on the
# shared worktree path and race each other's pushes). Marks the PR in-progress
# while holding the lock; the resolve/fail paths clear that label. Echoes the PR
# number on success, nothing when there is no PR to work.
claim_next_failing_pr() {
  local pr=""
  acquire_github_lock || return 1
  pr="$(next_failing_checks_pr)"
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --add-label "$INPROGRESS_LABEL" >/dev/null 2>&1 || true
  fi
  release_github_lock
  [ -n "$pr" ] && printf '%s\n' "$pr"
  [ -n "$pr" ]
}
# <<< failing-checks-pr helpers <<<

# --- Self-update: pull the loop code and restart when it changed --------------
# Before tackling each iteration, refresh this script from the default branch so
# the loop always runs the latest code. When the upstream copy differs from the
# committed baseline, fast-forward the checkout (or refresh just this file when
# the default branch is not checked out) and re-exec. No-op when self-update is
# off, the script is untracked, or nothing changed upstream. Never clobbers local
# uncommitted edits to the script.
self_update() {
  [ "$SELF_UPDATE" = 1 ] || return 0
  [ -n "$SCRIPT_REL" ] || return 0

  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || return 0
  local upstream="origin/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$upstream" >/dev/null 2>&1 || return 0

  # Has the script changed upstream? Compare the committed baseline (the local
  # default branch, or HEAD when it is absent) with the upstream copy, so local
  # uncommitted edits to the script never trigger a restart on their own.
  local local_ref="refs/heads/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 || local_ref="HEAD"
  local base_hash new_hash
  base_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${local_ref}:${SCRIPT_REL}" 2>/dev/null || true)"
  new_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "${upstream}:${SCRIPT_REL}" 2>/dev/null || true)"
  [ -n "$new_hash" ] || return 0
  [ "$new_hash" != "$base_hash" ] || return 0

  log "loop code changed on $DEFAULT_BRANCH upstream; updating and restarting"

  local cur_branch updated=0
  cur_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ "$cur_branch" = "$DEFAULT_BRANCH" ]; then
    # On the default branch: fast-forward the whole checkout. git refuses (safely)
    # when local changes would be overwritten, leaving the running code intact.
    git -C "$REPO_DIR" merge --ff-only "$upstream" >/dev/null 2>&1 && updated=1
  fi

  if [ "$updated" != 1 ]; then
    # Default branch not checked out (e.g. detached in --no-worktrees mode) or the
    # fast-forward was refused: refresh just this script, but never clobber local
    # uncommitted edits to it.
    local work_hash head_hash
    work_hash="$(git hash-object "$SCRIPT_PATH" 2>/dev/null || true)"
    head_hash="$(git -C "$REPO_DIR" rev-parse --verify --quiet "HEAD:${SCRIPT_REL}" 2>/dev/null || true)"
    if [ -n "$head_hash" ] && [ -n "$work_hash" ] && [ "$work_hash" != "$head_hash" ]; then
      log "local changes to $SCRIPT_REL; skipping self-update"
      return 0
    fi
    local tmp="${SCRIPT_PATH}.selfupdate.$$"
    if ! git -C "$REPO_DIR" show "${upstream}:${SCRIPT_REL}" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    chmod +x "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$SCRIPT_PATH" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    # Advance the local default branch pointer when it fast-forwards, so the next
    # iteration sees the baseline as current instead of re-detecting the change.
    if [ "$local_ref" = "refs/heads/${DEFAULT_BRANCH}" ] \
       && git -C "$REPO_DIR" merge-base --is-ancestor "refs/heads/${DEFAULT_BRANCH}" "$upstream" 2>/dev/null; then
      git -C "$REPO_DIR" branch -f "$DEFAULT_BRANCH" "$upstream" >/dev/null 2>&1 || true
    fi
  fi

  release_github_lock
  log "restarting loop with updated code"
  exec "$SCRIPT_PATH" ${SELF_ARGS[@]+"${SELF_ARGS[@]}"}
}

# --- Sync: bring the local default branch up to date with the remote ---------
# Before starting any new work, sync the local default branch with
# origin/<default> so the loop's baseline matches the remote. A clean update is a
# fast-forward; when the local default branch has diverged (it carries commits
# that conflict with what landed on the remote) the merge is handed to Copilot to
# resolve so the loop can move forward instead of stalling on a stale branch. The
# resolved merge is kept local only — the loop never pushes the default branch
# (pull requests do that). Best effort: any inability to sync is logged and the
# loop carries on, and an identical divergence Copilot already failed to resolve
# is skipped (marker) so it is not re-run every pass.
#
# classify_sync_state is pure and, with sync_default_branch, is covered by
# tests/sync-default-branch.test.sh between the markers — keep them intact.
# >>> sync-default helpers >>>
# classify_sync_state <upstream_is_ancestor_of_local> <local_is_ancestor_of_upstream>
# Classify how the local default branch relates to its upstream from the two
# `git merge-base --is-ancestor` outcomes (each "yes" when the ancestor test
# passed, anything else means no):
#   insync   - upstream already contained locally (equal, or local ahead): nothing to pull
#   ff       - local strictly behind upstream with no divergence: fast-forward
#   diverged - each side has unique commits: a real merge that may conflict
# Pure string logic so it can be unit tested without git.
classify_sync_state() {
  case "$1" in yes) printf 'insync'; return ;; esac
  case "$2" in yes) printf 'ff';     return ;; esac
  printf 'diverged'
}

sync_default_branch() {
  [ "$SYNC_REMOTE" = 1 ] || return 0

  git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || return 0
  local upstream="origin/${DEFAULT_BRANCH}" local_ref="refs/heads/${DEFAULT_BRANCH}"
  git -C "$REPO_DIR" rev-parse --verify --quiet "$upstream"  >/dev/null 2>&1 || return 0
  # Nothing to sync when there is no local default branch (e.g. a detached or
  # bare-worktree layout) — new work still bases off the fresh origin/<default>.
  git -C "$REPO_DIR" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 || return 0

  local upstream_anc=no local_anc=no state
  git -C "$REPO_DIR" merge-base --is-ancestor "$upstream" "$local_ref" >/dev/null 2>&1 && upstream_anc=yes
  git -C "$REPO_DIR" merge-base --is-ancestor "$local_ref" "$upstream" >/dev/null 2>&1 && local_anc=yes
  state="$(classify_sync_state "$upstream_anc" "$local_anc")"
  [ "$state" = insync ] && return 0

  local cur_branch
  cur_branch="$(git -C "$REPO_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

  if [ "$state" = ff ]; then
    # No divergence: fast-forward the checkout when the default branch is checked
    # out here, otherwise just advance the local ref (safe, no working-tree move).
    if [ "$cur_branch" = "$DEFAULT_BRANCH" ]; then
      git -C "$REPO_DIR" merge --ff-only "$upstream" >/dev/null 2>&1 \
        && log "synced $DEFAULT_BRANCH with origin (fast-forward)"
    else
      git -C "$REPO_DIR" branch -f "$DEFAULT_BRANCH" "$upstream" >/dev/null 2>&1 \
        && log "synced $DEFAULT_BRANCH with origin (fast-forward)"
    fi
    return 0
  fi

  # Diverged. Resolving means merging in the default branch's working tree, so we
  # only do it when the default branch is the checkout the loop owns (REPO_DIR);
  # when it is checked out elsewhere we must not touch that tree.
  if [ "$cur_branch" != "$DEFAULT_BRANCH" ]; then
    log "$DEFAULT_BRANCH has diverged from origin but is not checked out here; skipping sync"
    return 0
  fi

  # Skip a divergence we already handed to Copilot and could not resolve, until
  # either side moves, so an unresolvable conflict is not re-run every pass.
  local local_sha upstream_sha marker
  local_sha="$(git -C "$REPO_DIR" rev-parse "$local_ref" 2>/dev/null)"
  upstream_sha="$(git -C "$REPO_DIR" rev-parse "$upstream" 2>/dev/null)"
  marker="$WORK_DIR/sync-unresolved"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "${local_sha} ${upstream_sha}" ]; then
    return 0
  fi

  log "$DEFAULT_BRANCH has diverged from origin; syncing"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local log_file
  log_file="$LOG_DIR/sync-$(date '+%Y%m%d-%H%M%S').log"

  # A clean merge means there was nothing to resolve; a failed one leaves conflict
  # markers for Copilot (or failed for another reason, handled below).
  if git -C "$REPO_DIR" merge --no-edit "$upstream" >>"$log_file" 2>&1; then
    rm -f "$marker"
    log "synced $DEFAULT_BRANCH with origin (merged, no conflicts)"
    return 0
  fi

  local conflicts
  conflicts="$(git -C "$REPO_DIR" diff --name-only --diff-filter=U 2>/dev/null)"
  if [ -z "$conflicts" ]; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "could not sync $DEFAULT_BRANCH with origin; leaving it unchanged"
    return 0
  fi
  log "resolving $DEFAULT_BRANCH sync conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')"

  local prompt
  prompt="$(cat <<EOF
You are working in a git repository. Merging the remote branch
"origin/${DEFAULT_BRANCH}" into the local "${DEFAULT_BRANCH}" branch produced
conflicts that must be resolved before the automation can continue.

These files contain git conflict markers (<<<<<<<, =======, >>>>>>>):
${conflicts}

Resolve every conflict so the result is correct and preserves the intent of both
sides, then remove all conflict markers. Run any build or test commands needed to
verify your work. Do NOT run git commit, git merge, git push, or create
branches — those steps are handled automatically outside this session. Only edit
files to resolve the conflicts and verify.
EOF
)"
  local -a copilot_args=(-p "$prompt" --allow-all-tools --no-color --log-level none)
  [ -n "$COPILOT_MODEL" ] && copilot_args+=(--model "$COPILOT_MODEL")

  if ! cd "$REPO_DIR" 2>/dev/null; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "could not enter $REPO_DIR to resolve $DEFAULT_BRANCH sync conflicts; leaving it unchanged"
    return 0
  fi
  log "running copilot to resolve $DEFAULT_BRANCH sync conflicts (log: $log_file)"
  run_copilot "$log_file" "${copilot_args[@]}"
  log "copilot exited with code $COPILOT_RC while resolving $DEFAULT_BRANCH sync"

  # Bail if Copilot left conflict markers behind; record the divergence so we do
  # not re-run it on the identical local/upstream pair next pass.
  local f unresolved=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$REPO_DIR/$f" ] && grep -qE '^(<{7}|>{7})' "$REPO_DIR/$f" && unresolved="$unresolved $f"
  done <<< "$conflicts"
  if [ -n "$unresolved" ]; then
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    printf '%s %s\n' "$local_sha" "$upstream_sha" >"$marker" 2>/dev/null || true
    log "could not resolve $DEFAULT_BRANCH sync conflicts (markers left in:$unresolved); leaving it unchanged"
    return 0
  fi

  # Stage exactly the resolved conflict files (non-conflicted merge changes are
  # already staged) so untracked files in the checkout are never swept into the
  # merge commit, then complete the merge locally without pushing.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$REPO_DIR" add -- "$f" >/dev/null 2>&1 || true
  done <<< "$conflicts"
  if git -C "$REPO_DIR" commit --no-edit >/dev/null 2>&1 \
     || git -C "$REPO_DIR" commit -m "Merge origin/${DEFAULT_BRANCH} into ${DEFAULT_BRANCH}" >/dev/null 2>&1; then
    rm -f "$marker"
    log "resolved $DEFAULT_BRANCH sync conflicts with origin (kept local, not pushed)"
  else
    git -C "$REPO_DIR" merge --abort >/dev/null 2>&1 || true
    log "failed to commit resolved $DEFAULT_BRANCH sync; leaving it unchanged"
  fi
  return 0
}
# <<< sync-default helpers <<<

# --- AGENTS.md bootstrap -----------------------------------------------------
# One-time, per-repo: when the repo has no AGENTS.md / copilot-instructions.md,
# generate a concise AGENTS.md and open it as a PR before working any issue, so
# every later run starts with repo context instead of rediscovering it. Skips
# when one already exists; time-boxed and failure-safe (never blocks the loop).
generate_agents_md || true

# --- Self-improving loop: auto-fix the loop's own crashes (issue #218) --------
# When a guarded unit exits *unexpectedly* (a crash — a bug in the loop, not a
# handled failure), report it upstream so the loop can be fixed instead of
# quietly crashing forever. Two routes, decided by whether the operator can push
# to the loop's own repo (BOT_LOOP_REPO):
#   1. can push   -> file a trigger-labelled fix issue there; the loop then
#                    resolves it into a PR ("ask Copilot to fix and open a PR").
#   2. cannot push -> write a local crash report and email it to the maintainer
#                    (BOT_LOOP_EMAIL), asking the operator to forward it.
# When the error output could not be captured, a generic "the loop crashed, it
# needs fixing" message is used. Reports are de-duplicated per crash signature so
# a recurring crash is filed once, not every pass. report_loop_error() runs
# OUTSIDE guard()'s subshell, so every step here is best-effort and can never
# fail or crash the loop.
# >>> auto-fix helpers >>>
# Stable short signature for a crash, so the same crash is reported once (not
# every pass, and not once per issue it hits). Keyed on the crash's identity —
# normally its captured error text — so the SAME loop bug seen while running
# different units de-duplicates to one report. Pure: hashes its arguments
# (joined), echoing digits only. Args: <identity-text...>.
_auto_fix_signature() {
  printf '%s' "$*" | cksum | awk '{print $1}'
}

# True (rc 0) when the gh-authenticated user can push to $1 ("owner/repo") — has
# push, maintain or admin on it — so the loop may open a fix issue there. False
# on any error (not logged in for that host, repo not found, no access), which
# routes auto-fix to the report path instead. Only side effect is the gh call.
bot_loop_can_push() {
  local repo="${1:-}" perm
  [ -n "$repo" ] || return 1
  perm="$(gh api "repos/$repo" --jq '.permissions.push // false' 2>/dev/null)"
  [ "$perm" = "true" ]
}

# Build the Copilot-ready task text for a loop crash: names it a copilot-loop
# self-crash, embeds the captured error (or a generic note when none was
# captured), and asks for a root-cause fix. Pure: echoes the body on stdout.
# Args: <label> <error-text>.
_auto_fix_build_prompt() {
  local label="${1:-the loop}" err="${2:-}"
  printf 'copilot-loop (the autonomous loop in copilot-loop.sh) crashed while running "%s".\n\n' "$label"
  if [ -n "$err" ]; then
    printf 'It exited unexpectedly. Investigate the captured error below, find the\n'
    printf 'root cause in the loop code, and fix it so the loop no longer crashes\n'
    printf 'this way. Add a regression test under tests/ for the fix.\n\n'
    # shellcheck disable=SC2016  # backticks/%s are literal printf format (a code fence), not expansions
    printf 'Captured error:\n\n```\n%s\n```\n' "$err"
  else
    printf 'It exited unexpectedly but the error output could not be captured.\n'
    printf 'Reproduce the crash, find the root cause in the loop code, and fix it so\n'
    printf 'the loop no longer crashes this way. Add a regression test under tests/.\n'
  fi
}

# Option 1 (operator can push): file a trigger-labelled fix issue on the loop's
# own repo so the loop resolves it into a PR. Best-effort; logs the URL on
# success or a warning on failure. Falls back to filing without the label when
# the repo has no such label. Returns non-zero when nothing could be filed, so
# the caller does not mark the crash reported and can retry later.
# Args: <repo> <title> <body>.
_auto_fix_file_issue() {
  local repo="${1:-}" title="${2:-}" body="${3:-}" url
  url="$(gh issue create --repo "$repo" --title "$title" --body "$body" \
           --label "${TRIGGER_LABEL:-ready}" 2>/dev/null)" \
    || url="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>/dev/null)"
  if [ -n "$url" ]; then
    log "auto-fix: filed a fix request on $repo -> $url"
    return 0
  fi
  log "auto-fix: could not file a fix request on $repo (check 'gh' access); the crash is only logged"
  return 1
}

# Option 2 (operator cannot push): write a crash report to disk and, when a
# mailer is present, email it to the maintainer. Always leaves the report on disk
# and logs where it is and who to forward it to. Returns 0 (the report always
# lands locally). Args: <title> <body> <email> <report-dir>.
_auto_fix_write_report() {
  local title="${1:-}" body="${2:-}" email="${3:-}" dir="${4:-.}" file mailed=0
  mkdir -p "$dir" 2>/dev/null || true
  file="$dir/report-$(date '+%Y%m%d-%H%M%S').md"
  {
    printf '# %s\n\n' "$title"
    printf '%s\n\n' "$body"
    printf -- '---\n\n'
    printf 'You are running copilot-loop but cannot push to %s, so this crash\n' "${BOT_LOOP_REPO:-the bot-loop repo}"
    printf 'could not be filed there automatically. Please send this report to the\n'
    printf 'bot-loop maintainer at %s so the loop can be fixed.\n' "${email:-the maintainer}"
  } >"$file" 2>/dev/null || true

  if [ -n "$email" ]; then
    if command -v mail >/dev/null 2>&1; then
      mail -s "$title" "$email" <"$file" >/dev/null 2>&1 && mailed=1
    elif command -v sendmail >/dev/null 2>&1; then
      { printf 'To: %s\nSubject: %s\n\n' "$email" "$title"; cat "$file"; } \
        | sendmail -t >/dev/null 2>&1 && mailed=1
    fi
  fi

  if [ "$mailed" = 1 ]; then
    log "auto-fix: cannot push to ${BOT_LOOP_REPO:-bot-loop}; emailed a crash report to $email (copy: $file)"
  else
    log "auto-fix: cannot push to ${BOT_LOOP_REPO:-bot-loop}; wrote a crash report to $file — please send it to ${email:-the maintainer}"
  fi
  return 0
}

# Self-improving hook. Report a loop CRASH (a guarded unit that exited
# unexpectedly) so the loop can be fixed: file a fix issue on BOT_LOOP_REPO when
# the operator can push there, else write/email a report. De-duplicated per crash
# signature so a recurring crash is reported once. Fully failure-safe — it runs
# outside guard(), so it never returns non-zero or crashes the loop. No-op when
# AUTO_FIX is off. Args: <label> <error-file>.
report_loop_error() {
  [ "${AUTO_FIX:-0}" = 1 ] || return 0
  local label="${1:-the loop}" err_file="${2:-}" err="" sig marker state_dir ok=1

  if [ -n "$err_file" ] && [ -s "$err_file" ]; then
    err="$(grep -v '^[[:space:]]*$' "$err_file" 2>/dev/null | tail -n 40)"
  fi

  state_dir="${AUTO_FIX_STATE_DIR:-${WORK_DIR:-/tmp}/auto-fix}"
  # De-duplicate on the crash's identity: the captured error when we have one (so
  # the same bug across different issues is reported once), else the unit label.
  sig="$(_auto_fix_signature "${err:-$label}")"
  marker="$state_dir/reported-$sig"
  mkdir -p "$state_dir" 2>/dev/null || true
  if [ -e "$marker" ]; then
    log "auto-fix: already reported this loop crash; skipping ($label)"
    return 0
  fi

  local title body
  title="loop auto-fix: crash while running \"$label\""
  body="$(printf '%s\n\n%s\n' "$(_auto_fix_build_prompt "$label" "$err")" "${AUTO_FIX_MARKER:-}")"

  if bot_loop_can_push "${BOT_LOOP_REPO:-}"; then
    _auto_fix_file_issue "${BOT_LOOP_REPO:-}" "$title" "$body" || ok=0
  else
    _auto_fix_write_report "$title" "$body" "${BOT_LOOP_EMAIL:-}" "$state_dir" || ok=0
  fi

  # Only mark the crash reported once something actually landed, so a transient
  # failure (e.g. gh hiccup) is retried on the next crash instead of suppressed.
  if [ "$ok" = 1 ]; then
    : >"$marker" 2>/dev/null || true
  fi
  return 0
}
# <<< auto-fix helpers <<<

# EXIT-trap handler for guard()'s subshell. Runs when a guarded unit's subshell
# exits: on an *abnormal* exit (a crash — _guard_clean never got set to 1) it
# marks the crash for the parent and folds the captured stderr into the unit's
# own run log, where the TUI shows it, so the operator sees *why* the run ended.
# A normal return (any code) is left alone — the unit already reported itself.
_guard_on_exit() {
  local _g=$?
  [ "${_guard_clean:-0}" -eq 1 ] && return 0
  : > "$_GUARD_CRASHED" 2>/dev/null || true
  if [ -n "${CURRENT_RUN_LOG:-}" ] && [ -s "$_GUARD_ERR" ]; then
    {
      printf '%s | run ended unexpectedly (exit %s); captured error:\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$_g"
      sed 's/^/    /' "$_GUARD_ERR"
    } >>"$CURRENT_RUN_LOG" 2>/dev/null || true
  fi
  return 0
}

# Run one unit of work (a whole issue, plan, or PR fix) isolated in a subshell so
# an *unexpected* exit inside it cannot silently kill the loop. The `|| true`
# guards on the calls below do NOT catch a `set -u` unbound-variable crash: that
# aborts the shell rather than returning non-zero, so without this the loop just
# printed "shutting down" mid-issue and stopped (#214, #216). The subshell also
# captures the unit's own stderr; on an *abnormal* exit (a crash, not a normal
# non-zero return) it folds the captured error into that run's log — where the
# TUI shows it — so the operator sees *why* instead of a bare "shutting down".
# Usage: guard "<label>" <function> [args...]. Always returns the unit's own exit
# status; the loop then continues to the next pass regardless.
guard() {
  local _label="$1"; shift
  local rc
  _GUARD_ERR="$(mktemp 2>/dev/null || printf '%s/copilot-loop-guard.%s' "${WORK_DIR:-/tmp}" "$$")"
  _GUARD_CRASHED="${_GUARD_ERR}.crashed"
  rm -f "$_GUARD_CRASHED" 2>/dev/null || true
  (
    # A clean return (any code) sets this before exiting; a crash (set -u, an
    # uncaught error) never reaches it, which is how _guard_on_exit tells the two
    # apart and avoids crying "crash" over a failure the unit already reported.
    _guard_clean=0
    trap _guard_on_exit EXIT
    "$@"
    _guard_rc=$?
    _guard_clean=1
    exit "$_guard_rc"
  ) 2>>"$_GUARD_ERR"
  rc=$?
  # Keep the unit's unredirected stderr visible on the terminal, as a direct call
  # would, then summarise a crash (never a plain non-zero return) in the loop log.
  [ -s "$_GUARD_ERR" ] && cat "$_GUARD_ERR" >&2
  if [ -e "$_GUARD_CRASHED" ]; then
    log "$_label ended unexpectedly (exit $rc): $(grep -v '^[[:space:]]*$' "$_GUARD_ERR" 2>/dev/null | tail -n1)"
    # Self-improving loop (issue #218): report this crash upstream so the loop
    # can be fixed. Gated by `command -v` so unit tests that source guard() alone
    # are unaffected, and by AUTO_FIX inside. Best-effort — never fails the loop.
    if command -v report_loop_error >/dev/null 2>&1; then
      report_loop_error "$_label" "$_GUARD_ERR" || true
    fi
  fi
  rm -f "$_GUARD_ERR" "$_GUARD_CRASHED" 2>/dev/null || true
  return "$rc"
}

# --- Main loop ---------------------------------------------------------------
while true; do
  # Each iteration's setup and queue-scanning logs belong to the loop itself, not
  # to any one run, so drop the per-run mirror before the next run claims it
  # (#126). process_issue / resolve_pr_* re-arm it once they know their log file.
  CURRENT_RUN_LOG=""

  # Between issues this worker is not on any issue, so drop its TUI assignment;
  # process_issue / plan_issue re-set it once they claim one (#214).
  clear_worker_issue

  # Narrate the start of each pass when running verbose, so the log shows the
  # loop is alive and cycling even when there is nothing to do (#214).
  vlog "loop: starting pass (checking for work)"

  # Keep the loop current before starting any new work: pull the default branch
  # and re-exec if this script changed upstream.
  vlog "loop: checking for a script self-update"
  self_update

  # Sync the local default branch with the remote so new work starts from the
  # latest baseline; a diverged merge conflict is handed to Copilot to resolve.
  vlog "loop: syncing local $DEFAULT_BRANCH with origin"
  sync_default_branch

  vlog "loop: turning issues/ markdown files into GitHub issues"
  process_issue_files

  # Reclaim disk and keep git tidy: sweep branches and worktrees whose PR has
  # merged (local and, when enabled, remote). Safe — only the loop's own merged
  # branches are removed, never the default branch or un-pushed work.
  vlog "loop: sweeping merged branches and worktrees"
  sweep_merged_branches

  # Before starting any new task, make sure no open PR is left with merge
  # conflicts; claim one atomically if found and re-check before doing anything
  # else. Claiming under the lock stops two instances resolving the same PR.
  # First let GitHub finish computing PR mergeability so this check sees accurate
  # state instead of skipping a still-UNKNOWN PR (which would let the loop start a
  # ready issue with a conflict still open).
  vlog "loop: scanning open PRs for merge conflicts"
  ensure_pr_mergeability_known
  conflicted_pr="$(claim_next_conflicted_pr || true)"
  if [ -n "$conflicted_pr" ]; then
    log "PR #$conflicted_pr has conflicts, resolving before starting new tasks"
    guard "PR #$conflicted_pr conflict resolution" resolve_pr_conflicts "$conflicted_pr" || true
    continue
  fi

  # Still before starting new work: fix any open PR whose CI checks are failing.
  # Claim one atomically (under the lock, so instances never fix the same PR) and
  # hand its failing checks to Copilot, then re-check on the next pass. Conflicts
  # are handled first above, so a conflicting PR is never grabbed here.
  vlog "loop: scanning open PRs for failing checks"
  failing_pr="$(claim_next_failing_pr || true)"
  if [ -n "$failing_pr" ]; then
    log "PR #$failing_pr has failing checks, fixing before starting new tasks"
    guard "PR #$failing_pr check fix" resolve_pr_check_failures "$failing_pr" || true
    continue
  fi

  # Keep the "pending" label in sync with each open issue's dependency state
  # before picking work, so an issue waiting on another ("Wait for: #N") is
  # visibly marked and one whose blockers have closed is unmarked.
  vlog "loop: reconciling '$PENDING_LABEL' labels against dependencies"
  reconcile_pending_labels

  # Prefer resuming an issue where the user has answered a pending question.
  # Atomically select and claim to prevent race conditions with other instances.
  vlog "loop: checking for answered '$NEEDS_INFO_LABEL' issues to resume"
  next_issue="$(claim_next_reply_issue || true)"
  if [ -n "$next_issue" ]; then
    log "issue #$next_issue: user replied, resuming"
    guard "issue #$next_issue" process_issue "$next_issue" || true
    continue
  fi

  # Plan mode: an issue labelled with the plan label is drafted into an
  # implementation plan (no code changes) that is posted for review, instead of
  # being implemented straight away. Claimed atomically under the lock like ready
  # issues; the issue then waits (labelled plan-review) for the user to add the
  # trigger label, which routes it through normal execution above/below.
  plan_target="$(claim_next_plan_issue || true)"
  if [ -n "$plan_target" ]; then
    log "issue #$plan_target: labelled '$PLAN_LABEL', drafting a plan for review"
    guard "plan for issue #$plan_target" plan_issue "$plan_target" || true
    continue
  fi

  # Show the ready queue before pulling the next issue off it, so the operator
  # can see the backlog that is about to be worked.
  log_ready_issues

  # Pick the oldest ready issue and claim it atomically.
  # This prevents multiple instances from selecting the same issue.
  vlog "loop: claiming the oldest '$TRIGGER_LABEL' issue"
  next_issue="$(claim_next_ready_issue || true)"

  if [ -z "$next_issue" ]; then
    if [ -t 0 ]; then
      log "no ready issues; sleeping ${SLEEP_MINUTES}m (press 'f' to start now)"
    else
      log "no ready issues; sleeping ${SLEEP_MINUTES}m"
    fi
    if ! interruptible_sleep "$((SLEEP_MINUTES * 60))"; then
      log "'f' pressed; waking to look for work"
    fi
    vlog "loop: woke from sleep; starting the next pass"
    continue
  fi

  guard "issue #$next_issue" process_issue "$next_issue" || true
done
