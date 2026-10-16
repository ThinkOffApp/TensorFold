# Note lookup during decoding (`--notes`, `"notes_decode"`)

The server's note lookup (NOTES-IN-ENGINE.md) runs before prefill, on the question alone. A two-step question ("What car does my sister drive?") often needs a note the question does not name ("Anna drives a red Volvo."); only the answer names Anna. This change runs the same lookup again while the reply decodes and puts a note in when the reply names who it is about. Written 16 October 2026 on branch `notes-decode-lookup` of our fork, from `notes-live-writes` at `d1d08b75`. Not pushed; no pull request.

Grades as in NOTES-IN-ENGINE.md: **MEASURED** (we ran it, on the machine stated), **READ** (in code or a document), **INFERRED** (our reasoning, not checked by a run). Every run below is one run, at temperature 0.

## Update, the same evening: a shorter pause, and most notes in before prefill

petrus found the pause, about 0.3 s an added note, too high. Four changes were tried, each measured on the 28 two-step questions (thinking off and on), the same 28 asked inside a conversation (a system prompt and an earlier exchange before the question, "conv"), the 20 control questions (thinking off and on) and the L6 1,000-note store (the compare harness, thinking off). Each configuration ran on a fresh test server (its own prompt cache); one run each, temperature 0, load averages 6 to 10 (MEASURED).

| Configuration | Right: 28, off | 28, on | conv, off | conv, on | Two-step replies with a pause (of 112) | Pause p50 / p95 | Control injections (of 40) | L6 1,000: right / two-step right; replies with a pause |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| lookup off | 1 | 0 | 3 | 0 | 0 | | | 21 / 4 |
| (a) at sentence ends: the first version's default | 13 | 23 | 3 | 23 | 100 | 357 / 695 ms | 0 | 22 / 5; 6 (p50 336 ms) |
| (b) before the assistant turn | 10 | 20 | 3 | 18 | 100 | 170 / 346 ms | | |
| (c) before the question | 5 | 13 | 3 | 19 | 100 | 213 / 443 ms | 0 | |
| (a) + name trigger | 15 | 23 | 21 | 23 | 100 | 385 / 721 ms | 0 | 22 / 5; 8 (p50 369 ms) |
| (c) + name trigger | 9 | 16 | 19 | 15 | 100 | 208 / 378 ms | 0 | |
| value hop, lookup off | 27 | 28 | 28 | 28 | 0 | | | 24 / 6 |
| value hop + (a) + name trigger | 27 | 28 | 28 | 28 | 8 | 463 / 586 ms | 0 | 24 / 6; 5 (p50 353 ms) |
| **value hop + (c) + name trigger: the new default** | 27 | 28 | 28 | 28 | 8 | 297 / 385 ms | 0 | 24 / 6; 5 (p50 168 ms) |
| block before the question, lookup off | | | 3 | 0 | 0 of 56 | | | |
| block before the question + (a) | | | 4 | 26 | 46 of 56 | 347 / 571 ms | | |
| block before the question + (c) + name trigger | | | 18 | 26 | 46 of 56 | 201 / 506 ms | | |

