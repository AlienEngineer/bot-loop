# Run the test suite in CI on every pull request

tests/ has unit tests (*.test.sh) but nothing runs them automatically, so a PR
can merge while breaking a helper. Add continuous integration:

- A GitHub Actions workflow (.github/workflows/tests.yml) triggered on
  pull_request and push that runs every tests/*.test.sh on ubuntu-latest.
- A small aggregator, e.g. tests/run-all.sh, that runs each *.test.sh and exits
  non-zero if any fail, so the whole suite runs with one command locally and in CI.
- A shellcheck step over copilot-loop.sh, copilot-loop-tui.sh, and the tests.

Acceptance: CI fails when any test fails and passes on the current tree.

Label: none
