# Unknown-note block experiment

This is an incomplete, off-by-default server experiment, not the client
prototype's measured accuracy result. Enable it per request with
`"notes": true, "notes_subjects": true, "notes_unknown": true`.

For present-time queries with an unambiguous non-self subject, annotations
are appended without filtering or removing any retrieved notes, including
self facts and take-backs. All words of a stored attribute name must match;
only a unique most-specific attribute is eligible. Multiple distinct subjects
are suppressed until span binding exists. A current attribute sharing a
question word also suppresses a generic absence claim. Missing pairs receive
an explicit absence line; a current
single-valued take-back receives an unknown-current-value annotation while
retaining the evidence that the earlier value no longer holds. A set-item
take-back does not make the whole attribute unknown. All added text is counted
with the actual tokenizer and omitted when it cannot fit the request cap.

Live fetching is disabled for this shape, with an explicit `notes.decode.stopped`
reason: its current note-id-only replacement would otherwise discard these
annotations. Ordinary requests retain their existing behavior.

Known limitations:

- With no retrieved evidence, the block intentionally contains only the
  absence annotation, without a notes heading. It remains outside quoted data.
- Erase does not remove entity/attribute vocabulary. A question-resolved alias
  can therefore still name an erased entity in an absence annotation.
- Display replaces underscores with spaces only; it does not invent synonym
  expansions (for example, `fav` is not silently expanded to `favourite`).
- The model gate must include a yes/no question about a withdrawn value,
  such as "Is purple my cousin's favourite colour?", not only open questions.

- Self absence is suppressed because an unrecognized possessive relation can
  otherwise resolve to the user (for example, “my sister” falling back to “my”).
- No general relation parser, implicit-subject resolution or ambiguous-name
  disambiguation is implemented.
- Missing-pair absence lines are suppressed when the subject has a current
  entity-valued link: a linked fact might supply the answer, so a missing
  direct pair alone does not prove that the answer is unknown.
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
