# G1 review receipt

## Review corrections

G1 remains subject to re-review. Code HEAD 0374a8b4 passes 354/354 server tests (10 minutes, MaxRSS 5 GiB), all changed Zig fmt checks and lean 630 (unchanged from 815f8105).

- 203052cb: cancellation returns before the suffix-view output assertion. A deterministic first-output cancellation in both views passes; removing the guard aborts at the assertion. Claude independently reports 6 configurations times 400 random cancellations without panic, versus crashes on the previous pin.
- ee21ea19: the alias test checks actual encoded keys in memo names and by_key; route holder flags reset before every Chat/Messages/Responses request.
- bf04b7bc: exact remaining-place sets and requests:empty are asserted, not merely global !complete. Permanently forcing requests:may_hold makes the endpoint test fail. Historical promotion weights remain may_hold even with slide disabled; disabled-writer regression failed before this correction. Disk reasons now describe earlier runs too.
- 0374a8b4: documents that complete:true is currently unreachable and restores error.code=500 on applied-unsynced responses.

The tested baseline remaining-place set is now learn_files, compaction_memory, request_log and promotion, plus any specific active uncertain place. No claim is made that historical weights or files were actually searched or scrubbed.

Base: 815f8105. Separate from notes-unknown-integration. Not deployed or merged.

E1 clears the tokenizer memo after erase span discovery. E2/R4 build an owned replacement alias memo before publication and transfer it only after successful rewrite; failures keep the old memo intact. E3 carries applied-unsynced results through engine forgetting and returns HTTP 500 with journal uncertainty. E4 reports unsearched earlier-run disk files as may_hold. E15 ties scratch lifetime to the acquired version's epoch. E5 counts API prompt holders before planning through remember and async warm completion, latching holders before forgetting. R1 leaves refused erases' merges intact and cancels applied erases' merges cooperatively, discarding cores through the reaper.

Cancellation is not a hard deadline: allocation, zeroing and an individual sort are not interruptible. E5 counts all requests conservatively, not only stale note-bearing requests; no cancellation or epoch rejection is claimed. E4 does not search or delete historical/custom-path files and can keep every erase pending. Engine-specific forget coverage remains G2, not a G1 guarantee.

## Regression controls observed

- E1: encode counter after erase expected 0, found 361 before final memo clearing; passes after.
- E2/R4: rebuilt memo model pointer assertion fails before replacement/priming; scanned count and erased-name absence checked after. These share a regression, rather than proving two independent performance measurements.
- E3: injected folder-sync failure returns 500 but failed the second tokenizer-clear assertion before routing applied-unsynced outcomes through engine forgetting; place report and journal may_hold checked after.
- E4: disabled writers expected may_hold, found off before correction.
- E15: acquire then erase epoch bump then take/give/sweep expected pool length 0, found 1 before version tagging.
- E5: prepared request with no admitted engine job expected requests may_hold, found empty before accounting. Added holder-only and latched-after-completion cases. Chat/Messages/Responses route tests observe foreground and warm holder counts and zero after completion.
- R1: missing-ID erase discarded a ready merge before moving stop; pointer preservation passes after. Cancellation-ignoring worker negative control fails result==null; restored cancellation passes. Pre-cancelled core construction refuses without allocation leakage.

Focused runs passed (counts include four root tests): memo 5/5, unsynced 5/5, disk writers 5/5, scratch 5/5, request holders 5/5, route/warm lifecycle 5/5, refused merge 5/5, cancellation 5/5, running-merge erase 5/5. Existing folder-fault suite 13/13 and erase-reply suite 12/12 passed.

Full server suite at code commit 4f0d26de: 353/353 passed, 3/3 build steps, 10 minutes, MaxRSS 4 GiB (compile 8 seconds, 1 GiB). The prior run also passed 353/353 before the test encode counter became atomic. All 19 changed Zig files pass fmt checks; git diff --check passes. Lean: current/base 630 problems, no changed-file count increase; origin/main b7ce8121 has 503. Claude approved no increase against 815f8105 for repair groups; inherited cleanup remains separate before upstream PR.

## Existing assertions changed (not just added)

- Alias regression: replaces snapshot note 5 (a likes fact) -> 13 (the dog's name fact), and now proves the Zyqora alias key is present before erase; after erase the actual memo key arrays and map must lack it. Checking rebuilt-model text alone was insufficient and has been replaced.
- Promotion on/off tests: expected off -> may_hold when slide is disabled or its graph is empty, because older saved weights are not searched. Exact remaining sets now include promotion.
- notes_erase_test.eraseRun: tokenizer forget count 1 -> 2. The first clear precedes engine span discovery, which re-encodes erased text; the second clears those encodes. Exact count retained, not relaxed.
- notes_http_test endpoint erase: complete true -> false. Earlier-run disk files were not searched, so no-cache engine alone cannot establish completion.
- notes_erase_cache_test successful cache/learn forget: complete true/state complete -> false/pending. The specific prompt_cache and learn_files forgotten assertions remain; compaction/log uncertainty prevents a global completion claim.
- notes_erase_places_test.expectClear: global complete true/state complete -> false/pending; remaining arrays need not be empty. The tested place must retain its exact expected status and matching named/not-named state; compaction_memory and request_log must remain named. This separates local place clearance from unsupported global clearance.
- Disk writer on/off tests: disabled learn_files, compaction_memory and request_log expected off -> may_hold. Their names remain in the report even when today's flags are disabled. Response/Cortheon/cache place-specific status assertions remain.

Review is required before G1 is called done. No G2/G3/G4 fixes are included in this group.
