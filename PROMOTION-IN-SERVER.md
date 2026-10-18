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

**Regression set (since `4274b6b9`).** Besides the promoted facts' learner questions and the 4 controls, every
current fact note's own question joins it (`--notes-promote-regress N`: a sample of N by key hash; default all). The
question is written once per note by the untaught model ("the one short question the user would ask you later to hear
this again"), with its reference answer (the untaught model, the fact before it), and kept in the state. The night's
log and state name every question that went worse (`worse_list`: question, new reply, old reply).

**Right, without a key.** A probe agrees with its reference when the reply says every answer word the reference
took from the fact (the learner's `wording.recalls`), or, for a terse reply, when it says the reference's value words
(in the reference and the fact, not fillers, not the question's words by stem): every name and number among them and
half of the rest. The GB10 rerun's night 2 was rejected on "What eye colour has my dog? -> Grey (was Your dog has grey
eyes.)", a right reply the learner's check alone refuses ("eyes" not said); `agreesWith` takes it and still refuses
"Your dog has brown eyes." and "Your sister is called Maria." for Ana (host test). The rerun itself runs `d660eac3`. Since `6cc520f8`'s review (codexmb: "Not grey." and "I do not know whether grey." passed): a
reply with a denying, doubting or choice word (not, no, n't, never, maybe, perhaps, possibly, probably, might, whether,
or, either, neither, nor) never agrees, by either path; the terse path takes at most 8 words and refuses a reply naming
a word of another current note that this fact and question lack ("Grey or brown.", "Brown, not grey."). This changes
the night's acceptance judge. On the stored night-2 probe of the rerun (its only worse one) the new judge accepts
"Grey", so that night flips to accepted (INFERRED: the probes' before replies are not stored, so whether another probe
would then count as worse is not known).

**Publishing the in-weights list.** The report and every key are staged first, then swapped in under the lock with
the cache generation bump; a failure at any allocation leaves the old report, list and generation whole (codexmb's
review of `9cf5180e`; an allocation-failure sweep over the publish fails on the old code, with a leak).

**Targeted probes (since `b7dc1f3b`).** The day-2 diagnosis (both GB10 runs, the same 4 questions lost against
the notes-only control, each with the same block) found three kinds of damage the single-fact probes cannot see: a
taught value given to the same attribute of someone else ("my sister's eyes" became green), a made-up answer to a
personal question nobody answered ("my rabbit" became Floppy), and two-note answers broken (the cat's eyes against
mine, a two-step country). So each fact taught or in the pocket gets, written once and kept in the state:
its own question with its subject swapped for a near relation and for someone nobody told of ("my cat's eyes": "my
sister's eyes", "my neighbour's eyes"; the learner's `slide_route.others` alone gives "my sister's cat's eyes", which
misses the day-2 loss, host test), then asked of the model, at most 3;
and one question needing it and the current note sharing the most words with it (written by the untaught model, a
yes/no comparison or a two-step question, with its reference answer from both facts). Three fixed untold personal
questions join the controls. A neighbour or untold probe is worse when "don't know" turns into a value or the reply
changes in substance; a two-note probe when right turns wrong (a yes/no reference: the same yes or no). The log names
each by kind. Since `8596a471`'s review (codexmb): a "don't know" reply that still gives a value the earlier reply and the
question lack (a name, a number, or a word of a stored note: "I don't know for sure, but your rabbit is named
Floppy.") counts as giving it; a yes/no reference is matched on the whole first word ("Yesterday" is neither). Every
probe's two replies and verdict go to `SNAPSHOT.promote-probes.jsonl`, so a night can be judged again later. Host test: a lesson that leaks a value to neighbours, one that invents an untold answer and one that
flips a two-note answer each reject the night; control: the same night with no damage is kept.

**Retry.** A missed or rejected fact is due once more the next night (`retries`, kept in the state); not a third time.

**Alone.** On the accepted state each fact in the pocket is asked its probes with its own note left out (and the other
in-weights notes, as production does). All right: its streak grows; `alone` nights running: `in_weights`, and from then
on every `"notes": true` chat request has that note excluded. One wrong: back to `promoted`, the streak starts again.

**Serving.** `openai.plan` adds the in-weights notes' current ids to the request's exclude list before the lookup, and
gives the lookup's ids to the promoter (retrieval counts). With promotion off neither runs.

**Scheduling.** One background thread. A night holds the learner's lock (`srv.teacher.learning`, as a learn request
does) and asks through `slide_ask.ask` side by side; the engine steps the learner only while no reply decodes (READ
`engine_api.Learner`), so serving goes on during a night.

**Erase.** `DELETE /v1/notes/ID?erase=true` of a note whose fact is in the pocket zeroes that fact's neurons through
the learner's `retire` (the same op a learn request uses when a newer chat fact replaces an older one) and saves the
pocket into the model's files before the reply, which says so (`promotion: {zeroed, facts, ms}`). The store is the record: every fact in the pocket whose note the store no longer holds is
a target. The state keeps the fact's neurons until the zeroing succeeded; only then is the fact `freed`, and only once
the state file is written and the in-weights list refreshed is the erase reported done. A refused zeroing, a state
write that fails or a refresh that fails is reported `pending: true` with `failed`, and is done again after the next
night, before the next one, and at the next start (codexmb's review of `b40461d0`: the first version marked the fact
freed and dropped its neurons even when the learner refused, and reported done without the state written). While the
learner is busy (a night or a lesson) the erase is `pending` and done when it is free. Every refresh of the in-weights
list goes through one path that marks a failure (`publish_pending`); a later try refreshes it even when nothing is
left to zero, and a start with a failing refresh starts marked (codexmb's review of `d660eac3`: the reload's refresh
bypassed the test switch, and a try with nothing to zero never refreshed). A state write that fails puts the facts
and the pocket back as the file has them, without allocating (an allocation-failure test found the first version of
this relied on a reload that itself allocates). Zeroing one fact's neurons removes their output exactly (READ `pocket.retire`:
input and output weights set to zero); what it cannot undo is a later lesson's refit of an earlier neuron (question 1).
Take-backs and changes do not zero anything at once: the note answers, and the next night rebuilds the pocket.

**A failed night.** Any error inside a night (an allocation, the learner, a stop) marks the state to rebuild and
allocates nothing more: the pocket is recorded before each lesson, and the open night names the text being taught.
The next night first adds the neurons the slide graph records for that text (a lesson that placed neurons but failed
before they were recorded), then zeroes every promotion neuron and teaches again. The first version reloaded the
state file, which allocates; an allocation-failure sweep over a night (73 failing points) found that a lesson's
neurons could also go unrecorded when the allocation after it failed.

**Crash.** The state file says a night is open, with the neurons it has placed so far, before any change to the
weights. A start that finds an open night marks the next night a `rebuild` and zeroes every recorded promotion neuron
first (and the neurons of a slide-graph fact with the text that was being taught).

## Tests (MEASURED, this Mac, Zig 0.17.0)

`zig build test-server -Dcpu=apple_m1`: 312 of 312 before (`10cb2e22`), 324 of 324 after. The 12 new tests
(`-Dtest-server-filter=promotion`): with a scripted learner, qualification (unused, take-back and dated notes never due;
hold 2 waits a night), teach keep and miss, the alone streak (in weights after 2 nights; one miss back, streak from
zero), a night that changes a control rejected and its neurons zeroed (control: the same night without the breaking
fact is kept), a change rebuilding the pocket, every rebuild worse ending at the untaught model, the state across a
restart and a crash mid-night (rebuilt, its neurons zeroed), the state file; in a server (the notes rig), an in-weights
note left out of the chat block exactly as a client's `notes_exclude` would, its block counted as use, the same block
byte for byte with promotion off, an erase's renumbering followed, an erase zeroing the fact's neurons at once or after
the running night, kept across a restart; the flags. Lean checker: 530 problems before and after, none in new files.

## On a GB10 (asus3), CUDA (MEASURED, 17 October 2026)

Branch built at `e094e00d` (erase hook: `b40461d0` for the gate below), sm_121, Nemotron 3.5 Lightning MLX 4-bit
(`d9d758fb`), a copy of the folder, `--slide --notes nights-day1.snap.json --notes-promote-every 10m` (hold 1,
alone 2), `--prompt-cache-gib 0 --context 32768`. Day 1 is the snapshot (LLWZ's day-1 store); later lessons are
written over HTTP (`POST /v1/notes`; a change names the note it replaces; a take-back is a DELETE). Each day the 56
questions are asked with `"notes": true`, thinking off, greedy, 160 tokens, and judged by LLWZ's judge (main
`2083ee9` and the 7.8 run's `llwz-promo2`, which agreed on every day). The control arm is the same store each day on
the untaught model (no promotion).

| Day / after night | Right (system) | Right (control, notes only) | Python 7.8 system / control | Prompt tokens per answer | In weights | In pocket |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| day 1 | 40/56 | 40/56 | 40 / 40 | 166.6 | 0 | 0 |
| day 2 (after night 1) | 30/56 | 34/56 | 34 / 34 | 262.4 | 0 | 7 |
| day 3 (after night 2) | 38/56 | 42/56 | 45 / 43 | 320.6 | 2 | 7 |
| day 4 (after night 3) | 39/56 | 39/56 | 40 / 40 | 345.7 | 0 | 0 |
| day 5 (after night 4) | 44/56 | 39/56 | 40 / 40 | 345.7 | 0 | 7 |
| after night 5 | 43/56 | 39/56 | - | 325.8 | 2 | 7 |
| after night 6 | 43/56 | 39/56 | - | 325.8 | 2 | 7 |

| Night | Due | Stale | Plan kept | Taught (kept/missed) | Regression | Alone right | Left prompt | Seconds | Model folder bytes |
| --- | ---: | ---: | --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | 10 | 0 | add | 10 (7/3) | 0 worse of 4 | 11/21 | 0 | 2183 | 18,548,876,048 |
| 2 | 10 | 0 | none (add rejected, its neurons zeroed, then 0 worse) | 10 (9/1) | rejected | 9/21 | 2 | 2167 | 18,548,876,048 |
| 3 | 8 | 0 | source (add rejected; after zeroing still 1 worse) | 8 (5/3) | rejected | - | 0 | 1172 | 18,548,876,048 |
| 4 | 7 | 0 | add | 7 (7/0) | 0 worse of 4 | 12/24 | 0 | 1276 | 18,548,876,048 |
| 5 | 0 | 0 | none | 0 | - | 12/24 | 2 | 3.6 | 18,548,876,048 |
| 6 | 0 | 0 | none | 0 | - | 12/24 | 0 | 3.5 | 18,548,876,048 |

Disk: the untaught folder is 18,544,234,457 bytes; the taught copy 18,548,876,048 after every night (the first save
widens the shards; every later save rewrites the same four shards in place). No per-night copy of the weights is
kept; the run folder grew by 1.6 MB over six nights (state, journal, logs). The whole run used 19.1 GB on asus3.

Read with care: day 2 and day 3 are 4 below the control with 7 facts in the pocket and their notes still in the prompt
(INFERRED: the pocket disturbs other answers; no regression probe caught it, because the probes are the promoted
facts' own questions and four controls, not the 56). Day 5 is 5 above the control with a fresh pocket of 7. When the
two in-weights notes left the prompt (after night 5) one more question went wrong (44 to 43) and prompt tokens fell
by 19.9 per answer. Which regression probe went worse on nights 2 and 3 is not logged (a gap).

## Ash's gate (MEASURED)

Metal, this Mac (M5 Max), binary at `b40461d0`, a 1-note snapshot and two written facts, nights on request:

| Check | Result |
| --- | --- |
| off by default | `/v1/promotion` 404 without the flag; with it off, the chat block equals the old one byte for byte (rig test) |
| neurons alone vs note in prompt | "My dog is named Luna." (in weights, its note left out): 3/3 right, as with the note (3/3) |
| unrelated prompts | 32 of 32 fixed unrelated prompts give the same reply token for token before and after promotion |
| erase | 10 neurons zeroed and saved in 465 ms (the pocket save writes 250 MB in about 0.5 s); the dog's questions 0/3 after, 0/3 after a restart; the car, not erased, 3/3 (its note still in the prompt: it never passed alone) |

CUDA, the taught GB10 folder after the run (7 facts in the pocket, 2 in weights):

| Check | Result |
| --- | --- |
| unrelated prompts | 28 of 32 equal to the untaught model token for token; the 4 others part after 76 to 166 characters with the same answer |
| neurons alone vs note | the 56 questions with every note 44/56; with all 7 promoted facts' notes left out 39/56 (production leaves out only the 2 in weights: 43/56) |
| erase | "My dog's eyes are brown now." (promoted): 10 neurons zeroed and saved in 3.8 s; its questions without its note 1/3 before the erase, 0/3 after and 0/3 after a restart (the answers say grey, the note the erase brings back) |

So on CUDA the gate's second point is not met for the facts that never passed the alone check (they stay in the
prompt, which is the design), and the 2 in-weights facts cost one question when their notes left. Unrelated drift is
0 of 32 on Metal and 4 of 32 (late, same answer) on CUDA.

## Not done

- No pocket checkpoint op (exact rollback) or pocket compaction (open questions 1 and 2).
- The regression set does not log which probe went worse; the learner's degenerate wordings ("the boat's colour's
  colour's ...") are used as probes as the learner wrote them.
- Missed and rejected facts are never retried; only 2 of 29 facts reached in weights on the GB10 run.
- A Metal run of the full nights set; Metal was the two-fact gate only.
- Not pushed; no pull request.
