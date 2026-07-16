#!/usr/bin/env bash
#
# Unit tests for the gh-host helper in copilot-loop.sh. _gh_host_from_url is
# extracted verbatim from the script (between the "gh-host helpers" markers) and
# sourced here, so the real parsing code is exercised. The host it returns is
# what the loop uses to target repo-independent `gh` calls (e.g. `gh api user`)
# at the account that owns the repo, so a machine logged in to several hosts
# never resolves the wrong identity.
#
# Run: tests/gh-host.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

block="$(sed -n '/# >>> gh-host helpers >>>/,/# <<< gh-host helpers <<</p' "$script")"
[ -n "$block" ] || { echo "could not extract gh-host helpers (markers missing?)"; exit 1; }
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

# --- _gh_host_from_url: parse the host out of every remote URL form ----------
assert_eq "https github.com"      "$(_gh_host_from_url 'https://github.com/AlienEngineer/bot-loop.git')"       "github.com"
assert_eq "https enterprise host" "$(_gh_host_from_url 'https://bmw.ghe.com/unit/team-insights.git')"          "bmw.ghe.com"
assert_eq "scp-like ssh"          "$(_gh_host_from_url 'git@bmw.ghe.com:unit/team-insights.git')"              "bmw.ghe.com"
assert_eq "ssh:// url"            "$(_gh_host_from_url 'ssh://git@code.connected.bmw/org/productivity.git')"   "code.connected.bmw"
assert_eq "https with userinfo"   "$(_gh_host_from_url 'https://user@github.com/o/r')"                         "github.com"
assert_eq "scp-like no path"      "$(_gh_host_from_url 'git@bmw.ghe.com:o/r')"                                 "bmw.ghe.com"
assert_eq "empty input"           "$(_gh_host_from_url '')"                                                    ""

if [ "$fail" -eq 0 ]; then
  echo "All gh-host tests passed."
else
  echo "Some gh-host tests FAILED."
fi
exit "$fail"
