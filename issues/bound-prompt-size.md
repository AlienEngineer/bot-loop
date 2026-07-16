# Bound the size of the issue body and comment thread sent to Copilot

process_single_issue builds the prompt from the full issue body plus the ENTIRE
comment thread (gh issue view ... comments, joined with no cap). On long or
resumed issues this grows without limit and inflates the input tokens of every
run, which is costly given the automated, repeated nature of the loop.

- Cap the comment thread injected into the prompt: keep the most recent N
  comments and/or a maximum character budget, always preserving the latest human
  reply (the answer a resume depends on).
- Cap very long issue bodies the same way, with a clear truncation marker.
- Make the limits configurable with sensible defaults, and add unit tests for the
  trimming helper.

This directly reduces input tokens per run, especially on long-running issues.

Label: none