(The pause is pooled over the 28 and conv sets, both thinking modes. The new default's row is its own run; value hop + (c) + name trigger set by fields gave the same answers with a pause of 247 / 322 ms.)

**Recommended default, now the server's: the value hop, the name trigger, and placement (c) for what still comes in mid-reply.** With it every two-step reply with thinking off needed no pause at all (0 of 56), against 44 of 56 for the first version; with thinking on, 8 of 56 replies paused, all for notes about other people the reasoning named, which changed no answer. Right answers rose from 13, 23, 3 and 23 of 28 to 27, 28, 28 and 28, and on the 1,000-note store from 21 to 24 of 56 (two-step 4 to 6 of 16), where the first version reached 22. Each field still turns its part off: `"notes_value_hop": false` gives LLWZ's own lookup again (the compare harness then shows 56 of 56 blocks equal), `"notes_decode_names": false`, `"notes_decode_place": "first"`, and `"notes_decode": false` the whole decode-time lookup.

1. **Notes before the last user turn** (`"notes_position": "user"`). As asked, the whole block as a system message right before the latest user message, re-rendered there on a hit. For a one-turn chat it is the same prompt as before (the block is still the first system message). In the conversation set it changed the answers (21 of 28 replies changed tokens with thinking off, all 28 with it on) but not how many were right (3 and 0 of 28 either way), and it lost the prompt cache that the questions shared: the engine keeps no state right before the block, so the first token came at 294 ms p50 against 88 ms. Not the default. What does cut the cost is (c), `"notes_decode_place": "user"`: the first block stays where it is and a hit's notes go in as a short system message of their own right before the question, spliced into the prompt's tokens, where the engine keeps a state (the history's). Re-prefilled tokens p50: 44 (one turn) and 52 (conversation), against 470 and 674 for (a); pause 213 ms against 357 ms. But on its own (c) is less often right than (a): 5 against 13 and 13 against 23 of 28. Like (b), a separate notes message after the model began answering more often lets it end at "My boss is Henrik.".
2. **Value hop at input** (`"notes_value_hop"`, default on). LLWZ's subject+value hop, the vendored lookup's own code, with the snapshot's hop setting replaced for the request. Notes written over `/v1/notes` have no value entity, so the index now gives a written note the entity its text names (`notes/value.zig`; a snapshot's notes keep LLWZ's). All 28 facts were in the first block, so none of the 28 needed a mid-reply injection; the block grew from 418 to 468 tokens p50 (31 to 35 notes), 476 at most, inside the cap. The one miss ("What is my best friend's job?") had the fact in the block and answered with the name only. On the 1,000-note store 19 of 56 blocks differ from Python's (another setting than the snapshot's), and 3 answers more were right with the hop than without (24 against 21 of 56).
3. **The name trigger** (`"notes_decode_names"`, default on): a check also right after a token that ends a name of an entity with a current note outside the block. In the conversation set, where the model answered in one sentence, it lifted (a) from 3 to 21 of 28 with thinking off: the note comes before the model commits to a short answer ("Your uncle Bertil" ... "drives a green Saab.").
4. **No cancel and restart**: not done. Of the pause, the cancel (the engine finishing its round) is 40 to 60 ms p50 and the prefill and first token the rest (MEASURED). The lane engine can append tokens to a running stream (its forced tokens, used for the thinking budget's close), but nothing lets the server reach it mid-reply, the lone GPU driver would have to hand the stream back, and appended tokens land at the end of the reply: they could only carry the notes inside the assistant turn (closing it, a system message, reopening it), not before the question as (a) and (c) do, and they would arrive as reply tokens the server must hide (READ, `lanes/engine.zig`, `stream.zig`). Not attempted in this change.

**Tests of the update** (`zig/src/server/notes_decode_more_test.zig`, 6 tests): (c)'s exact continuation prompt (two system messages that normalizing would merge, the first request's tokens kept before the question); the name trigger (the note in after "Your sister Anna", where without it the check waits for the sentence end; a name whose notes are all in the block is no check point); the value hop (a note naming Anna brings Anna's note into the first block, inside the cap, and nothing is left to put in mid-reply; without a value entity nothing comes); a written note's value entity is the one its text names, a snapshot's keeps LLWZ's; `notes_position` with (a) and (c); and the defaults. The first file's tests send the first version's fields, so they still test it. Controls by hand: no name trigger, no value entities for written notes, and the snapshot's hop kept each make tests fail (4 of 20 in all). `zig build test test-golden -Dcpu=apple_m1` with an empty cache: 2,071 of 2,079 passed (8 skipped), 164 of 164 steps, the golden corpus 309 of 319 with 0 unexpected differences; the lean checker 527 problems, as before.

## In short (the first version)

- **Built** (`zig/src/server/notes_decode.zig`, hooks in `chat.zig` and `openai.zig`). For a chat request with `"notes": true`, at each sentence end of the generated text and at the latest every 48 tokens, the lookup runs over the last user message plus the reply so far (a thinking reply's reasoning included). A note not yet in the block qualifies when the query names its subject and its score is at least the top IDF weight. On a hit the engine request is cancelled at that token, the prompt is rendered again with the note in, and a new request carries the generated ids after it, so decoding goes on from them; the client's stream simply continues. At most 2 injections a reply, never a note twice, the notes the model sees stay within the cap (512), counted by the model's tokenizer.
- **Placement (a), the note in the first block, was the first version's default** (see the update above for the new one): on 28 two-step questions it was right 13 times with thinking off and 23 with thinking on, against 10 and 20 for (b), a short block before the assistant turn; with the lookup off, 1 and 0 (MEASURED). (b) costs less: pause p50 119 ms against 322 ms with thinking off, because it reuses the prompt cache up to the user message.
- **The task's example, MEASURED**: off, "My sister is Anna. I have no information about what car she drives."; on, "My sister is Anna. Anna drives a red Volvo.", the note put in after reply token 5 with a pause of 198.6 ms.
- **No injection in the controls** (MEASURED): 20 questions whose answers name nothing in the notes, thinking off and on: 0 injections in 1,109 checks.
- **Tests** (MEASURED): `zig build test test-golden -Dcpu=apple_m1`: 2,059 of 2,067 passed (8 skipped), 164 of 164 steps, the golden corpus 309 of 319 equal with 0 unexpected differences; at `d1d08b75`, 2,039 of 2,047. The 20 new tests are 10 counted twice.

## What it does

**When.** After each reply token the server decides whether to check: the token's text ends a sentence (`.`, `!`, `?` before closing quotes or brackets, a line break, `。！？…`), or 48 tokens passed since the last check. Checks stop after the second injection.

**What is looked up.** `lookup()` (LLWZ's, unchanged) over the last user message, a line break and the reply so far, with every note already in the block and the client's `notes_exclude` excluded, with the request's past view and cap.

**What qualifies.** A note not in the block, of an entity the query names, whose score is at least `topWeight = log(1 + (N - 0.5) / 1.5)`, the weight of a key one note alone has and the lookup's own subject boost (subject 1.0). The lookup's subject match covers entity names of 2 to 8 keys; names this tokenizer keeps whole ("Anna" is one token) never match there, so the check gives the notes of an entity named by a one-key name the same boost. For that the index keeps a map of one-key entity phrases beside its phrases (`index.zig`, three lines; `subjects()` never reads it, so the lookup's arithmetic and LLWZ equivalence are unchanged). Notes whose score comes from shared words alone never qualify, whatever the score: see the threshold below. The qualifying notes go in best first while they fit the cap.

**On a hit.** The tokens of the engine's round after the check point are dropped (never sent); the engine request is cancelled and drained; the continuation is the prompt rendered again with the note in, then the reply's ids so far; `max_tokens` is what is left of the request's. Chunk starts, shared cuts, history and rewind marks are made as `chat.prepare` makes them, for the new prompt.

- **(a) `"first"`, the default**: the first system message's block is rendered again with the new note, in told order, as `render()` orders a block; the rest of the prompt follows unchanged. Nothing after the block's first changed line can come from the prompt cache.
- **(b) `"turn"`**: a system message after the conversation holds the new notes' titles and lines (the first block's head is not said again; with no first block it is). The template keeps a later system message in place (a template that would make it a user turn gets (a)); the prompt cache's state at the user message is reused.

**Request fields** (read only with `--notes` and `"notes": true`; a 400 otherwise, and for a wrong type): `"notes_decode": false` turns it off for the request (A/B tests); `"notes_decode_place": "first" | "turn" | "user"` (default `"user"`, (c) of the update); `"notes_decode_names"` (default true); `"notes_decode_dry": true` checks and reports, puts nothing in; for the first lookup, `"notes_value_hop"` (default true) and `"notes_position": "first" | "user"` (default `"first"`).

**Reply and log.** The reply's `notes` field gains `decode`: on, place, checks, `capped` (checks whose qualifying notes did not fit), the injections (ids, shares of the top weight, the reply token, the notes' tokens after it, prompt and cached tokens, the pause and its parts) and why checks stopped; with `notes_echo` also each check's first candidates and the block. One log line per injection, for example (MEASURED):

```
[tensorfold] notes decode chatcmpl-21230a87c65875a7335d249ea2e217a8: [2] put in after reply token 5 (first), pause 198.6 ms (lookup 89.7 us, render 208.0 us, cancel 62.4 ms, prefill and first token 136.1 ms); prompt 121 tokens, 0 cached, 121 prefilled; notes 93 tokens
```

**Not for** structured output, required tool calls, logprobs, thinking budgets (the engine's own state would start over), completions, or `--cortheon` replies (its turns render their own prompts); the reply's `decode.stopped` says why. A write to the notes during the reply stops the checks (the block's ids are of the version it was read from).

## The threshold (MEASURED)

**Machine and model for every run below:** Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1 (26A434); `tensorfold-native` from this branch, `zig build native -Dcpu=apple_m1`; TensorFold/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit, revision `d9d758fb`; `--prompt-cache-gib 4 --context 32768 --keep-warm 0`, drafts on; temperature 0. A shared machine: load averages 6 to 19 during the runs, the Python server on port 8091 and the TensorFold.app engine resident and untouched.

**Store:** LLWZ's L6-seed1 teach snapshot (29 notes, 24 current) with 28 notes written over `/v1/notes`: 14 pairs of a relation note ("My uncle is Bertil.", subject "my uncle") and a fact about the name ("Bertil drives a green Saab.", subject "Bertil"), 44 current notes in all. Each question names the relation, not the name, and its fact note is not in the first block (checked for every question).

Dry runs (`notes_decode_dry`, thinking off) record each check's candidates. The 14 questions' replies and 20 questions about other things (capitals, a haiku, how to boil an egg, why cats purr) give, by the best candidate's score over `topWeight`:

| Score threshold alone | Control replies with a candidate over it (of 20) | Case replies whose fact note reaches it (of 14) |
| ---: | ---: | ---: |
| 1.0 | 12 | 8 |
| 1.5 | 7 | 7 |
| 2.0 | 4 | 6 |
| 3.0 | 1 | 4 |

Shared words in a small store score high: "the same" or "I have" are in one or two of 44 notes, and a long answer about hiking or cats matched unrelated notes at 2.3 and 3.1 times the top weight, while a fact named by a one-token name scored 0.86. No score threshold separates them. The subject match does: of all candidates in all those replies, none that the reply named was a wrong note, and 9 of the 14 fact notes were named (two more matched on words only: "keeps", and "(Pekka)", which the tokenizer splits otherwise than "Pekka"; in three replies the fact note was no candidate). So a note qualifies when it is named, and the score threshold is the subject boost itself, which every named note has.

The unit tests carry the same controls: an unnamed candidate scoring over the threshold is not taken, and an answer that names nothing puts nothing in.

## Placement and the pause (MEASURED)

The 14 cases, each asked in two wordings (28 questions), with the lookup off, (a) and (b); the answer is right when it holds the fact's value (Saab, cello, Tampere, ...). Thinking off, `max_tokens` 160; thinking on, 1,500, the answer graded without its reasoning. A fresh server for each mode's set; the injections' prompt and cache counts are the engine's.

| Thinking | Mode | Right (of 28) | Injections (with the case's fact) | Pause p50 (min, max) | Cancel p50 | Prefill and first token p50 | Prefilled tokens p50 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| off | lookup off | 1 | 0 | | | | |
| off | (a) first block | 13 | 22 (22) | 322 ms (76, 401) | 22 ms | 296 ms | 470 |
| off | (b) before the turn | 10 | 22 (22) | 119 ms (61, 151) | 21 ms | 95 ms | 44 |
| on | lookup off | 0 | 0 | | | | |
| on | (a) first block | 23 | 39 (23) | 316 ms (122, 472) | 40 ms | 275 ms | 564 |
| on | (b) before the turn | 20 | 43 (22) | 148 ms (119, 379) | 41 ms | 108 ms | 149 |

Paired: (a) was right where (b) was wrong in 4 questions with thinking off and 3 with thinking on; the other way, 1 and 0. With (b) the model more often ended its answer at the sentence the note came after ("My boss is Henrik." and nothing more); with (a) it went on ("Henrik was born in Tampere."). So (a) is the default and (b) is a request field. The pause is the time between the last token before the note and the first one after it, at the server; (a) prefills the whole prompt from the block on, so its pause grows with the conversation behind it (INFERRED: measured only on one-turn prompts of about 450 to 550 tokens).

With thinking on, a reasoning that lists the notes names other people too: 16 of (a)'s 39 injections were other people's notes (from the reply naming them), which take one of the two injections. Reading only the answer avoided that but came too late: 0 of 14 right (the first wording, an earlier build), the same as with the lookup off.

Each check costs a decode of the reply so far, an encode of question and reply and the lookup: p50 0.1 ms a check with thinking off, 0.9 ms with thinking on (long reasoning), 43 ms a reply in all at p50 and 273 ms at most, on the reply's own thread while the engine goes on decoding.

| Case | Relation and fact | Wording 1 / wording 2 | Thinking off: off, (a), (b) | Thinking on: off, (a), (b) |
| --- | --- | --- | --- | --- |
| 0 | uncle Bertil, green Saab | What car does my uncle drive? / What kind of car does my uncle have? | . . / Y Y / Y . | . . / Y Y / . Y |
| 1 | neighbour Greta, cello | What instrument does my neighbour play? / Does my neighbour play any instrument? | . . / . . / . . | . . / Y Y / Y . |
| 2 | boss Henrik, Tampere | What is my boss's hometown? / Which town does my boss come from? | . . / Y . / . . | . . / . Y / . Y |
| 3 | niece Lotta, marine biology | What subject does my niece study? / What is my niece studying? | Y . / Y Y / Y Y | . . / Y Y / Y Y |
| 4 | cousin Mikael, goats | Which animals does my cousin keep? / What pets does my cousin have? | . . / . . / . . | . . / . Y / . Y |
| 5 | aunt Sirkka, rye bread | What does my aunt bake? / What does my aunt like to bake? | . . / Y . / Y . | . . / Y . / Y . |
| 6 | landlord Pekka, old radios | What does my landlord collect? / What is my landlord's hobby? | . . / . Y / . Y | . . / Y Y / Y Y |
| 7 | best friend Jonas, ferry captain | What is my best friend's job? / What does my best friend do for work? | . . / . Y / . Y | . . / . Y / . Y |
| 8 | dentist Ilona, marathons | Which sport does my dentist do? / What does my dentist do for exercise? | . . / . Y / . Y | . . / Y Y / Y Y |
| 9 | coach Ville, spiders | What is my coach scared of? / What is my coach afraid of? | . . / . . / . . | . . / . Y / . . |
| 10 | godmother Maria, tomatoes | Which vegetable does my godmother grow? / What vegetables does my godmother grow? | . . / . . / . . | . . / Y Y / Y Y |
| 11 | piano teacher Peter, Japanese | Which foreign language does my piano teacher know? / What language does my piano teacher speak? | . . / Y . / . . | . . / Y Y / Y Y |
| 12 | roommate Laura, yellow Volvo | What car does my roommate drive? / Which car brand does my roommate own? | . . / Y Y / Y Y | . . / Y Y / Y Y |
| 13 | grandfather David, train driver | What did my grandfather work as? / What job did my grandfather have? | . . / . Y / Y . | . . / Y Y / Y Y |

With thinking off, most misses are answers that end at their first sentence ("My godmother is Maria."): the note comes in at that sentence end and the model then ends the reply. A check before the sentence ends (at a name) was not tried.

**The task's example** on its own store ("My sister is Anna.", "Anna drives a red Volvo." and six other notes), "What car does my sister drive?" (MEASURED, the binary of `cf9c6c2e`):

| Mode | Thinking off | Thinking on (answer) |
| --- | --- | --- |
| lookup off | "My sister is Anna. I have no information about what car she drives." | "Based on the information you've shared, your sister's name is Anna, but there's no mention of what car she drives. ..." |
| (a) | "My sister is Anna. Anna drives a red Volvo." (note 2 after token 5, pause 198.6 ms) | "Your sister Anna drives a red Volvo." (note 2 after reasoning token 54, pause 224.3 ms; then Otto's note, which the reasoning named, 220.9 ms) |
| (b) | "My sister is Anna. Anna drives a red Volvo." (pause 163.6 ms) | "Your sister Anna drives a red Volvo." (pauses 205.7 and 208.6 ms) |

## The L6 harness, off against on (MEASURED)

`tools/notes/run.py compare` (17fa3fc5), with the engine request given `"notes_decode": false` for the off run (a copy of the script with that one option; the repo's file is unchanged), `--prompt-cache-gib 0` as in NOTES-IN-ENGINE.md. It compares the engine's block and answer with Python's block sent by the client; it does not grade answers. The 56 L6-seed1 questions, 16 of them two-step:

| Store | Mode | Block equal | Answer equal to the client-block answer | Checks | Injections | Checks the cap stopped |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| L6 teach (24 current) | off | 56 | 56 | | | |
| L6 teach | on | 56 | 56 | 71 | 1 | 0 |
| sweep, 1,000 notes (472 current) | off | 56 | 56 | | | |
| sweep, 1,000 notes | on | 56 | 51 | 77 | 6 | 18 |

On the teach store the one injection (Q22, after the answer's last sentence) changed no token. On the 1,000-note store 5 answers changed. The repo has no grader for these answers; ours (the reply holds the expected value of the teach phase, a yes or no first for yes/no questions, "don't know" and the like for unknowns; a rough grader of our own, not LLWZ's) gives on the teach store 39 of 56 both ways (two-step 11 of 16), on the 1,000-note store 21 of 56 off and 22 on (two-step 4 and 5 of 16: "Which country does my brother live in?" became "My brother lives in the same city as my sister. My sister lives in Turku. Turku is in Finland."). There the first blocks are near the cap (485 of 512 tokens at p50, 440 to 491): 18 checks had a named note that did not fit. The 10,000 and 100,000-note stores were not run.

## Tests (MEASURED)

`zig/src/server/notes_decode_test.zig`, 10 tests, with a word-level test tokenizer that folds "Anna" and " Anna" to one key and a scripted engine (four tokens a round, every prompt kept):

- check points (sentence ends, the 48-token cadence);
- what qualifies: a one-key name, a two-key name (the lookup's subject match); controls: "I have a red bicycle too" scores over the threshold against an unnamed note and is not taken, an answer naming nothing gets nothing;
- the switch with (a) and (b): the exact continuation prompt (the enlarged block, or the late block, then the reply's own ids), the round's tokens after the check point never sent, one cancel; the stream's deltas are the reply once, in order;
- never twice (with a control: the same check without that note held takes it); two injections at most (a control: the third would qualify); the second continuation starts from the prepared prompt with both notes;
- the cap at its boundary for (a) and (b): one token less and the note stays out;
- off: one request, the same first prompt, the engine's reply as it was; a dry run reports and puts nothing in; a thinking reply's reasoning brings the note in before the answer; the request fields' refusals.

```sh
ZIG=zig bash zig/tests/server/zig_test.sh --test-filter notes_decode_test
```

```sh
zig build test test-golden -Dcpu=apple_m1 --summary all
```

Alone: 14 of 14 (the 10 and the module's 4 unconditional tests). Full suite: above. Controls checked by hand, each put back afterwards: reading the mailbox once before the loop (the first version's bug, which re-sent the reply and freed a request the engine still ran) fails 5 of the 10; building the second continuation from the enlarged block fails 1; no cap check fails 1; qualifying by score alone fails 4. `python3 tools/zig/lean_check.py`: 527 problems before and after.

## Not done

- (Done in the update: a check at a name before the sentence ends.)
- With thinking on, the reasoning names people the question is not about; their notes take pauses (8 of 56 two-step replies) and change no answer here.
- A state kept right before a block placed before the question (`notes_position`), so that the conversation before it stays cached across turns: the engine's marks do not allow one there now.
- (a) on long conversations: nothing after the block comes from the prompt cache, so its pause grows with the conversation (not measured). Keeping a state at the block's end would need a mark the first prefill does not set now.
- The checks decode and encode the whole reply each time (0.9 ms a check at p50 in long reasoning); an incremental query was not written.
- Sampled replies: the continuation's sampler starts again from the request's seed (only temperature 0 was measured).
- The 10,000 and 100,000-note stores; only one run of each measurement; the receipts are not committed (scripts and JSON lines in the session's scratch directory).
