#!/usr/bin/env bash
#
# Unit tests for the path sanitization helpers in copilot-loop.sh.
# Tests the sanitize_paths_for_display function which replaces absolute paths
# with ~/ notation to hide user home directories from GitHub comments.
#
# The function under test is extracted verbatim from the script (between the
# "path-sanitization helpers" markers) and sourced here so the real code is
# exercised without touching GitHub.
#
# Run: tests/hide-paths.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> path-sanitization helpers >>>/,/# <<< path-sanitization helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract path-sanitization helpers (markers missing?)"; exit 1; }
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

# Test: Single absolute path replacement
assert_eq "single path" \
  "$(echo "/Users/john/repo/file.txt" | sanitize_paths_for_display)" \
  "~/repo/file.txt"

# Test: Multiple paths in one line
assert_eq "multiple paths on one line" \
  "$(echo "Error in /Users/alice/project and /Users/alice/code" | sanitize_paths_for_display)" \
  "Error in ~/project and ~/code"

# Test: Path at beginning, middle, and end
assert_eq "paths in different positions" \
  "$(echo "/Users/bob/work building /Users/bob/src done" | sanitize_paths_for_display)" \
  "~/work building ~/src done"

# Test: Preserve relative paths
assert_eq "preserve relative path" \
  "$(echo "relative/path/file.txt" | sanitize_paths_for_display)" \
  "relative/path/file.txt"

# Test: Path in code block with backticks
assert_eq "path in code" \
  "$(echo "Run: \`/Users/jane/bot-loop/script.sh\`" | sanitize_paths_for_display)" \
  "Run: \`~/bot-loop/script.sh\`"

# Test: Path with trailing slash
assert_eq "path with trailing slash" \
  "$(echo "/Users/dave/project/" | sanitize_paths_for_display)" \
  "~/project/"

# Test: Multiline log with multiple paths
multiline_input="[ERROR] Failed at /Users/test/repo/src/main.rs:42
Stack trace from /Users/test/logs/trace.log:
  /Users/test/repo/lib/util.rs"
multiline_expected="[ERROR] Failed at ~/repo/src/main.rs:42
Stack trace from ~/logs/trace.log:
  ~/repo/lib/util.rs"
assert_eq "multiline paths" \
  "$(echo "$multiline_input" | sanitize_paths_for_display)" \
  "$multiline_expected"

# Test: JSON-like structure with paths
json_input='{"home":"/Users/user/data","log":"/Users/user/.logs/session.log"}'
json_expected='{"home":"~/data","log":"~/.logs/session.log"}'
assert_eq "paths in JSON" \
  "$(echo "$json_input" | sanitize_paths_for_display)" \
  "$json_expected"

# Test: Empty input
assert_eq "empty input" \
  "$(echo "" | sanitize_paths_for_display)" \
  ""

# Test: No paths (should pass through unchanged)
assert_eq "no paths" \
  "$(echo "This is normal text with no absolute paths" | sanitize_paths_for_display)" \
  "This is normal text with no absolute paths"

# Test: Path in shell command
shell_input="cd /Users/admin/project && git status"
shell_expected="cd ~/project && git status"
assert_eq "path in shell command" \
  "$(echo "$shell_input" | sanitize_paths_for_display)" \
  "$shell_expected"

# Test: Path with special characters (though rare)
assert_eq "path with space in dirname" \
  "$(echo "Config at /Users/jane/My Projects/config.yaml" | sanitize_paths_for_display)" \
  "Config at ~/My Projects/config.yaml"

# Test: Consecutive slashes (edge case)
assert_eq "consecutive slashes" \
  "$(echo "Path: /Users/user//double//slash" | sanitize_paths_for_display)" \
  "Path: ~//double//slash"

# Test: Only home directory
assert_eq "just home directory" \
  "$(echo "/Users/user" | sanitize_paths_for_display)" \
  "~"

# Test: Home with no trailing path
home_test="/Users/charlie"
assert_eq "home directory only" \
  "$(echo "$home_test" | sanitize_paths_for_display)" \
  "~"

if [ "$fail" -eq 0 ]; then
  echo "All hide-paths tests passed."
else
  echo "Some hide-paths tests FAILED."
fi
exit "$fail"
