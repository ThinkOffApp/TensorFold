# TensorFold Notes: bounded writes and an erase that reaches everything (design)

Branch `notes-write-erase-design`, from `notes-review` at `2c9e7599`. This is a design only: no code changed. It
covers the two open gates named in the [README](../README.md) and [the write-path plan](../NOTES-WRITE-SCALING.md):

- **Gate 1, bounded writes**: a write whose cost does not grow with the number of notes in the store.
- **Gate 2, erase that reaches everything**: an erased note gone from the store, the journal, the prompt cache,
  saved conversations and, with promotion, the neurons; and an erase reply that says honestly what it reached.

How each claim was graded, as in the other notes documents:

- **READ**: read in the code at `2c9e7599` (or the named branch), with `file:line`. Paths are under `zig/src/` unless
  given in full.
- **MEASURED**: a number from an earlier run, with the document that holds the receipt. Nothing was re-run for this
  design.
- **REPORTED**: a number given in the request for this design (the write median and the merge time below); its
  receipt is not in this repository.
- **INFERRED**: our own reasoning, not run.

Words used throughout:

- A **note** is one sentence the user told, stored with its token ids and a rendered **line**
  (`[12] "My dog is Luna."`, plus a label when it was replaced or withdrawn).
- A note's **place** is its position in the store's arrays (0, 1, 2, ...). Its **id** is the number in its line.
- The **index** is what a lookup reads: per-note columns (id, state, time told, line, line cost in tokens, ...),
  groups (an entity's current notes, a pair's notes), name tables and the n-gram index.
- A **version** is one immutable build of the index. A lookup takes the current version, reads it without a lock and
  hands it back; a write builds the next version and swaps it in (copy-on-write).
- The **suffix array** (SA) is the default n-gram index (`notes/index.zig:44`): every suffix of every note's token
  keys, sorted, so an n-gram's notes are one binary search away. Its **base** covers the notes up to some place; the
  **side buffer** holds the notes written since, as posting lists (an n-gram mapped to the notes that hold it).
  A **merge** builds a new base over every note and empties the side buffer.
- The **journal** is `SNAPSHOT.journal`, the file beside the snapshot that holds every write since the snapshot; a
  write is answered only after its record and its commit line are synced to the drive.
- The **prompt cache** keeps the engine's computed state (the KV cache and recurrent state) for prompt prefixes, so a
  later request that starts with the same tokens resumes instead of reading them again.

## Summary

**Gate 1.** Today every write that adds a note builds a whole new index: it copies every note's columns, re-sorts
every note for the tie order, regroups every entity and pair, re-encodes every current name note with the tokenizer,
and re-checks every written note's value entity (READ, `notes/index.zig:270-328`). The suffix-array base is reused
for up to 1,024 notes after it; the write that passes that count rebuilds the base over every note, synchronously,
inside the writer lock, before its own journal append (READ, `notes_store.zig:374-391`). The writer model also scans
lists that grow with the store (READ, `notes/model.zig:138-156`, `notes/write.zig:66-78`), and every lookup after an
add throws away its pooled scratch and allocates one sized to the whole store again (READ, `notes_store.zig:250`).

The proposed design keeps the journal exactly as the record and changes only what is derived from it: an immutable
**base** (columns, groups, tables, suffix array) shared by many versions, plus a small **delta** per version (the
notes written since the base, and changed states, lines and costs of base notes). A write then costs its intake,
O(delta) work, its journal sync, and a pointer swap. Merges move to a background thread, become a linear merge of two
sorted suffix arrays instead of a full re-sort, and publish a new base only when it is complete; readers keep their
version (base pinned by a reference count) until they release it.

**Gate 2.** Today an erase rebuilds the store from the snapshot and journal without the note's write, rewrites the
journal, frees and zeroes every old version once no lookup holds it, drops pooled lookup scratch and clears the
tokenizer's encode memo (READ, `notes_ops.zig:145-231`). It does not reach: the engine's prompt cache (there is no
call from the server into it at all, READ, `core/engine_api.zig:329-343`); prompt states that `--learn` wrote to disk,
which hold the notes block because the block is a leading system message and so lies inside the "shared system
block" cuts that `--learn` persists (READ, `chat.zig:124-127`, `core/prompt_learn.zig:10`); the Responses store,
Cortheon's hidden rounds and the compaction memory files on disk (READ, `responses.zig:40-110`,
`cortheon/memory.zig:10-45`, `compact_mem.zig:42-66`); requests already decoding. The reply's `"complete"` field is
computed from one fact only, whether the engine has a prompt cache (READ, `notes_http.zig:195-203`), so a server with
`--compact-memory`, `/v1/responses` storage or `TENSORFOLD_REQUEST_LOG` answers `"complete": true` while copies remain.
On the promotion branch the erase zeroes the fact's neurons and keeps them zeroed after a restart, but the fact's
text, its questions and reference answers stay in the promotion state file, in the probe log and in the Sliding
Weights fact graph (READ, `notes-promotion` at `ad6ed646`, details below).

The proposed design makes an erase two-phase. **Accepted**: one journal record ("erase w12") synced, the note masked
in a new version, every in-flight request whose block held it cancelled, and every cache told to drop what it holds
of it, all before the reply: a few milliseconds plus the drive sync. **Complete**: within a stated deadline, the
journal rewritten without the note, the store rebuilt as never taught, every old version freed (zeroed), the prompt
cache and its disk states, the saved conversations and the promotion records purged, each path confirmed. The reply
and a status query distinguish the two and name every path that is not done.

