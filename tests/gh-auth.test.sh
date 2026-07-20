#!/usr/bin/env bash
#
# Unit tests for the gh-auth preflight helper in copilot-loop.sh.
# _gh_authenticated_for_origin scopes `gh auth status` to the origin host so a
# broken login on an *unrelated* host cannot make an authenticated machine look
# logged out (which used to spuriously demand `gh auth login`). The helper and
# its _gh_host_from_url dependency are extracted from the script between marker
# comments and sourced here, and `gh` is stubbed so the test controls which
# hosts are "logged in".
#
# Run: tests/gh-auth.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../copilot-loop.sh"

[ -f "$script" ] || { echo "cannot find copilot-loop.sh next to tests/"; exit 1; }

extract() { sed -n "/# >>> $1 >>>/,/# <<< $1 <<</p" "$script"; }

host_block="$(extract 'gh-host helpers')"
auth_block="$(extract 'gh-auth helpers')"
[ -n "$host_block" ] || { echo "could not extract gh-host helpers (markers missing?)"; exit 1; }
[ -n "$auth_block" ] || { echo "could not extract gh-auth helpers (markers missing?)"; exit 1; }
eval "$host_block"
eval "$auth_block"

# Stub `gh`: only `gh auth status --hostname <host>` is exercised. github.com and
# bmw.ghe.com are "logged in" (exit 0); every other host, including the broken
# enterprise host code.connected.bmw, is "logged out" (exit 1). Mirrors a machine
# with a stale token on one host and good tokens elsewhere.
gh() {
  local host=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hostname) host="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$host" in
    github.com|bmw.ghe.com) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
assert_ok() {
  local desc="$1" url="$2"
  if _gh_authenticated_for_origin "$url"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected authenticated for: [%s]\n' "$desc" "$url"
    fail=1
  fi
}
assert_not_ok() {
  local desc="$1" url="$2"
  if _gh_authenticated_for_origin "$url"; then
    printf 'FAIL - %s\n       expected NOT authenticated for: [%s]\n' "$desc" "$url"
    fail=1
  else
    printf 'ok   - %s\n' "$desc"
  fi
}

# Regression: origin on a good host stays authenticated even though an unrelated
# host (code.connected.bmw) has a broken token. Unscoped `gh auth status` would
# fail here; the scoped check must not.
assert_ok     "github.com origin passes despite broken unrelated host" 'https://github.com/AlienEngineer/bot-loop.git'
assert_ok     "enterprise origin passes on its own logged-in host"     'git@bmw.ghe.com:unit/team-insights.git'
assert_ok     "no parseable host defaults to github.com (logged in)"   ''

# Origin host itself is not logged in / has a broken token -> fail fast.
assert_not_ok "broken enterprise origin host fails"                    'ssh://git@code.connected.bmw/org/productivity.git'
assert_not_ok "unknown host fails"                                     'https://example.com/o/r'

if [ "$fail" -eq 0 ]; then
  echo "All gh-auth tests passed."
else
  echo "Some gh-auth tests FAILED."
fi
exit "$fail"
