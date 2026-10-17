# Write-path scaling work plan

Current pin: f419b916. SA reuse alone is insufficient: Index.buildWith
still allocates Raw for every note, copies every per-note column, sorts all
tie ranks, and rebuilds entity/pair groups and name/value tables per write.
The journal sync is not the cause of these whole-store operations.

Required replacement: an immutable metadata base plus a bounded per-version
delta, alongside the already shared SA base and side postings. Lookup must
read note state/line/cost through version-aware accessors, not the mutable
writer Model. A change/take-back overrides only touched places; new notes
append. Reader-held versions must retain old lines and state until release.
Erase must enforce the serving barrier and bounded reclamation contract below.

Sequence:

1. Introduce version-aware accessors and differential tests while retaining
   the current full arrays. This is a semantics-preserving seam.
2. Move immutable note columns and groups into a retained base; represent
   per-write overrides/new entries in the bounded side view. Do not scan or
   clone all note columns just to append one entry.
3. Compare tie order directly by (-told, id), preserving score ordering,
   instead of sorting the entire note table solely to assign trank each time.
4. Preserve exactly the current lookup blocks and IDs through add, change,
   take-back, replay, erase, and old-version concurrent readers. Include
   failed allocation/journal rollback at every publication point.
5. Measure ordinary writes separately from SA merge boundaries and fsync,
   at 1k/10k/100k/1M. A fixed 1024-write synchronous full SA merge still
   grows with total store size: report those spikes and address them before
   claiming bounded production write latency.

No constant-time or production-ready claim follows from the present pin.

## Required erase contract (not yet implemented)

- DELETE must return an error on I/O or allocation failure. A successful
  acceptance acknowledgment follows durable journal fsync, not merely an
  in-memory change. Publication and rollback must preserve this ordering.
- Acceptance immediately bars erased material from notes lookup, cached
  prompts, and saved-conversation serving. It must not wait for a merge.
- Distinguish accepted/pending reclamation from complete reclamation in the
  response and a status query; expose failures rather than silently claiming
  completion. Snapshot-origin notes must be supported, not rejected with 409.
- Reclamation has an enforced deadline T, including retained reader versions:
  readers must finish, expire, or be cancelled within that bound. Force index
  compaction and snapshot rewrite within T; "at the next merge" is not a bound.
- Cover journal, snapshot, index keys/lines and process-owned cached copies;
  restart must not resurrect erased material. Separately qualify external
  backups or exports outside the service's control, rather than promising
  their deletion.
- Test crash/restart, held readers, cached prompts/conversations, snapshot
  notes, and injected allocation/I/O failures. Measure worst-case reclamation
  and serving-barrier behavior at 1k/10k/100k/1M before advertising any T or
  bounded-erase production guarantee.

Multi-user routing is a separate isolation layer: owners must be bound to
authenticated principals, not trusted request-body owner strings. Snapshot,
journal, lookup scratch, decode continuation and deletion must stay isolated.
