# Unknown-note block experiment

This is an incomplete, off-by-default server experiment, not the client
prototype's measured accuracy result. Enable it per request with
`"notes": true, "notes_subjects": true, "notes_unknown": true`.

For present-time queries with an unambiguous non-self subject, the initial
retrieval is restricted to that subject and at most two value links among
the notes already selected. Stored attribute-name words identify potentially
asked attributes. Missing pairs receive an explicit absence line; a current
single-valued take-back receives an unknown-current-value annotation while
retaining the evidence that the earlier value no longer holds. A set-item
take-back does not make the whole attribute unknown. All added text is counted
with the actual tokenizer and omitted when it cannot fit the request cap.

Live fetching is disabled for this shape, with an explicit `notes.decode.stopped`
reason: its current note-id-only replacement would otherwise discard these
annotations. Ordinary requests retain their existing behavior.

Known limitations:

- Self absence is suppressed because an unrecognized possessive relation can
  otherwise resolve to the user (for example, “my sister” falling back to “my”).
- No general relation parser, implicit-subject resolution or ambiguous-name
  disambiguation is implemented.
- Attributes use stored names only, not a test-question keyword map. Optional
  topic metadata needs an explicit store export before it can be supported.
- Filtering an already capped retrieval cannot recover a relevant note that
  was crowded out before filtering; value-link expansion is likewise limited
  to already selected notes.
- Take-back wording is evidence for the model, not a deterministic answer or a
  guarantee against hallucination. Yes/no and set-valued semantics need more
  end-to-end evaluation.
- Finnish/German prototype changes are not included.

Focused CPU tests cover request validation, prefetch-only behavior, missing
pairs, take-back metadata, known-value precedence and exact cap enforcement.
The full server suite must pass after each implementation change. No claim
of reproducing the client prototype's 62/86 or 35/45 accuracy follows from
these tests; that requires separate model runs on held-out questions.
