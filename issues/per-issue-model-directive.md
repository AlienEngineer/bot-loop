# Support a per-issue model directive to pick the model per task

Today the model is global (--model / COPILOT_MODEL). Simple issues (docs, tiny
fixes) still run on whatever large model is configured, wasting cost, while hard
issues might warrant a stronger model.

- Read an optional per-issue model directive from the issue body (mirror the
  issue_labels / issue_wait_for parsing style with a pure, testable helper).
- When present, pass it as copilot --model for that issue, overriding the global
  default; when absent, keep current behaviour.
- Document it in TEMPLATE.md and add unit tests for the parser.

This lets cheap issues run on a cheap model and lowers overall token spend.

Label: none
