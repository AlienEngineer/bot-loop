#!/usr/bin/env bash
#
# Test aggregator: run every tests/*.test.sh and exit non-zero if any fail, so
# the whole suite runs with one command locally and in CI.
#
# Run: tests/run-all.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

fail=0
total=0
failed=()

for t in "$here"/*.test.sh; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  name="$(basename "$t")"
  printf '=== %s ===\n' "$name"
  if ! bash "$t"; then
    fail=1
    failed+=("$name")
  fi
  printf '\n'
done

if [ "$total" -eq 0 ]; then
  echo "No test files found (tests/*.test.sh)."
  exit 1
fi

if [ "$fail" -eq 0 ]; then
  printf 'All %d test file(s) passed.\n' "$total"
else
  printf '%d of %d test file(s) FAILED:\n' "${#failed[@]}" "$total"
  printf '  - %s\n' "${failed[@]}"
fi
exit "$fail"
