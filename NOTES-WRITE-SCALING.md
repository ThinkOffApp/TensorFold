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
Erase must rebuild and synchronously retire all reachable old secret bytes.

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
Multi-user routing is a separate isolation layer: owners must be bound to
authenticated principals, not trusted request-body owner strings. Snapshot,
journal, lookup scratch, decode continuation and deletion must stay isolated.
