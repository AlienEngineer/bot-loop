# Allow issues to be prioritised instead of strictly oldest-first

claim_next_ready_issue picks ready issues strictly oldest-first (lowest number),
so there is no way to make an urgent issue jump the queue.

- Support a priority signal: either a priority label (e.g. priority-high) or a
  "Priority: high|normal|low" directive in the body (pure, testable parser).
- When selecting the next ready issue, order by priority first, then fall back to
  oldest-first within the same priority.
- Keep dependency gating ("Wait for: #N") intact.
- Add unit tests for the ordering.

Label: none