**Proposed order of work** (each step after codexmb's `notes-integrated` work lands; see the last section): (1) make
the erase reply honest (small); (2) the writer model's lookup maps and the scratch headroom (small, large wins);
(3) the prompt-cache forget call with note tags, and `--learn` file deletion (core and native code, little overlap
with codexmb's files); (4) the base-plus-delta version and the background merge; (5) the two-phase erase with the
journal's erase record; (6) saved conversations and promotion residues; (7) snapshot checkpoints, which also make
snapshot notes erasable.

---

## Gate 1: bounded writes

### What a write does today, and why each step costs what it does

A write over HTTP (`POST /v1/notes`) or from a chat request's own statement (`notes_route.zig:107`) goes through
`ops.perform` (`notes_ops.zig:78-136`). Its steps, in order:

1. **Take the writer lock** (`notes_ops.zig:79`). One write at a time; listing the notes also takes it
   (`notes_ops.zig:245`).
2. **Intake on the writer's model** (`notes/write.zig:117-201`, called at `notes_ops.zig:104`). The model is the
   mutable record a snapshot loads into (`notes/model.zig`).
   - `entityOf`, `attributeOf` and `pairOf` are linear scans over every entity, attribute and pair
     (`notes/model.zig:138-151`). Every new note adds an attribute `note:wN` and a pair of its own
     (`notes_ops.zig:87`), so these lists grow with every add: a write's scans grow with the store.
   - `duplicates` (`notes/write.zig:66-78`) loops over **every** note of the store to find current facts of the same
     subject with the same normal form, and normalizes each candidate's text again for every write.
   - A change whose target was erased scans every note for the pair's current ones (`notes/write.zig:100`).
   - `placeOfSource` is a linear scan over the written notes (`notes/model.zig:154-156`).
   - The note itself is encoded, its line rendered and its line's tokens counted: bounded by the note's length.
3. **Build a whole new index version** (`notes_ops.zig:110` -> `Store.build`, `notes_store.zig:374-391` ->
   `Index.buildWith`, `notes/index.zig:270-328`). This is the part that grows with the store:
   - a temporary `Raw` record for every note, copied from the model (`notes/index.zig:293-295`);
   - `placeNotes` (`notes/index.zig:385-444`): every per-note column allocated and copied again (id, state, told,
     entity, pair, value entity, line, cost); an id-to-place array sized to the highest id; **a full sort of all
     notes** by (newest told first, then id) only to assign each note its tie rank `trank` (`:415-428`); a scan for
     the cheapest line (`:438-440`);
   - `groupsOf` (`notes/index.zig:447-500`): every entity's current notes, every entity's pairs and every pair's
     notes, rebuilt from scratch;
   - the entity names, attribute names and pair attributes duplicated (`notes/index.zig:299-307`);
   - `phrasesOf` (`notes/index.zig:503-515`): the entity phrase and one-key name tables rebuilt;
   - `value.ofWrites` (`notes/value.zig:8-17`): for **every written note** without a value entity, its tokens are
     matched against the phrase tables again, and the whole value-entity column is copied when any is found;
   - `alias.populate` (`notes/alias.zig:42-79`, called at `notes_store.zig:385`): every current name note's value
     **encoded with the model's tokenizer again**, per write;
   - the n-gram index: with `--notes-index postings`, posting lists over every note (`notes/index.zig:518-574`); with
     the suffix array (the default), the side buffer's keys and postings, rebuilt from all of the side buffer's notes
     (up to 1,024; `notes/index.zig:321-326`, `:331-347`), or, past 1,024 notes since the base, **a new base over
     every note** (`notes_store.zig:376-378`, `notes/index.zig:322` -> `baseOf` `:350-365` -> `sa.build`
     `notes/sa.zig:214-327`: a dictionary of every key, every note's codes copied, both views' suffixes radix-sorted
     and the ties sorted whole).
4. **Append and sync the journal** (`notes_ops.zig:120`, `notes/journal.zig:138-160`): the record, then its commit
   line, each synced with `F_FULLFSYNC` on macOS. Bounded by the record's size, plus the drive's flush.
5. **Swap the new version in** (`notes_ops.zig:129-133`, `notes_store.zig:349-355`) and free retired versions no
   lookup holds (`notes_store.zig:332-346`).

After the swap there is a sixth cost, paid by readers: a pooled lookup scratch is reused only when its arrays are at
least as long as the store (`notes_store.zig:250`). The scratch holds one slot per note (`notes/lookup.zig:44-55`),
so after every add the next lookup on each thread frees its scratch and allocates and clears a new one sized to the
whole store.

**Why it was built this way (READ, from the code's comments and NOTES-IN-ENGINE.md:222).** Copy-on-write makes
concurrency simple and exact: a version is immutable, a lookup never waits, and "the index after a write is exactly
what a snapshot of that store would load". The index lives in one exact-size arena per version
(`notes/index.zig:130`), so a version cannot share arrays with the one before it: changing one entry means copying
the arrays. The tie rank is a global order, so one new note shifts every rank. Nothing here is wrong; it is the
simplest correct version, and its cost is proportional to the store.

**What that costs (MEASURED, NOTES-IN-ENGINE.md:258-267, postings index, Apple M5 Max).** A write took 3.9 ms (median)
at 29 to 769 notes, mostly the drive sync; 14.5 ms at 10,000 notes and 121 ms at 100,000. **REPORTED** for this
design, with the suffix array: a median write of 3.9 to 4.8 ms, and a base merge about every 1,000 writes that takes
about 3.5 s at 1,000,000 notes. Those two medians agree with the code above: between merges the suffix array keeps
the n-gram work bounded, but steps 2, 3 and the scratch still grow with the store; the median hides them only while
the store is small enough for the sync to dominate.

**Is the merge blocking? Yes, for writers; no, for lookups (READ).** The merge runs inside `perform`, under the
writer lock, before the journal append (`notes_ops.zig:79`, `:110`). So the write that crosses the 1,024-note mark
waits the whole merge before it is stored or answered; every write, listing and promotion refresh queued behind it
waits too; and a chat request whose own statement is that write waits before its reply starts, because a chat
request's statement is written before the reply (NOTES-IN-ENGINE.md:211, `notes_route.zig:107`). Lookups do not
wait: they read the current version, and the new one appears only at the swap.

An erase is worse: it re-reads and re-parses the snapshot, replays every journal record, builds a new index and base
from nothing and rewrites the whole journal (`notes_ops.zig:156-203`), all under the writer lock: 35 ms, 91 ms and
589 ms at 769, 10,000 and 100,000 notes (MEASURED, NOTES-IN-ENGINE.md:267). Then it waits, without a deadline, until
no lookup holds an old version (`notes_ops.zig:225`, `notes_store.zig:332-346`).

### Proposed design

The rule: **the journal stays the only durable record, and its format and sync order stay as they are** (except one
new record type for Gate 2). Everything changed below is derived state, rebuilt from the snapshot and the journal at
any start, so a crash at any point cannot lose or invent a write.

#### 1. A writer model whose lookups do not scan

Replace the linear scans in the model with maps kept in step with every append and revert:

- entity name -> entity, attribute name -> attribute, (entity, attribute) -> pair, source -> place
  (`notes/model.zig:138-156`);
- per entity (and per pair), the normal forms of its current facts -> note ids, for `duplicates`
  (`notes/write.zig:66-78`). A change or take-back removes the retired note's form; `write.revert` puts it back.
- the erased-target fallback (`notes/write.zig:100`) walks the pair's own id list (`model.pairs.items[p].ids`)
  instead of every note.

Cost per write: a few hash lookups and one normal form. These maps live only in the writer's model, under the writer
lock; no reader sees them, so no concurrency change.

#### 2. Scratch with headroom

`Scratch.init` sizes its arrays to the version's note count. Allocate them for `notes + side_max` (or grow by half
again when outgrown), and let `take` keep a scratch whose arrays are long enough for the version it reads
(`notes_store.zig:250`). The erase epoch check stays. Cost: one scratch per lookup thread a little larger; the
per-lookup reallocation after each add disappears.

#### 3. A version is a shared base plus a bounded delta

Today's `Index` becomes two parts:

- **Base** (immutable, reference counted, shared by every version built on it): every column, group, name table and
  the suffix-array base for places `0..B-1`, exactly as `buildWith` makes them now. The suffix-array `Base` is already
  shared this way (`notes/sa.zig:93-116`); the metadata joins it.
- **Delta** (owned by one version, copied forward when the next version is made, bounded by a configured size):
  - the **tail**: notes at places `B..`, written since the base: their columns, their keys and their side postings
    (as the side buffer is now);
  - **overrides** of base places: a base note's new state, line and cost when a later write retires it. The
    overlay type for this is already on the branch, tested, and not yet wired (`notes/overlay.zig:6-56`, a bounded
    `changed` map plus `tail`, with `fork` copying it forward);
  - **group additions**: per touched entity, its new current places; per touched pair, its new places (pairs only
    grow, oldest first, so new places append in order); per touched entity, its new pairs;
  - **table additions**: new entity phrases and one-key names, new aliases, new entity and attribute names.

Readers already go through accessors for the per-note columns (`stateAt`, `lineAt`, `costAt`, `idAt`, `rankAt`,
`toldAt`, `entityAt`, `pairAt`, `valueEntityAt`, `notes/index.zig:186-222`), added on this branch as the seam for
exactly this change. Each accessor becomes "tail if the place is past the base, else override if there is one, else
base". The groups and tables get the same treatment:

- `ent_cur.of(e)` becomes the base group filtered by `stateAt(p) == current`, then the delta's current places of
  `e`. Filtering at read time matters: the "me" entity can hold most of a store's current notes, so copying its group
  on every write would grow with the store. (A base note retired since the base already has to be skipped this way
  by the suffix-array path, `notes/lookup.zig:231`.)
- `pair_notes.of(p)` and `ent_keys.of(e)`: base group, then the delta's appended entries.
- `phrases`, `names`, `aliases`, `alias_entities`: the delta's small map first, then the base's.
- `placeOfId`: new ids are contiguous (`notes/model.zig:134-136`: the next id is the last plus one), so a tail id's
  place is arithmetic; a base id uses the base array.
- `n_cur`, `n_hist`: counts carried in the delta.

The four whole-store computations that do not fit an overlay are replaced:

- **The tie rank.** `trank` exists only to break score ties by (newest told first, then lower id), packed into the
  sort key (`notes/lookup.zig:119-122`). Replace it with a key computed from the note itself: a tick is
  `day x 1,000,000 + offset` (`notes/line.zig:7`), so a tick fits in 40 bits until the year 3000, and an id under
  16.7 million fits in 24; `((maximum tick - told) << 24) | id` orders exactly as the sort did and needs no global
  pass (INFERRED; the build checks both bounds and keeps the old sort when a store exceeds them). This is step 3 of
  the write-path plan (NOTES-WRITE-SCALING.md).
- **The cheapest line** (`min_line`). It is only an early exit in packing (`notes/lookup.zig:414`): the walk stops
  when the room left is below the cheapest possible line. Every line's cost is at least the true minimum, so a lower
  bound that is too low changes no result, it only stops later (INFERRED; the differential test below checks it).
  The delta keeps `min(base minimum, tail and override costs)`.
- **Value entities of written notes** (`notes/value.zig:8-17`). Compute a written note's value entity once, when it
  is written, and keep it in the delta. A new entity phrase can give an earlier written note a value entity, or a
  longer one; so a write that adds a phrase looks up the notes holding that phrase's keys (one index lookup) and
  recomputes only those. Work: proportional to the notes that contain the new name, not to the store.
- **Aliases** (`notes/alias.zig:42-79`). Recompute only the alias keys a write touches: a new current name note adds
  one, a retired one removes one. To keep the "ambiguous" marker exact, the delta keeps, per touched alias key, the
  list of (entity, note) contributors.

A write then costs: intake (step 1), O(note length) for its own columns and keys, O(touched groups) for overrides,
copying the delta forward (bounded by its configured size), the journal sync, and the swap. None of it grows with
the store.

#### 4. Merges in the background, as a linear merge

When the delta reaches its soft limit (for example 1,024 tail notes or 1,024 overrides, whichever first), the writer
wakes a merge thread with the current version **V** (retained). The merge thread:

1. builds a new base from V, through V's accessors only: it never reads the writer's model, which keeps changing;
2. merges the suffix arrays linearly instead of re-sorting. A suffix never crosses a note's separator
   (`notes/sa.zig:177-191`: comparison stops at the separator), so the suffixes of two disjoint sets of notes are
   ordered without reading across them: the new array is a merge of the old base's sorted array and the tail's
   sorted suffixes, ties broken by place, the base's first (INFERRED). The tail's suffixes are few (at most the
   delta's tokens) and are sorted alone. Notes retired since the old base move from the current view's array to the
   history view's during the same pass. Cost: proportional to the store's tokens, read once, instead of a radix sort
   plus tie sorts; still proportional to the store, but off the write path;
3. hands the finished base to the writer.

The writer, under its lock, publishes a version made of the new base plus a delta **re-based**: the notes and
overrides written since V. Places do not move between V and now (only an erase moves them, and an erase cancels a
running merge, below), so the re-base is a copy of the newer delta entries: bounded. Then the swap, as today.

While the merge runs, writes go on against the old base and a growing delta. A **hard limit** (for example four
times the soft one) stops the delta growing without bound when writes outpace merges: past it a write waits for the
merge to publish. That wait is the only place a write can wait for merge work, and it occurs only when writes arrive
faster than about one per (merge time / soft limit): at a 3.5 s merge and 1,024 notes, faster than about one write
every 3.4 ms, sustained (INFERRED from the REPORTED merge time).

**What readers see during a merge.** Exactly what they see now: a version is immutable and holds its base by
reference count, so a reader that took version V before the publish keeps reading V's base and delta until it
releases them; a reader after the publish reads the new base. The old base is freed (through the zeroing allocator)
when its last version goes. Memory: two bases coexist for the length of the merge plus the longest lookup, about
twice the base's bytes at the peak (the suffix-array base was about 444 requested bytes per note at 100,000 notes,
MEASURED on `notes-sa-index` at `687cdceb`, NOTES-IN-ENGINE.md:306).

**Crash safety.** A merge writes nothing to disk. A crash before, during or after a merge loses nothing: the start
replays the snapshot and the journal as now (`notes_store.zig:158-170`). The journal's sync-before-swap order
(`notes_ops.zig:120-133`) is unchanged, so a write that was answered is in the journal, and a write that was not
answered either is not, or is cut at the next start (NOTES-IN-ENGINE.md:224).

**Startup.** Replay applies each journal record through the intake, which today scans the store (step 2 above), so
a start costs about records x notes. With the maps of part 1 a start is linear in records plus one base build.
A later step, the **checkpoint** (part 6), bounds it further.

#### 5. Erase inside this design

An erase changes places and ids: LLWZ's semantics are "never taught", so every note after the erased one is
renumbered, and a note's line contains its own id and the id of the note that replaced it
(`notes/line.zig:89-101`), which also changes its token cost. That is a whole-tail rewrite by definition and does
not fit an overlay. Gate 2 below therefore splits an erase into a bounded **acceptance** (a mask in the delta and a
journal record) and a **purge** that rebuilds as today but off the write path, with a deadline. A merge running when
an erase is accepted is cancelled and restarted after the purge.

#### 6. Checkpoints (later)

Periodically, and at every completed purge, write the store as a new snapshot file beside the old (a fresh temporary
file, synced, renamed, the folder synced: the journal's own rule, `notes/journal.zig:200-235`), start a new journal
whose header names it, and remove the old journal. Startup then reads one snapshot and a short journal. This needs a
snapshot writer in Zig that produces `lw-notes-snapshot/1` byte-compatible with LLWZ's export; that writer does not
exist yet (READ: `notes/model.zig:193` parses, nothing writes). It is also what makes snapshot notes erasable
(Gate 2).

### Alternatives considered and rejected

- **An unindexed tail searched linearly** (the request's example). Lookups would scan every tail note's tokens for
  every question n-gram: cheap at 1,024 notes, but it changes the lookup path's code for no gain, because the side
  postings already exist, are exact and cost O(tail) to build. Kept the side postings; the tail is the side buffer.
- **Mutating the index in place under a short write lock** (NOTES-IN-ENGINE.md:294 mentions it). Lookups would then
  take a lock or see torn state, and an erase or a failed write would have to undo in place. Copy-on-write with a
  small delta keeps "a version never changes" and every existing concurrency test.
- **A delta that grows with the base** (merge every N/64 writes). It amortizes merge cost, but the delta's copy per
  write then grows with the store. The fixed soft limit plus a background merge keeps the write bounded and moves
  the store-sized work off the write path.
- **Tiered (log-structured) merging** with several suffix-array levels. Fewer bytes merged per write over time, but
  every lookup searches several arrays, and the base-plus-delta step is needed first anyway. Held for later, only if
  the background merge's duty cycle measures high at the expected write rates.
- **Keeping the synchronous merge and only making it faster** (the linear merge alone). Still a pause that grows with
  the store, and still inside a chat request's reply path. Rejected as the end state; the linear merge is kept as
  part of the background design.
- **Group commit** (one drive sync for several queued writes). It cuts the sync's share, but the sync is already
  bounded and is the floor today; it is independent of this gate and can follow.

### Test plan (Gate 1)

Every test runs alone first (`-Dtest-server-filter=...`), then in the whole suite. Each has a negative control: a
switch that puts back the old behaviour or plants the bug the test exists for, which must make it fail.

1. **Differential equivalence at every step.** Random sequences of add, change, take-back, same-as, erase and
   restart (byte tokenizer, the L6 fixture and random stores), with merges forced at random points. After every
   step, every fixture question's block, ids, tokens and past flag on the new version equal those of a full
   `buildKind` of the same model (today's code path, kept as the oracle). Also at held old versions: a version taken
   before step k answers as the oracle at step k-1. Negative controls: (a) a test-only switch that skips the
   delta's group addition on a supersede; (b) one that uses a stale alias table; each must fail the comparison.
   `notes-golden` over the 1,568 questions must still give 1,568 of 1,568.
2. **Bounded write cost.** `notes-sa-bench` (exists) at 1,000, 10,000, 100,000 and 1,000,000 notes, the journal on
   a RAM-backed or fault-injected sync so that only the write's own work is timed, then again with the real sync.
   Pass: the median and 99th-percentile write time without sync at 1,000,000 notes is within 2 times that at 1,000
   notes. Negative control: the same bench on `2c9e7599` must fail it (121 ms at 100,000 notes against 3.9 ms is
   already 30 times, MEASURED above). Report the sync separately.
3. **No write waits for a merge** (below the hard limit). Writes at a steady rate while a merge of the 1,000,000-note
   store runs: no write's time includes the merge. Negative control: the synchronous merge switch shows the spike
   (REPORTED about 3.5 s).
4. **Readers during merges.** The 8-thread test (`notes_concurrency_test.zig`) with merges and erases forced during
   it: every block equals its own version's oracle, none torn, none from a version the writer did not publish.
   Negative control: a switch that publishes the new base before the delta is re-based must produce torn blocks.
5. **Crash safety.** A child process killed (`SIGKILL`) at each publication point: mid-merge, between journal append
   and swap, mid-purge. The restarted store equals the oracle replay of the journal. Negative control: the journal's
   sync skipped (existing fault switch, `notes/journal.zig:22-36`) loses an answered write, which the test must catch.
6. **Allocation failure.** `std.testing.checkAllAllocationFailures` over a write, a merge publish and a re-base: any
   failure leaves the old version current and all memory freed (the pattern of `notes_alloc_test.zig`).

### Cost estimate (Gate 1, INFERRED)

| Part | Work | Write-path effect |
| --- | --- | --- |
| 1. model maps | 1 to 2 days | removes scans over entities, attributes, pairs and notes |
| 2. scratch headroom | half a day | removes the store-sized allocation per lookup after each add |
| 3. base plus delta | 5 to 8 days, most of it the differential tests | removes the whole-index rebuild |
| 4. background linear merge | 3 to 5 days | removes the merge pause from writes |
| 6. checkpoints | 4 to 6 days (the byte-compatible snapshot writer) | bounds startup and enables snapshot-note erase |

Expected write cost after parts 1 to 4: the drive sync (3.9 ms median today, MEASURED) plus well under a millisecond
of work, at any store size (INFERRED, to be MEASURED by test 2). Extra memory: one delta per live version (a few
hundred kilobytes at the soft limit) and a second base during a merge.

### Files Gate 1 would touch

`server/notes/model.zig`, `server/notes/write.zig`, `server/notes/index.zig`, `server/notes/lookup.zig`,
`server/notes/sa.zig`, `server/notes/value.zig`, `server/notes/alias.zig`, `server/notes/overlay.zig`,
`server/notes_store.zig`, `server/notes_ops.zig`, `server/notes_decode.zig` (it reads `ent_cur` and the tables
directly, `notes_decode.zig:157-186`), `server/notes_records.zig`; tests `notes_concurrency_test.zig`,
`notes_sa_test.zig`, `notes_alloc_test.zig`, a new `notes_delta_test.zig`; the `notes-sa-bench` tool.
Overlap with codexmb's open work in `notes-integrated` (uncommitted there at the time of writing:
`notes_store.zig`, `notes_route.zig`, `notes_decode_fields.zig`, `notes_decode_test.zig`, `notes_sa_test.zig`):
`notes_store.zig` and `notes_sa_test.zig` directly, `notes_decode.zig` by its readers. Part 1 touches none of them.

---

## Gate 2: an erase that reaches everything

### Where an erased note's text or tokens can be, today

| # | Place | What it holds | Today's erase (READ) |
| --- | --- | --- | --- |
| 1 | The store's versions, model, log, scratch | text, token ids, lines | Rebuilt without it; old versions freed and zeroed once no lookup holds them (waits with no deadline); scratch from before the erase freed; all through the zeroing allocator (`notes_ops.zig:145-231`, `notes_store.zig:332-371`) |
| 2 | Tokenizer encode memo | ids of every segment of 1 KiB or more, a block among them | Cleared and zeroed (`notes_ops.zig:228`, commit `9b16b027`) |
| 3 | The journal on disk | the write's record with its text | Rewritten without it, renamed in, folder synced (`notes/journal.zig:200-235`); old blocks on the drive not overwritten (NOTES-IN-ENGINE.md:230) |
| 4 | The snapshot file | snapshot notes' text and ids | Not erasable: 409 (`notes_ops.zig:152`) |
| 5 | Engine prompt cache, in memory | KV state and the full prompt tokens of kept prefixes (`core/prompt_cache.zig:100-111`: `tokens`, `last`) | Not reached: the engine API has no call for it (`core/engine_api.zig:329-343`) |
| 6 | `--learn` prompt states on disk | KV state files and an index of their tokens (`core/prompt_imprint.zig:157`) | Not reached; and even the existing whole-cache clear on a weight change only stops reading them, it leaves the files (`core/prompt_cache.zig:301-306`) |
| 7 | Requests decoding now | the block in their prompt, and the reply they are writing | Not reached: they finish |
| 8 | Responses store (`/v1/responses`, `store: true`) | the conversation's messages and output, in memory, up to 1,024 entries or 256 MiB (`responses.zig:40-92`) | Not reached |
| 9 | Cortheon's hidden rounds | messages a client never saw, kept to splice back (`cortheon/memory.zig:10-45`) | Not reached |
| 10 | Compaction memory files (`--compact-memory`) | the memory note of a compacted conversation, `.md` and `.json` per conversation, on disk (`compact_mem.zig:42-66`) | Not reached |
| 11 | Request log (`TENSORFOLD_REQUEST_LOG`) | every chat body, the user's statement among them (`openai.zig:130`, `request_log.zig:1`) | Not reached (the operator's file) |
| 12 | Promotion (branch `notes-promotion`) | the fact's neurons; its text, questions and answers in the state; probe log; fact graph | Neurons zeroed and kept zeroed; the rest kept (below) |
| 13 | Freed heap, drive blocks, backups | anything ever written | Out of reach (NOTES-IN-ENGINE.md:230) |

Three facts in this table are new findings:

- **The notes block is inside the prompt cache's "shared" prefixes, so `--learn` writes it to disk.** The block is
  inserted as the first system message (`notes_route.zig:192-215`, called at `openai.zig:136`). A chat request's
  shared cuts are positions inside the leading system messages (`chat.zig:124-127`, measured by
  `prompt.zig:129-146`), and the prompt cache writes a state kept at a shared cut to disk when `--learn` is on
  (`core/prompt_cache.zig:433`, `:482` -> `core/prompt_learn.zig:10-40`). A block of 512 tokens or more therefore
  ends up as a learned state file on disk, keyed by a hash of its tokens (`core/prompt_imprint.zig:54`), read back by
  later servers.
- **Compaction memory is keyed by the notes block.** Compaction runs after the block is inserted (`openai.zig:501`
  after `:136`), and the memory file's key is a hash of the first system message and the first user message
  (`compact_mem.zig:10-19`). With `"notes": true` the first system message is (or begins with) the block, so the
  memory note's file name changes whenever the block does: the note can quote a fact and be filed under a key that
  no later request computes (it is then orphaned rather than reused). That is a separate correctness problem for
  compaction with notes; for erase it means the server cannot find these files by recomputing a key.
- **`"complete": true` over-claims.** It is `!srv.info.prompt_cache` (`notes_http.zig:195-203`): with the prompt cache
  off, the reply says complete even when rows 6 to 12 hold copies.

### How promotion's erase works today (READ, branch `notes-promotion` at `ad6ed646`)

- The erase route calls the promoter after the store's erase (`server/notes_http.zig:79-80` on that branch).
- **The store is the record**: the promoter lists the store's notes and takes as targets every fact in the pocket
  whose key (the write's source, `w12`, or `s<id>` for a snapshot note) the store no longer holds
  (`notes_promote.zig:305-316`). It does not trust the erase's own list, so a missed erase is found later.
- It zeroes the targets' neurons through the learner's `retire` and **saves the pocket into the model's files before
  answering** (`server/slide.zig:143-150` on that branch: `retire`, then `saveAll`).
- Only after the zeroing succeeded does it mark the facts `freed`, then writes the state file (fresh temporary file,
  synced, renamed, folder synced), then refreshes the in-weights exclusion list. A refusal or a failed state write is
  reported `pending: true` and the state is put back as the file has it (`notes_promote.zig:325-364`). While a night
  or a lesson runs, the erase is `pending` (`notes_promote.zig:279-286`).
- **After a restart**: the promoter thread's first act is `drainPending` (`notes_promote.zig:238-242`), which runs the
  same "store is the record" check. Since the journal was rewritten without the note, the restarted store lacks it,
  so any fact still active in the state is zeroed again (zeroing twice is a no-op). The zeroed weights are in the
  model's files already. That is why the fact stays out after a restart (MEASURED in PROMOTION-IN-SERVER.md: 0 of 3
  after the erase and 0 of 3 after a restart, Metal and CUDA).
- A side effect: a learner step that changes weights clears the engine's whole prompt cache
  (`core/lane_host_learn.zig:37`), so an erase of a **promoted** note does empty the in-memory prompt cache. It does
  not delete `--learn` files (row 6).

What it leaves (READ): the freed fact keeps `text`, its own question and reference answer (`ask`), its neighbour
questions and its two-note question (`pair`, which holds the other fact's text too) in `SNAPSHOT.promote`
(`notes/promote_json.zig:51`, `:73`, `:82`; `zeroErased` clears only status, neurons, probes and streak,
`notes_promote.zig:336-342`); **another** fact's `pair.text` can quote the erased fact; every probe's question and
two replies are appended to `SNAPSHOT.promote-probes.jsonl` and never removed (`notes/promote_json.zig:234-244`);
the Sliding Weights fact graph keeps the fact's text, state `learned` and its neuron list (`slide_graph.zig:84`,
`:96-98`: neurons are cleared only for `missed` or `replaced`), shown at `/slide` and written to `--slide-graph`.
And zeroing a fact's neurons does not undo a later lesson's refit of earlier neurons (PROMOTION-IN-SERVER.md, open
question 1).

### The earlier cache incident this design must not repeat

LLWZ's erasure check (docs/NOTES-LAYER.md:65 in the LLWZ repository) walks every attribute, key, value and container
reachable from the store after a delete, looking for the deleted sentences, a word only they hold and their token
ids. On LLWZ commit `d831eb7` that walk **found the deleted lesson in 10 places after the delete**: the memos that
lookups fill (`_costs`, `_canon`, `_canon_ids`, `_wordy`) and the stand-in tokenizer's piece table, caches that the
delete did not know about. It was found in codexmb's review of PR #1. The lesson, kept in that document: the check
must be generic, so that a cache added later is walked too, and it needs a control that plants a store-wide memo and
must find it. TensorFold repeated it once: the tokenizer's encode memo kept an erased note's block until commit
`9b16b027`. And the erase tests' own negative-control branch once answered success on a failed folder sync, found by
running the fault tests with each index kind (commit `b6c9adf6`). Every test below therefore has a planted copy that
the test must find before it is trusted to find nothing.

### Proposed design

#### The two phases

**Phase A, accepted** (bounded; the reply waits for it):

1. Under the writer lock, find the writes the erase takes out: the note's own, the writes kept out as the same as it,
   its take-backs (`notes_records.zig:105-115`; today a scan of the log, made an index by target).
2. **Append one journal record** `{"op": "erase", "source": "w12"}` with its commit line, synced as every write is
   (`notes/journal.zig:138-160`). Replay treats it as "skip every record this erase takes out", which is exactly what
   the rewrite produces. This is the durable point: from here a restart cannot bring the note back, even though the
   older record with its text is still in the file until phase B. Journal format `tf-notes-journal/3`; a version-2
   server refuses a version-3 journal by its header, as it refuses unknown formats today.
3. Publish a version whose delta **masks** every note of those writes (their places hidden from lookups, listings
   and decode checks). This is an interim state, not the never-taught one: a write that was kept out as the same as
   the erased note becomes a note of its own after the purge, not before. The reply says so (`"state": "accepted"`).
4. **Barrier for serving**, before the reply:
   - every in-flight request whose block held one of the masked notes is cancelled at its next round
     (`Engine.cancel`, `core/engine_api.zig:352`); its reply ends with an error that names the erase. The server
     already records each request's block ids (`notes_route.zig:155-163` logs them);
   - the engine is told to forget prompt states tagged with those notes (below) and acknowledges before the reply;
   - the in-memory saved-conversation stores drop their tagged entries (below);
   - the promoter is told (as today).
5. Reply `200` with `state: accepted`, the moves the purge will make, and per path its status.

Cost: one journal append and sync (3.9 ms median today, MEASURED), a mask in the delta, and the engine's forget pass
over its kept states (a scan of their token lists: at the 16 GiB default budget and about 60 MiB a Nemotron state,
about 270 entries, CHANGELOG.md:115 for the state size; a few million token comparisons, milliseconds, INFERRED).

**Phase B, complete** (in the background, within a deadline T):

1. The purge: today's erase body (`notes_ops.zig:156-218`: snapshot re-read, journal replay without the writes, new
   index), on the merge thread instead of under the writer lock, then the writer re-bases the writes accepted since
   phase A onto it (re-applying their records: replay is the definition of the live state, so live equals what a
   restart would build). Then the swap.
2. The journal rewrite without the records and without the erase record (the existing atomic rewrite).
3. Old versions freed (zeroed) once released. Readers are lookups and decode checks, which hold a version for one
   lookup (`notes_store.zig:281`, `notes_decode.zig:158`, `:191`): microseconds to milliseconds. The deadline makes
   that an enforced bound: a version still held at T is reported, not waited on forever.
4. Disk paths: `--learn` files deleted and their index rewritten; compaction memory files deleted; promotion state
   and logs rewritten without the fact (below). Each synced.
5. The erase's status becomes `complete`, or `failed` with the path that failed. Status is kept in memory and in a
   small state file beside the journal, so a restart during phase B resumes it (the journal's erase record is the
   trigger: a start that finds one rewrites the journal before serving).

**T**: a setting, default 30 s, and the measured purge time at the store's size must be well under it before any
deadline is advertised (the contract in NOTES-WRITE-SCALING.md). The purge measured 589 ms at 100,000 notes with the
postings index (MEASURED, NOTES-IN-ENGINE.md:267); at 1,000,000 it must be measured.

Writes during phase B continue against the masked version (Gate 1's bounded path). A write's verdict given during
phase B can differ from the verdict replay later gives it (for example, a statement that matched only the erased note
was answered `ALREADY_KNOWN` before the erase and becomes `NEW` at replay). That is the same rule a restart already
applies; the reply of a write made during a pending erase says `"provisional": true`.

#### Tagging what each request put in, so it can be found again

Note ids move at an erase, so tags use the stable key promotion already uses: the write's source (`w12`) or `s<id>`
for a snapshot note (`notes_promote.zig:58`). A chat request with `"notes": true` knows its block's notes and where
the block's tokens start in its prompt.

- `api.Request` (`core/engine_api.zig:50-91`) gains `notes_tags: []const u64` (hashed keys) and `notes_from: u32`
  (the first token of the block) and `notes_epoch: u64`.
- `prompt_cache.Entry` (`core/prompt_cache.zig:100-111`) gains the tags of the request that kept it, recorded only
  when the kept position `at` is past `notes_from` (a state kept before the block, such as a client's own system
  prompt, holds none of it and stays). A resumed-and-extended state takes the union of its tags.
- New engine call `forget_notes(tags, epoch)` in `Engine.VTable` (`core/engine_api.zig:329-343`), queued to the
  engine thread the way lessons are (`core/lane_host_learn.zig:7-15`), run between rounds before any newer request is
  admitted, acknowledged to the caller. It removes (a) every entry with a matching tag, (b) as a backstop, every
  entry whose `tokens` or `last` contain the note's own token ids (its `n.tokens()`, minus the first and last token,
  which may merge with the quote marks around it in a line; at least 4 tokens), which catches a client that pasted a
  block back in (`notes_echo` returns it to clients), and (c) refuses, from then on, a keep by any request whose
  `notes_epoch` is older and whose tags intersect: this stops a background pass that was already prefilling a tainted
  conversation (`core/lane_host.zig:80`, `:427`) from keeping it again after the forget.
- For `--learn`: each removed entry's learned key (`Imprint.keyOf(tokens)`, `core/prompt_imprint.zig:54`) is removed
  with the family's `forget` (`core/prompt_cache.zig:57`) and `Imprint.remove` (`core/prompt_imprint.zig:188`, which
  rewrites the index without it), and the directory synced. The existing whole-cache `clear` (`:301-306`) is changed
  to delete the files it stops reading, not only to forget the pointer.
- Two-Mac GLM: rank 1 holds copies by id; the forget goes through `peer_other_remove` (`core/prompt_cache.zig:54`).
- Every backend holds a `prompt_cache.Store` (READ: `native/metal.zig:71`, `native/cuda.zig:150`,
  `native/glm_host.zig:23`, `native/flashnext_host.zig:47`, `native/qwen27_served.zig:37`); the paged radix store
  (`core/prompt_radix.zig`) is not wired into a served engine at `2c9e7599`, and gets the same call if it is.

The saved-conversation stores get the same tags:

- `responses.Store` entries, Cortheon's `memory.Store` entries and compaction memory files record the tags of the
  request that made them (compaction: a `.tags` line in the existing `.json` sidecar, `compact_mem.zig:48`). An
  erase drops tagged entries, deletes tagged files and, as the backstop, scans the in-memory entries and the
  compaction directory's `.md` files (each under 1 MiB, `compact_mem.zig:56`) for the note's normal form. Their
  memory moves to the zeroing allocator (`notes/zero_alloc.zig`), so a dropped entry's bytes are zeroed when freed.
- `/v1/responses` neither looks up nor writes notes (NOTES-IN-ENGINE.md:297), so its entries carry no tags; the
  backstop scan is what reaches a fact a user typed there.
- The request log is the operator's file. The erase reports it under `remaining` when it is set; rewriting it is
  out of scope.

#### Promotion

Keep the "store is the record" rule and the zeroing order; add:

- a freed fact keeps only its key, status and why: `text`, `ask`, `neighbours`, `pair` emptied, and every other
  fact's `pair` that quotes it dropped (rewritten on the next night), before the state is written;
- the probe log rewritten without the lines that name the fact (or one log per night, deleted whole);
- the Sliding Weights graph entry of the fact marked `replaced` (which clears its neurons, `slide_graph.zig:96-98`)
  and its text emptied, and the graph file written;
- the in-memory prompt cache is cleared by the weight change already; `--learn` files go with the fix above.

What stays out of reach, and is said: a later lesson's refit of other neurons (open question 1 of
PROMOTION-IN-SERVER.md); exact rollback needs a pocket checkpoint in the learner.

