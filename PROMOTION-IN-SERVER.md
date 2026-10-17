# Nightly promotion inside the notes server

Notes that prove useful and stay unchanged are taught into Living Weights (the pocket neurons) at night. A note leaves
the prompt only after the neurons answer its questions alone on 2 nights running. A change or a take-back is served by
the notes at once; the stale neurons are rebuilt the next night. Branch `notes-promotion` of our fork, from
`notes-integrated` at `10cb2e22`. Not pushed; no pull request.

Grades: **MEASURED** we ran it; **READ** we read it in code or a document; **INFERRED** our own reasoning, not run.

## Open questions (for petrus and codexmb)

1. **Rollback is not exact.** The learner has no "put the pocket back as it was" (READ: `LearnRequest` has `undo` and
   `drop` for the last lesson only, `retire` to zero given neurons). A rejected night zeroes the neurons it placed and
   asks the regression set again; a later lesson can also have refitted an earlier fact's input weights away from its
   own rows ("refits", READ `pocket.zig`), and zeroing does not undo that. If the second ask is still worse, every
   promotion neuron is zeroed (the untaught model, for promotion's part). Is that good enough, or do we want a pocket
   checkpoint op in the learner (an engine change, not done here)?
2. **Zeroed neurons keep their places** (READ `pocket.retire`: "their places stay taken"). Every rebuild uses new slots;
   64 per MoE layer, about ten per fact. A long-lived server needs pocket compaction; not built.
3. **No answer key.** "Right" means the learner's own test: `wording.recalls(fact, question, reference, reply)`, with
   the reference the untaught model's answer with the fact in front of it (`told_note`), as the learner's held-out
   answers are written. Control prompts count as worse when the reply changes and the model's own judge
   (`same_prompt`) says the new reply claims something new. Good enough?
4. **Dated values** are not visible in the server's notes model (READ: `model.Kind` is `fact` or `tombstone`, no op or
   dates). Here a note whose text names a year (4 digits, 1900 to 2099) or says since/until is treated as dated and not
   promoted (INFERRED heuristic).
5. **Missed and rejected facts are never retried** (as `promote.py`). Retry after M nights?
6. **Exclusion by id after an erase.** In-weights notes are excluded by their current id, recomputed from the listing
   whenever the index version changes (an erase renumbers). The first lookup after a write takes the writer lock once
   to list the notes.
7. **One owner per server**, like `--notes`.

## Design

**Flags** (off by default; with none of them the server is unchanged):

| Flag | Meaning |
| --- | --- |
| `--notes-promote-every DURATION` | a night every DURATION after the last ended (`600s`, `10m`, `24h`); needs `--notes` and `--slide` |
| `--notes-promote-hold N` | nights a note must stay unchanged before it is due (default 1) |
| `--notes-promote-alone N` | nights running its questions must come back without its note (default 2) |

State lives in `SNAPSHOT.promote` beside the snapshot (JSON, format `tf-notes-promote/1`), written to a fresh
temporary file, synced (`F_FULLFSYNC` on macOS, `fsync` elsewhere, the journal's rule), renamed over, and the folder
synced. `GET /v1/promotion` returns it; `POST /v1/promotion` runs a night now (409 while one runs). Both sit behind the
`/v1` key check.

**A fact** is a current note of kind fact, keyed by its write's source (`w12`) or `s<id>` for a snapshot note (both
survive an erase's renumbering). A change makes a new note with a new key, so "unchanged" needs no version count.

**Qualify (each night k).** Due when: current, kind fact (not a take-back), not dated (question 4), retrieved into a
chat request's block at least once (the lookup hook records the ids), status `note`, and `k - since >= hold`, where
`since` is the number of nights done when the server first saw the note. With hold 1 a note written and used today is
due tonight.

**Stale.** A fact in the pocket (`promoted` or `in_weights`) whose key is no longer current (changed, taken back,
erased) is stale. Its notes already answer: the old note is no longer current, so nothing excludes the new one.

**Plans (as `promote.py`'s `night_plans`).** Nothing stale: `add` the due facts. Something stale: `rebuild` (zero every
promotion neuron, then teach the facts that still hold and the due ones, oldest first), then `rebuild-old` (without the
due ones), then `source` (zero every promotion neuron, teach nothing), always last and always taken.

**Teach.** Each fact's own text goes through `slide.teachText`, the body of `POST /v1/slide/learn` (source `chat`)
moved into a function the route calls too: the same lesson writer, rounds, held-out checks and save. The learner's
checks decide kept or missed. Its questions (held-out and never-learned wordings, from the slide graph) become the
fact's probes, at most 4, each with its reference answer.

**Regress.** Before the night the probes of the facts that still hold plus 4 fixed control prompts are asked as
production asks them (notes in, in-weights notes out); after the teach they are asked again. A probe right before and
wrong after, or a control that changed in substance, counts as worse; more than the tolerance (0) rejects the plan.
A rejected `add` zeroes tonight's neurons and asks again; still worse goes to `source`.

**Alone.** On the accepted state each fact in the pocket is asked its probes with its own note left out (and the other
in-weights notes, as production does). All right: its streak grows; `alone` nights running: `in_weights`, and from then
on every `"notes": true` chat request has that note excluded. One wrong: back to `promoted`, the streak starts again.

**Serving.** `openai.plan` adds the in-weights notes' current ids to the request's exclude list before the lookup, and
gives the lookup's ids to the promoter (retrieval counts). With promotion off neither runs.

**Scheduling.** One background thread. A night holds the learner's lock (`srv.teacher.learning`, as a learn request
does) and asks through `slide_ask.ask` side by side; the engine steps the learner only while no reply decodes (READ
`engine_api.Learner`), so serving goes on during a night.

**Crash.** The state file says a night is open, with the neurons it has placed so far, before any change to the
weights. A start that finds an open night marks the next night a `rebuild` and zeroes every recorded promotion neuron
first (and the neurons of a slide-graph fact with the text that was being taught).
