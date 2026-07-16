# Summarise long issue threads before sending them to the coding model

When an issue is resumed after several needs-info rounds, the whole Q&A thread is
replayed into the prompt verbatim and grows every subsequent run, spending tokens
to re-read the same history.

- Before building the prompt, if the thread exceeds a threshold, use the cheap
  model to produce a short summary of the prior conversation and pass that instead
  of the raw thread (always keep the latest human reply verbatim).
- Skip summarisation when the thread is short.
- Keep it optional and off by default until proven.

Best paired with bounding the prompt size, which is a simpler first step.

Label: none