#### Snapshot notes

Today erasing a snapshot note is refused (`notes_ops.zig:152`): the server cannot re-run LLWZ's intake for the
snapshot's own lessons. With checkpoints (Gate 1 part 6), offer **removal** for snapshot notes, a different and
weaker semantics than "never taught": the note is removed, notes it replaced keep their retired state with the
label's id pointing at nothing erased, and the next checkpoint is written without it. The original snapshot file is
the operator's export; the server writes its checkpoint beside it and reports the original under `remaining` unless
it was started with a flag that lets it replace that file. This needs a decision from petrus and Ash before it is
built.

### What must be true before "deleted" is claimed end to end

The reply may say `"state": "complete"` only when all of these hold, and must list each one that does not:

1. The journal file at its name holds no record with the note's text, and its folder is synced; the erase record that
   made phase A durable is gone with it.
2. No version, model, log, scratch or memo in the process holds the note's text or token ids (all freed through the
   zeroing allocator), checked by the tracking-allocator walk in tests.
3. The engine holds no prompt state tagged with the note or containing its token sequence, on every rank, and no
   newer keep of one was accepted after the forget.
4. No `--learn` file or index entry holds such a state, and the directory is synced.
5. No request that had the note in its block is still decoding.
6. No Responses entry, Cortheon entry or compaction memory file holds the note's text (tag or scan), and deleted files'
   directories are synced.
