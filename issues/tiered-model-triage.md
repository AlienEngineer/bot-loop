# Triage issues with a cheap model and escalate only when needed

Every issue currently runs on the same coding model regardless of difficulty,
which over-spends tokens on trivial tasks in an automated loop.

- Add an optional triage step: run a cheap model (reuse the COMMIT_MODEL idea) to
  classify the issue (e.g. trivial / normal / complex) and/or draft a short plan.
- Route trivial issues to a cheaper model and reserve the expensive model for
  complex ones; make the mapping configurable.
- Fall back to the current behaviour when triage is disabled or fails.

This lowers the average token cost per issue without hurting hard-issue quality.

Label: none
