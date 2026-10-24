# Periodic Notes promotion

Promotion teaches retrieved, unchanged Notes into Sliding Weights on a writable model copy.
It is off until `--notes-promote-every` is supplied, and requires both `--notes` and `--slide`.
Explicit promotion settings without an interval are refused at startup.
A learned note stays available to chat retrieval until its own questions pass without that note
for the configured number of consecutive nights. An edited or withdrawn note returns to the
prompt immediately; stale promotion neurons are rebuilt on the next night.

## Controls

| Flag | Default | Meaning |
| --- | --- | --- |
| `--notes-promote-every DURATION` | off | Interval after the previous night finishes; seconds, or `s`, `m`, `h` suffix |
| `--notes-promote-hold N` | 1 | Unchanged nights after retrieval before teaching; at least 1 |
| `--notes-promote-alone N` | 2 | Consecutive successful nights without the note before prompt exclusion; at least 1 |
| `--notes-promote-regress all` or `N` | all | Current Notes checked for regression; 0 disables this subset |
| `--notes-promote-targeted on/off` | on | Neighbour, untold-answer and two-note probes |
| `--notes-promote-thinking on/off` | off | Repeat regression and alone checks with thinking enabled |

`GET /v1/promotion` returns the last published state, nights and per-fact status.
`POST /v1/promotion` queues a night and returns 202; it does not wait for completion.
With promotion disabled, these routes return 404. During an erase the cached report is withheld
until a sanitized state can be published. A report publication failure leaves cleanup pending.
The worker holds the normal engine lifetime lease during inference and recovery, wakes an idle
engine, and stops before the idle manager is destroyed.

## Decisions and recovery

The worker uses each note's stable write source, current lookup policy and question generation.
A retrieved, unchanged, undated note becomes eligible after the hold interval. Dated text is
screened heuristically; this is not a temporal reasoning guarantee. Missed or rejected lessons
receive one further attempt on a later night. Thinking checks are off by default.

The judge compares the model's answers with reference answers obtained with the note present.
Controls and targeted probes can reject a night. Whole-night checkpoints are separate from
per-lesson checkpoints: pocket values, quantized shard writes, replay, graph and teacher state
are restored for a refused plan. Failures keep recovery pending and prevent new lessons from
reusing neuron slots. On restart, persisted promotion state is reconciled with the Notes journal
before a new lesson is admitted. Each shared sentence or reversed fact carries a durable Notes
source key before fitting. Recovery finds partial lessons by that identity rather than whole-text
matching. A failed rewind retains its mark and the corresponding promotion address snapshot in
memory, so a later control retry restores the same checkpoint without LLM question generation.
Small cleanup/control retries run at most every five seconds; a failed full night waits for the
configured interval or an explicit POST before another full attempt. During a rebuild or failure,
notes remain in production prompts. A manual deletion of a promotion graph fact restores its note
to prompts and fences a rebuild before another lesson can reuse its slots.

The whole-night mark is not persisted. After a process crash, recovery retires recorded promotion
neurons; it does not promise to undo refits or quantized rounding of unrelated manually taught
facts from an interrupted night.

When a multi-fact night regresses, facts are retried in oldest-first order. This has a two-fact
blame limit: an interaction between two facts can cause the later fact to be rejected even when
it would pass by itself. Attribution is not proof that a rejected fact alone caused the regression.
Retired pocket slots are not compacted, so long-running promotion can exhaust available capacity.

## Erase scope

With the worker active, `DELETE /v1/notes/ID?erase=true` participates in the persisted Notes erase
transaction. It scrubs promotion text, questions, references, neighbours, pairs and night summaries
for every fact status, and clears pairs on affected partner facts. The reply names those partner
keys. It persists the scrubbed state and neuron addresses before retirement, zeros and saves the
recorded promotion neurons, removes their owned graph text, answers, questions and chains, then
commits retirement and publishes a sanitized report. The Notes mutex is released during model
retirement/saving; journal retirement uses the current records so concurrent writes survive.
An old interrupted lesson with no durable source identity remains pending instead of guessing.

Neuron, state or report failures leave the same erase retryable. A failure after physical retirement
keeps new lessons blocked until the state transaction is committed, including after restart.
The reply exposes `promotion_state`, `promotion_graph`, `promotion_neurons`, `promotion_report`, a nested promotion
result, `retryable`, and `cleanup_complete`. Permanent remaining-place warnings keep `complete`
false without retaining reversible journal token spans indefinitely.

New probe JSONL records contain hashes, opaque source keys, note IDs, verdicts and modes rather
than probe text. Hashes are not encryption and can be guessed for low-entropy values. An active
erase atomically empties the whole owned `.promote-probes.jsonl`, including control and cross-fact
copies; a failed purge keeps the erase retryable. With the worker disabled, every nonempty,
unreadable or oversized log remains named `promotion_probe_log`. Operator-captured learning or
historical promotion diagnostics remain named separately. Disabling the worker does not scrub an
earlier `.promote` state or retire its neurons: known retained state and neurons are reported as
remaining places; re-enable promotion on the same writable model copy to recover missing sources.

If an erase meets a busy worker, it returns pending. Background promotion cleanup can settle its
owned places, but the client must repeat the same DELETE for the final engine-place checks and
journal token-span retirement. The worker does not yet send a completion notification.

Selective promotion retirement does not prove that arbitrary Sliding Weights graph data, other
learned model weights, external logs, client copies or all the remaining places in
[Notes erase reporting](notes-store.md) are clear. An erase can therefore finish its actionable
cleanup while still reporting `complete: false`. Keep those diagnostics when assessing clearance.

## Validation scope

CPU tests exercise the real HTTP routes with inert learners, failure injection, restart recovery,
shared lesson handling and synthetic physical shard restoration. Native and CUDA host builds and
a Windows compile/link check cover integration and portability; Windows execution and real-model
Metal/CUDA qualification require separate receipts. Host tests do not establish learning quality,
model fidelity, GPU correctness or performance on a checkpoint.