7. With promotion: the fact's neurons are zeroed and saved in the model's files, and no promotion state, probe log or
   fact graph entry holds its text.
8. Snapshot notes: the checkpoint without it is written and the original snapshot is replaced, or the original is
   named under `remaining`.
9. Named under `remaining`, always, when they apply: the request log, freed heap that did not go through the zeroing
   allocator (request arenas, HTTP buffers), the drive's freed blocks (APFS writes new blocks and leaves the old ones,
   NOTES-IN-ENGINE.md:230: an encrypted volume such as FileVault is the protection there, not the server), copies the
   client received (`notes_echo`, replies), backups and exports.

### Alternatives considered and rejected

- **Clear the whole prompt cache on every erase.** Exact and simple, and already the rule for weight changes. Rejected
  as the default because it drops every unrelated conversation's warm state (a resumed turn goes from about 0.2 s to
  re-reading the history, CHANGELOG.md:115), but kept as the fallback when tagging is off or a backend lacks the
  forget call, and as a request flag.
- **Content scan only, no tags.** A block's tokens are not the note's tokens: in a block the text is quoted and
  tokenized in its line, so a boundary token can differ; a scan can miss. Kept as a backstop, never as the only path.
- **Keep the note's ids stable at erase (no renumbering).** It would make erase an overlay change, but it breaks the
  "same as never taught" equivalence with LLWZ that the notes are measured against. Not a decision this design takes.
