#!/usr/bin/env bash
#
# Unit tests for parse_usage_stats and _usage_header in copilot-loop.sh. The
# helpers are extracted verbatim from the script (between the "usage helpers"
# markers) and sourced here, so the real code is exercised. parse_usage_stats
# reads Copilot's captured run output on stdin and echoes the per-run cost
# summary (the last "AI Credits" / "Premium requests" line and the last "Tokens"
# line); _usage_header builds the comment header that names which model resolved
# the run. Together they form the usage comment _report_usage posts on the
# issue/PR, so every prompt's cost and model are tracked.
#
# Run: tests/usage-report.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> usage helpers >>>/,/# <<< usage helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract usage helpers (markers missing?)"; exit 1; }
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

# --- full block: credits + tokens, surrounded by ordinary log chatter --------
full="$(cat <<'EOF'
copilot: done editing files
AI Credits 25.7 (8s)
Tokens     ↑ 40.2k (40.2k written) • ↓ 221 (217 reasoning)
copilot: exiting
EOF
)"
want_full="$(printf 'AI Credits 25.7 (8s)\nTokens     ↑ 40.2k (40.2k written) • ↓ 221 (217 reasoning)')"
assert_eq "full block -> both lines" "$(printf '%s' "$full" | parse_usage_stats)" "$want_full"

# --- tokens only: no credits line present ------------------------------------
tokens_only="$(cat <<'EOF'
some output
Tokens     ↑ 100 • ↓ 50
EOF
)"
assert_eq "tokens only" "$(printf '%s' "$tokens_only" | parse_usage_stats)" "Tokens     ↑ 100 • ↓ 50"

# --- credits only: no tokens line present ------------------------------------
credits_only="$(cat <<'EOF'
AI Credits 3.2 (2s)
all done
EOF
)"
assert_eq "credits only" "$(printf '%s' "$credits_only" | parse_usage_stats)" "AI Credits 3.2 (2s)"

# --- legacy "Premium requests" wording is recognised as the credits line -----
legacy="$(cat <<'EOF'
Premium requests 1 (5s)
Tokens     ↑ 10k • ↓ 20
EOF
)"
want_legacy="$(printf 'Premium requests 1 (5s)\nTokens     ↑ 10k • ↓ 20')"
assert_eq "legacy premium requests" "$(printf '%s' "$legacy" | parse_usage_stats)" "$want_legacy"

# --- no stats at all -> empty summary (so nothing is posted) ------------------
none="$(cat <<'EOF'
nothing to see here
just regular copilot chatter
EOF
)"
assert_eq "no stats -> empty" "$(printf '%s' "$none" | parse_usage_stats)" ""

# --- two blocks (triage run then coding run) -> the LAST block wins -----------
two="$(cat <<'EOF'
AI Credits 1.0 (1s)
Tokens     ↑ 1 • ↓ 1
--- coding run ---
AI Credits 25.7 (8s)
Tokens     ↑ 40.2k • ↓ 221
EOF
)"
want_two="$(printf 'AI Credits 25.7 (8s)\nTokens     ↑ 40.2k • ↓ 221')"
assert_eq "two blocks -> last wins" "$(printf '%s' "$two" | parse_usage_stats)" "$want_two"

# --- CRLF line endings are stripped ------------------------------------------
crlf="$(printf 'AI Credits 5.0 (3s)\r\nTokens     \xe2\x86\x91 9k \xe2\x80\xa2 \xe2\x86\x93 3\r\n')"
want_crlf="$(printf 'AI Credits 5.0 (3s)\nTokens     \xe2\x86\x91 9k \xe2\x80\xa2 \xe2\x86\x93 3')"
assert_eq "CRLF stripped" "$(printf '%s' "$crlf" | parse_usage_stats)" "$want_crlf"

# --- leading indentation is trimmed ------------------------------------------
indented="$(printf '    AI Credits 7.7 (4s)\n    Tokens     \xe2\x86\x91 2k \xe2\x80\xa2 \xe2\x86\x93 9\n')"
want_indented="$(printf 'AI Credits 7.7 (4s)\nTokens     \xe2\x86\x91 2k \xe2\x80\xa2 \xe2\x86\x93 9')"
assert_eq "leading indent trimmed" "$(printf '%s' "$indented" | parse_usage_stats)" "$want_indented"

# --- _usage_header: the model that resolved the run is always recorded (#208) --
assert_eq "explicit model in header" \
  "$(_usage_header 'claude-opus-4.5')" "**copilot-loop usage** (model: claude-opus-4.5)"
assert_eq "empty model -> auto" \
  "$(_usage_header '')" "**copilot-loop usage** (model: auto)"
assert_eq "missing model arg -> auto" \
  "$(_usage_header)" "**copilot-loop usage** (model: auto)"

if [ "$fail" -eq 0 ]; then
  echo "All usage-report tests passed."
else
  echo "Some usage-report tests FAILED."
fi
exit "$fail"