- **Rewrite the journal synchronously in the reply (today).** Bounded only by the store's size; replaced by the erase
  record, which is durable in one sync, with the rewrite inside T.
- **Overwrite the old journal's bytes in place before the rename.** On a copy-on-write filesystem an overwrite writes
  new blocks too; it would promise what the drive does not do.
- **Promotion: delete the fact through the learner's per-fact delete instead of zeroing.** PROMOTION.md (LLWZ) and
  PROMOTION-IN-SERVER.md chose zeroing plus rebuild for good reasons (zeroing can leave the fact or hit a neighbour;
  the rebuild is the clean state); this design keeps that.

### Test plan (Gate 2)

Each test is written to fail first on `2c9e7599` (or `ad6ed646` for promotion), which is its negative control: the
gap exists today, so a test that passes on today's code tests nothing. Each also plants a copy it must find.

1. **Store and memory.** The existing walk (`notes_erase_test.zig`: a tracking allocator sees every live allocation;
   a distinctive word "Quixotic Zanzibar" and the note's token ids are searched) extended: after phase A, no lookup,
   listing or decode check returns the note, while the walk may still find it; after phase B, the walk finds nothing.
   Control: the existing `defer_erase_merge` switch (`notes_store.zig:63`), plus a planted test-only memo that copies
   every block, which the walk must find.
2. **Journal and restart.** After phase A, kill the process before phase B; restart: the note is absent and phase B
   finishes before serving. After phase B, the raw bytes of the journal file contain neither the word nor the text.
   Control: a switch that skips the erase record must bring the note back after the restart.
3. **Prompt cache, unit** (`core/prompt_cache_test.zig`, with the fake family `core/prompt_cache_fake.zig`). Keep
   request A (block with note X past its system prompt), request B (block without X) and A's system prompt alone.
   Forget X: A's states past the block are gone, A's state before the block and all of B's stay; a new request with
   A's prompt resumes at most at the block's start. A client-pasted copy of X's line with no tag is found by the scan.
   A background pass of A started before the forget keeps nothing after it. Controls: on today's store (no forget
   call) A's state is still found, which is the failure this test exists for; with the epoch check off, the
   background pass keeps a tainted state.
4. **`--learn` on disk.** A temporary `--learn-dir`; a request whose block is at least 512 tokens and holds X makes a
   learned state; erase X: its file and index entry are gone and the directory's bytes contain neither X's token
   sequence nor its text; a restarted server reads nothing for that prompt. Control: today's `clear` leaves the file.
5. **Server, end to end** (fake engine with a real `prompt_cache.Store` in the notes rig, `notes_rig_test.zig`).
   Erase replies say `accepted` then `complete` (status query), with every path listed. A streaming request whose
   block holds X is cancelled within one round of the erase. Control: without the barrier the stream finishes.
6. **Saved conversations.** A stored response, a Cortheon entry and a compaction memory file each holding X's text
   (tagged and untagged): after the erase, none in memory (tracking allocator) or on disk. Control: before the erase
   each is found.
7. **Promotion** (`notes_promote_rig_test.zig`). After an erase and a restart, `SNAPSHOT.promote`, the probe log and the
   fact graph file contain no byte of X's text, and another fact's two-note question naming X is gone. Control:
   `ad6ed646` fails this today.
8. **The "complete" claim.** With each of `--compact-memory`, `TENSORFOLD_REQUEST_LOG`, `--learn`, `/v1/responses`
   storage on in turn, `complete` is false until its path is done, and the request log is always under `remaining`.
   Control: today's reply says `complete: true` with the prompt cache off and compaction on.
9. **On real engines** (Metal on this Mac; CUDA on a GB10). Nemotron with the prompt cache on: a conversation with X
   in its block, then the erase, then the same conversation's next turn reports cached tokens no further than the
   block's start and a reply equal to the cache-off server's. Control: today's binary reports cached tokens past the
   block.

### Cost estimate (Gate 2, INFERRED)

| Part | Work |
| --- | --- |
| Honest reply: `complete` from every path, `remaining` listing them | half a day |
| Journal erase record (format 3), phase A mask, phase B purge on the merge thread, status query and state file | 4 to 6 days (needs Gate 1 part 3 for the mask) |
| Request tags, `forget_notes` engine call, scan backstop, epoch refusal, on every backend | 4 to 6 days, plus a Metal and a CUDA run |
| `--learn` file deletion (forget and clear) | 1 to 2 days |
| In-flight cancel barrier | 1 day |
| Responses, Cortheon, compaction memory tags and deletion | 2 to 3 days |
| Promotion residues (state, probe log, fact graph) | 2 days |
| Snapshot-note removal | after checkpoints; 2 days plus the decision |

Runtime cost: phase A adds one journal sync and one pass over the prompt cache's kept states to an erase; nothing is
added to an ordinary write or lookup except recording a request's tags (a few integers).

### Files Gate 2 would touch

Store and journal: `server/notes_ops.zig`, `server/notes_http.zig`, `server/notes_records.zig`,
`server/notes/journal.zig`, `server/notes_store.zig`, `server/notes_route.zig` (records the block's tags and start).
Engine: `core/engine_api.zig`, `core/prompt_cache.zig`, `core/prompt_learn.zig`, `core/prompt_imprint.zig`,
`core/lane_host.zig`, `core/lane_host_learn.zig`, the hosts `native/metal.zig`, `native/cuda.zig`,
`native/glm_host.zig`, `native/glm_dsa_host.zig`, `native/flashnext_host.zig`, `native/qwen27_served.zig`.
Request path: `server/chat.zig`, `server/openai.zig`, `server/responses.zig`, `server/cortheon/memory.zig`,
`server/compact_mem.zig`. Promotion branch: `server/notes_promote.zig`, `server/notes/promote_json.zig`,
`server/slide_graph.zig`. Tests: `notes_erase_test.zig`, `notes_journal_fault_test.zig`, `notes_rig_test.zig`,
`core/prompt_cache_test.zig`, new `notes_erase_paths_test.zig`.
Overlap with codexmb's open work: `notes_store.zig` and `notes_route.zig`. The engine, prompt-cache and saved-store
parts touch none of codexmb's files.

---

## Order of work, after `notes-integrated` lands

| Step | What | Depends on | Conflicts with codexmb's open files |
| --- | --- | --- | --- |
| 1 | Erase reply honest: `complete` false whenever any path in the table is live; `remaining` lists them | nothing | none (`notes_http.zig`) |
| 2 | Gate 1 parts 1 and 2: model maps, scratch headroom | nothing | `notes_store.zig` (part 2, one line) |
| 3 | Request tags, `forget_notes` in every backend, epoch refusal, `--learn` file deletion, the whole-cache clear deleting its files | nothing in the store | `notes_route.zig` (recording the tags) |
| 4 | Gate 1 part 3: base plus delta, with the differential tests | step 2 | `notes_store.zig`, `notes_decode.zig`, `notes_sa_test.zig` |
| 5 | Gate 1 part 4: background linear merge | step 4 | `notes_store.zig` |
| 6 | Gate 2 two-phase erase: journal format 3, mask, purge on the merge thread, in-flight cancel, status | steps 3 to 5 | `notes_store.zig`, `notes_ops.zig` |
| 7 | Saved conversations and promotion residues | step 3; promotion branch merged | none |
| 8 | Checkpoints; snapshot-note removal (after a decision) | step 6 | `notes_store.zig` |

Steps 1 and 3 can start as soon as codexmb's branch is merged and are worth doing first: step 1 stops an
over-claim today, and step 3 closes the prompt-cache and `--learn` holes, which hold the most copies of a note and do
not depend on the store's internals. No production or bounded-erase claim follows from this document; each gate
needs its tests passing and its numbers measured at 1,000 to 1,000,000 notes.
