# The note lookup inside the native server (`--notes`), and writes to it while it runs

LLWZ's note lookup (paper section 4.2) run inside `tensorfold-native`, per chat request, before the prompt is rendered and prefilled, and checked against LLWZ's own Python question by question. Written 15 October 2026 on branch `notes-in-engine` of our fork (ThinkOffApp/TensorFold), from upstream `main` at `c7137bb3`. Not pushed; no pull request.

Grades, as in LLWZ's NOTES-ZIG.md: **MEASURED** means we ran it, on the machine stated above each table. **READ** means we read it in code or a document. **INFERRED** means our own reasoning, not checked by a run. Every number below was measured on this Mac on 15 October 2026.

## In short

- **Live writes, the same as LLWZ Python (MEASURED).** The same 13 writes and 3 erases on each store of the 1,568-question set, applied over HTTP to a real server and in LLWZ's `NoteStore` with the same intake: all 1,568 blocks equal at each of three checkpoints, after a restart, and from Python's own export of the written store (7,840 of 7,840), with every listing and reply equal.
- **Live writes (16 October 2026, branch `notes-live-writes`).** A running server now adds, changes, takes back, erases and lists notes over HTTP (`/v1/notes`, behind the `/v1` key check), and a `"notes": true` chat request's last message, when it is the user's statement, is written through the intake before the reply. Every write is on disk (a journal beside the snapshot, `F_FULLFSYNC`) before it is answered or seen, and replayed at startup. Lookups never wait for a write: each write builds a new index version (copy-on-write). The details, numbers and limits are in [Live writes](#live-writes-v1notes) below; the rest of this "In short" is the read path of 15 October.
- **Built.** `tensorfold-native serve MODEL --notes SNAPSHOT` loads one owner's note snapshot (LLWZ's `zengine/notes_export.py` format). A `/v1/chat/completions` request that sends `"notes": true` has its last user message tokenized with the model's own tokenizer, looked up, counted by `fit()` with the same tokenizer, and the block put in as the first system message before the chat template is applied. Nothing retrieved puts nothing in. The reply's `notes` field and the server's log line carry the note ids, the tokens and the times. Without `--notes` nothing changes (the fields are ignored, as before).
- **Same blocks as LLWZ Python, byte for byte (MEASURED).** 1,568 questions: the 56 questions of `examples/L6-seed1.json` (phase teach), of each day phase of `examples/nights/L6-seed1-nights.json` and of the four sweep stores (100 to 100,000 notes) as `retrieve()` asks them, and again on teach and the five days with the past view forced, with two notes excluded, and both. In all 1,568 the server's block equals Python `retrieve()`'s byte for byte, with the same note ids, the same token count and the same past flag.
- **Same answers, token for token (MEASURED).** At temperature 0 with thinking off, the server's answer with the block it looked up itself equals its answer with the same block sent by the client as a system message, in all 1,568 (the server's token SHA, completion tokens and text), with the same prompt token count.
- **The comparison can fail (MEASURED).** A wrong snapshot (phase del-B for the teach questions) gives 0 of 56 blocks equal and 25 of 56 answers different; the teach store with the hop off gives 9 of 56 blocks equal and 15 answers different; a client block with its last line dropped makes 16 of 56 answers and all 56 prompt counts differ.
- **Time to first token: the lookup is not what costs (MEASURED).** With the block sent by the client or looked up in the server, the prompt is the same 503 to 512 tokens (p50) and the time to first token is the same within noise (paired median difference -0.1 to +0.9 ms). The block itself adds about 480 prefill tokens: 41 to 53 ms without notes against 205 to 279 ms with them (p50). The lookup inside the server takes 52 to 437 µs in all (p50, 100 to 100,000 notes), against 0.42 to 23.6 ms for Python's `retrieve()` on the same stores.
- **Tests (MEASURED).** `zig build test test-golden -Dcpu=apple_m1`: before, 1,981 of 1,989 passed (8 skipped, 0 failed); after, 2,013 of 2,021 (8 skipped, 0 failed); the golden corpus 309 of 319 equal with 0 unexpected differences both times. The lean checker: 527 problems before and after.

## What is built

| Commit | What |
| --- | --- |
| `52e77449` | `zig/src/server/notes/`: LLWZ's lookup vendored (index, lookup, `is_past`), its unit tests and a byte-tokenized fixture |
| `c11e8d26` | `--notes`: the request fields, the insertion, the reply field and log line, the startup checks, and the server tests |
| `17fa3fc5` | `tools/notes/` (export, compare, bench, report), this file and its receipts (`docs/notes-in-engine/`) |
| `f2b0ec49` | a snapshot that names a tokenizer hash starts only when the model's `tokenizer.json` is read and matches; one that names none is reported as vocabulary-only |
| `1f3f5693` | `Scratch.init` frees what it took when an allocation fails (LLWZ `f54344f`) |
| `d1d08b75` | live writes: the model, the index built from it, the intake's deterministic part, the journal, `/v1/notes`; the equivalence, endpoint, erase tests |
| `ba3b9bf9` | a `"notes": true` chat request's own statement written through the intake; `--no-notes-write`, `"notes_write"`; failing-allocator and journal tests |
| `038216a5` | 8 lookup threads during 1,000 writes and erases |
| `9b16b027` | an erase also drops the tokenizer's kept encodes |
| `ed09efd2` | the index's entity groups in one pass (writes at 100,000 notes); `zig build notes-live-bench` |
| `0a13245b` | the concurrency test prints nothing (zig build shows a passing test's stderr as a failed command) |
| `1119b13b` | `tools/notes/live.py`: the writes on a real server against LLWZ Python over the 1,568-question set |
| `dbd9d964` | a lookup reads the settings from the store's own copy, never the model an erase may free |

**The lookup** (`zig/src/server/notes/`) is LLWZ's Zig port (`github.com/ThinkOffApp/llwz`, branch `notes-zig`, `zig/notes/src/notes.zig` at `a81d1a9`, MIT; the branch's head on the day, `dd357a1`, changes only its golden test's deliberate faults in that file). Its arithmetic is unchanged: the same n-grams, IDF weights (the C library's `log`, as CPython's), subject boost, candidate cut, floor, hop, ranking key, `pack()` and `render()`. What differs (READ, from the diff): the snapshot is read with this server's JSON reader instead of `std.json`'s typed parse (the build refuses a server binary that links compiler-rt's `memcpy`, and names `std.json`'s typed int parse as one way to pull it in); the golden test's `Breaks` are gone; the files are split under 600 lines with one-line comments (the lean rule); and `pack()` and `render()` are separate calls, so the server can run Python's `fit()` exactly: render the packed notes, count the whole block with the model's tokenizer, drop the lowest ranked note while it is over the cap. The standalone port has no tokenizer and reports `pack()`'s sum instead. `past.zig` ports `notes.is_past` (the `PAST_CUE` regular expression).

**At startup** the snapshot is refused unless its vocabulary is the model tokenizer's size. A stand-in-tokenizer snapshot is refused. Then:

- **A snapshot that names a `tokenizer.json` SHA-256** (`notes_export.py` writes one for a model tokenizer) starts only when the model folder's `tokenizer.json` is read and hashes to it. A server with no model folder, a missing file, one that cannot be read (a directory, no permission, an I/O error) or one over the 256 MiB read limit refuses to start (exit 2), naming the cause and the error (`NoModelDir`, `FileNotFound`, `IsDir`, `AccessDenied`, `StreamTooLong`), as does a hash that differs (`TokenizerMismatch`). The first version of `c11e8d26` skipped the hash check whenever the file could not be read, leaving only the vocabulary-size check (found by codexmb's review; fixed in `f2b0ec49`).
- **A snapshot that names no hash** is checked by its vocabulary size alone: **vocabulary-only compatibility**. A different tokenizer with the same number of ids would pass, and its ids would match the wrong notes. The startup line says so (`tokenizer checked by vocabulary size only (vocabulary-only compatibility): the snapshot names no tokenizer.json SHA-256`), as does `tensorfold-native serve --help`; with a hash it says `tokenizer checked: the model's tokenizer.json SHA-256 equals the snapshot's`.

With the real model and a binary built from `f2b0ec49` (MEASURED): the teach snapshot, which names the model's hash, starts with the hash line; the same snapshot naming another hash exits 2 with `TokenizerMismatch`; with the hash removed it starts with the vocabulary-only line. Loading took 16 to 27 ms at 10 to 1,000 notes, 37 to 50 ms at 10,000 and 188 to 193 ms at 100,000 (the server's own log line, which includes hashing `tokenizer.json`; MEASURED).

**The request fields** (read only when the server has `--notes`):

| Field | Meaning |
| --- | --- |
| `"notes": true` | look the notes up for this request (`false` or absent: none) |
| `"notes_exclude": [ids]` | note ids never given (`retrieve()`'s `exclude`); asks for the lookup by itself |
| `"notes_past": true/false` | the past view; absent, `notes.is_past(question)` decides, as `retrieve()` does |
| `"notes_cap": n` | the block's token cap; absent, the snapshot's (512) |
| `"notes_echo": true` | the block itself in the reply's `notes` field |

A wrong type is a 400 (`notes must be a boolean`, and so on); `notes_past`, `notes_cap` or `notes_echo` without `"notes": true` is a 400; `"notes": false` with `notes_exclude` is a 400.

**Per request**, inside `openai.plan`: the client's messages are normalized as before; the last user message's text is encoded by the model's tokenizer; the lookup runs on a per-thread scratch taken from a small pool (the index is read-only and shared); `fit()` counts the block; if the block is not empty it is put first in the client's raw messages as `{"role": "system", "content": block}` and the list is normalized again, so a client system message follows it exactly as if the client had sent both. Then the request goes on unchanged (render, prefill, decode).

**The reply** gets a `notes` field (in the last chunk when streamed): `ids`, `past`, `past_from` (`request` or `question`), `cap`, `tokens` (the model tokenizer's count of the block), `pack_tokens`, `dropped` (by `fit()`), `candidates`, `notes_in_store`, `question_tokens`, `tokenize_us`, `lookup_us` (lookup and render), `fit_us`, `total_us` (all of it, the second normalize included) and `block_sha256` (and `block` with `notes_echo`). The server logs one line per request, for example (MEASURED, 100,000 notes):

```
[tensorfold] notes chatcmpl-…: [97565,97699,…,26,28,29] 491 tokens of 512, past no, 1813 candidates; tokenize 12.0 us, lookup 91.2 us, fit 4.5 us, total 115.9 us
```

**Not done (read path):** one owner per server; `/v1/completions`, `/v1/responses` and `/v1/messages` do not take the fields; no request with several lookups at once was measured. Writes were not done on 15 October; they are now (below).

## Equivalence with LLWZ Python (MEASURED)

**Machine:** Apple M5 Max (`machdep.cpu.brand_string`), 18 cores, 128 GiB (`hw.memsize` 137,438,953,472), macOS 27.0.1 (26A434). **TensorFold:** `tensorfold-native` built from `c11e8d26` with Zig 0.17.0 (`zig build native -Dcpu=apple_m1 -Dversion=1.0.0`; the binary measured differs from a rebuild of that commit only in its Mach-O UUID, one debug-map timestamp and the code-signature hashes that follow from them, and two rebuilds are byte-identical). **Model:** TensorFold/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit, revision `d9d758fb83953437f7263256b0d96157e2a348b8` (4-bit, group 64, 17.27 GiB of weights), served read-only. **Server:** `--prompt-cache-gib 0 --context 32768 --no-update-check`, otherwise the defaults (drafts on, keep-warm 900 s). **Requests:** temperature 0, `chat_template_kwargs: {"enable_thinking": false}` (thinking off), `max_tokens` 160 (LLWZ's `--max-tokens-off`), one user message. **Python:** LLWZ `notes-zig` at `a81d1a9` (`zengine/notes.py`, `notes_export.py`), CPython 3.12.8, `tokenizers` 0.23.2 with the model's `tokenizer.json`, `PYTHONHASHSEED=0`.

What is compared, per question: the server is started with the store's snapshot; (engine) the question as the only message with `"notes": true, "notes_echo": true`; (client) Python `retrieve()`'s block for it as a system message before the question (no system message when Python retrieved nothing). The engine's block must equal Python's byte for byte, with the same ids, tokens and past flag; the two answers must have the same token SHA (the server's `token_sha` of the generated ids), completion token count and text; the prompt token counts must be equal.

| Store | Notes (current) | Questions | Retrieve notes | Block equal | Ids equal | Tokens equal | Past equal | Prompt tokens equal | Answer equal |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| L6-seed1, teach | 29 (24) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| nights, day1 | 10 (10) | 56 | 53 | 56 | 56 | 56 | 56 | 56 | 56 |
| nights, day2 | 20 (18) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| nights, day3 | 29 (24) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| nights, day4 | 32 (24) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| nights, day5 | 32 (24) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| sweep, 100 notes | 100 (60) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| sweep, 1,000 | 1,000 (472) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| sweep, 10,000 | 10,000 (4,113) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |
| sweep, 100,000 | 100,000 (24,262) | 56 | 56 | 56 | 56 | 56 | 56 | 56 | 56 |

None of the 56 L6 questions is about the past as `notes.is_past` reads it (0 of 56), so the past view is not reached above. The same stores were asked again with the request fields (Python's `retrieve()` with `past=True`, with `exclude` = the first two ids it gives, and both):

| Store | Past forced (history section shown) | Two notes excluded | Past forced, two excluded |
| --- | --- | --- | --- |
| L6-seed1, teach | 56 of 56 equal (55) | 56 of 56 | 56 of 56 (54) |
| nights, day1 | 56 of 56 (0) | 56 of 56 | 56 of 56 (0) |
| nights, day2 | 56 of 56 (50) | 56 of 56 | 56 of 56 (48) |
| nights, day3 | 56 of 56 (55) | 56 of 56 | 56 of 56 (54) |
| nights, day4 | 56 of 56 (56) | 56 of 56 | 56 of 56 (55) |
| nights, day5 | 56 of 56 (56) | 56 of 56 | 56 of 56 (55) |

"Equal" here is all of the columns of the first table at once. In total, 560 + 1,008 = 1,568 questions, all equal on every column. The answers are not trivial: 232 distinct answers (token SHAs) among the 560 of the first table, 2 to 160 completion tokens, median 8.

The model's tokenizer in the server against Python's `tokenizers`: `/tokenize` of the 56 questions and the 56 teach blocks gives the same ids as `Tokenizer.encode(text, add_special_tokens=False)` for all 112 texts.

**Negative controls** (the same comparison, made to fail on purpose):

| Control | Block equal | Prompt tokens equal | Answer equal |
| --- | ---: | ---: | ---: |
| server on the del-B snapshot (a wrong store), teach questions and teach blocks | 0 of 56 | 0 | 31 of 56 |
| server on the teach store with the hop off (a wrong setting) | 9 of 56 | 9 | 41 of 56 |
| client block with its last line dropped (the engine's block still equal to Python's: 56 of 56) | 56 of 56 | 0 | 40 of 56 |
| server on the hop-off snapshot against Python's own hop-off blocks (the server follows the snapshot's settings) | 56 of 56 | 56 | 56 of 56 |

The unit tests have their own controls: the byte-tokenized fixture with the hop switched off must differ from Python's answers (it does), and the insertion test fails when the block is put last instead of first (checked by hand: 2 failures, both copies of the server test binary, at the prompt comparison).

## Time to first token and prefill tokens (MEASURED)

**Machine:** Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1. **TensorFold:** `c11e8d26`, the binary above. **Model:** Nemotron 3.5 Lightning 30B-A3B MLX 4-bit, revision `d9d758fb`. **Thinking off** (`enable_thinking: false`), temperature 0, `max_tokens` 8, streamed. **Server:** `--prompt-cache-gib 0 --context 32768`, drafts on; every reply reported 0 cached tokens. **Load:** a shared machine: load averages 5.4 to 10.1 during the runs (Google Drive, Finder, Photos, another LLWZ golden run); an idle Python TensorFold server (port 8091) and an idle TensorFold.app engine were resident and were not touched.

The stores are LLWZ `notes.py`'s sweep stores (L6-seed1's teach notes for owner `u0`, then `notes.distractors`, seed 1, as `notes_zig_golden.grow` builds them), the questions L6-seed1's 56. Arms: **(a)** the question alone; **(b)** Python `retrieve()`'s block sent by the client as a system message; **(c)** the question with `"notes": true`, looked up in the server. Each question was asked 4 times per arm; each (b) and (c) request came right after an (a) request (b first in even repetitions, c first in odd), for the reason below. A figure is the median of a question's 4 repetitions, then the p50 or p95 over the 56 questions. **Server TTFT** is the server's own `time_to_first_token`, which starts after the lookup; **TTFT + lookup** adds the server's notes `total_us` to it; **client first byte** is the client's time to the first content byte.

| Notes in store | Arm | Server TTFT p50 (ms) | p95 | TTFT + lookup p50 | p95 | Client first byte p50 | p95 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | (a) no notes | 46.7 | 54.3 | | | 47.2 | 54.9 |
| 100 | (b) notes sent by the client | 227.0 | 265.0 | | | 227.6 | 265.5 |
| 100 | (c) notes looked up in the server | 230.8 | 266.8 | 230.9 | 266.9 | 231.6 | 267.5 |
| 1,000 | (a) no notes | 52.9 | 62.9 | | | 53.4 | 63.4 |
| 1,000 | (b) notes sent by the client | 278.2 | 297.0 | | | 278.7 | 297.4 |
| 1,000 | (c) notes looked up in the server | 278.3 | 300.5 | 278.4 | 300.6 | 278.9 | 301.1 |
| 10,000 | (a) no notes | 48.4 | 58.5 | | | 49.1 | 59.2 |
| 10,000 | (b) notes sent by the client | 242.1 | 267.3 | | | 242.9 | 267.9 |
| 10,000 | (c) notes looked up in the server | 241.4 | 269.5 | 241.6 | 269.7 | 242.7 | 270.3 |
| 100,000 | (a) no notes | 40.8 | 49.6 | | | 41.4 | 50.3 |
| 100,000 | (b) notes sent by the client | 207.1 | 222.9 | | | 207.8 | 223.6 |
| 100,000 | (c) notes looked up in the server | 205.1 | 221.6 | 205.6 | 221.9 | 206.1 | 222.5 |

Prompt (prefill) tokens per request, the server's `usage.prompt_tokens` (first repetition; the same in every repetition):

| Notes in store | Arm | p50 | p95 | Total over the 56 questions |
| ---: | --- | ---: | ---: | ---: |
| 100 | (a) | 24 | 32 | 1,388 |
| 100 | (b) and (c), each | 503 | 513 | 26,730 |
| 1,000 | (a) | 24 | 32 | 1,388 |
| 1,000 | (b) and (c), each | 509 | 517 | 28,472 |
| 10,000 | (a) | 24 | 32 | 1,388 |
| 10,000 | (b) and (c), each | 512 | 520 | 28,679 |
| 100,000 | (a) | 24 | 32 | 1,388 |
| 100,000 | (b) and (c), each | 511 | 521 | 28,600 |

The lookup inside the server, (c), from the reply's `notes` field, in microseconds (p50 / p95), with Python's `retrieve()` on the same store and questions (its own `lookup_us`, which also encodes the question and counts the block with the tokenizer, timed once per question in the exporting process):

| Notes in store | Candidates | Question tokens | Lookup and render | `fit()` count | Total in server | Python `retrieve()` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 54 / 58 | 16.8 / 23.3 | 19.5 / 26.5 | 6.5 / 36.0 | 57.5 / 101.5 | 423 / 526 |
| 1,000 | 466 / 470 | 12.2 / 16.3 | 27.9 / 59.9 | 4.4 / 7.0 | 52.0 / 85.8 | 946 / 1,164 |
| 10,000 | 4,107 / 4,111 | 18.3 / 24.8 | 108.2 / 159.6 | 6.6 / 13.3 | 155.1 / 231.5 | 2,053 / 2,991 |
| 100,000 | 24,256 / 24,260 | 14.7 / 18.7 | 395.1 / 561.1 | 5.6 / 7.3 | 436.5 / 621.2 | 23,588 / 28,980 |

In all 896 (c) replies of these runs the note ids and the block's SHA-256 equal Python's for that question.

- **The block, not the lookup, sets the time.** (b) and (c) prefill the same tokens and take the same time: per question and repetition, (c) minus (b) has a median of -0.12, +0.85, -0.04 and +0.25 ms at 100 to 100,000 notes, inside the run-to-run spread (the p95 of the absolute difference is 20 to 38 ms). The lookup's own total (0.05 to 0.44 ms p50) is 0.02% to 0.21% of (c)'s time to first token. About 480 block tokens take the time to first token from 41 to 53 ms to 205 to 279 ms (p50).
- **The four stores ran in four server processes, minutes apart, under a changing load**: (a), which has nothing to do with the store, ranges from 40.8 to 52.9 ms p50 across them. Compare arms within a row group, not across stores.
- **Where the lookup is slower than LLWZ's own bench.** At 100,000 notes LLWZ's NOTES-ZIG.md measured 146 to 167 µs p50 for the standalone lookup (ReleaseFast, the same 56 questions asked 50 times in a loop); here the lookup and render take 395 µs p50 (343 µs in an earlier run of the same requests, below). The server's HTTP side is built ReleaseSafe and runs one lookup per request with cold caches (INFERRED: not measured apart). Python `retrieve()` on the same store took 23.6 ms p50.
- **An ordering effect, found on the way (MEASURED).** A first run asked the arms in an order rotated per question (a, b, c; b, c, a; c, a, b over 3 repetitions). There (c) came out 7 to 19 ms slower than (b) at p50. The cause is the engine, not the notes: a long prefill right after another long one is slower. The engine's own `prefill_seconds` (median, ms), by the request that came just before:

| Notes in store | (b) after (a) | (b) after (c) | (c) after (a) | (c) after (b) | Rotated: (c) - (b) TTFT, paired median | With an (a) before each: (b) after (a) | (c) after (a) | (c) - (b) TTFT, paired median |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 204.9 | 228.4 | 209.8 | 225.7 | +5.6 | 225.5 | 226.5 | -0.1 |
| 1,000 | 225.3 | 255.9 | 238.3 | 257.5 | +8.4 | 279.1 | 278.7 | +0.9 |
| 10,000 | 254.2 | 290.0 | 260.1 | 286.3 | +7.0 | 239.6 | 237.2 | -0.0 |
| 100,000 | 208.3 | 228.9 | 209.3 | 226.0 | +7.5 | 205.7 | 205.5 | +0.3 |

  In the rotated run (c) followed (b) 113 times and (a) 55 times, (b) the other way round; a long prompt right after a long prompt took 16 to 36 ms more. With an (a) before every (b) and (c), the two agree. Why a long prefill slows the next one was not looked into. The rotated run's lookup times (p50 / p95, µs: 100 notes 17.5 / 21.8; 1,000: 32.9 / 64.7; 10,000: 75.8 / 108.8; 100,000: 342.8 / 464.7) agree with the final run's within 1.5 times.

## Tests (MEASURED)

`zig build test test-golden -Dcpu=apple_m1 --summary all`, Zig 0.17.0, each run with an empty local cache:

| Tree | Steps | Unit tests | Golden corpus |
| --- | --- | --- | --- |
| upstream `main` `c7137bb3` | 164 of 164 succeeded | 1,981 of 1,989 passed, 8 skipped, 0 failed | 309 of 319 equal, 0 unexpected differences |
| this branch at `17fa3fc5` | 164 of 164 succeeded | 1,999 of 2,007 passed, 8 skipped, 0 failed | 309 of 319 equal, 0 unexpected differences |
| this branch at `f2b0ec49` | 164 of 164 succeeded | 2,013 of 2,021 passed, 8 skipped, 0 failed | 309 of 319 equal, 0 unexpected differences |

The 32 new tests are 16 tests counted twice: the server's test module runs in two test binaries (207 tests before, 223 after, in each). They are: the startup checks (`notes_startup_test.zig`: a named hash with no `tokenizer.json`, with no model folder, with a directory in its place, with a file its user may not read, with a file over the read limit, and with another file's hash each refuse startup; the matching hash starts, checked by hash; a snapshot naming none starts and its startup line says vocabulary-only; with the old fail-open put back, the four tests of an unreadable or missing file fail, in both binaries); the server's lookup against LLWZ Python's ids, tokens, candidates and block for each of 82 cases of a byte-tokenized L6-seed1 teach store (68 retrieving notes; 14 about the past; caps 512 and 128; exclusions), and the same store with its hop off as a control that must differ; a snapshot for another vocabulary refused; the request fields (15 bodies); the insertion end to end through a fake engine (the prompt with `"notes": true` equals the prompt with the same block sent by the client, with and without a client system message; nothing retrieved puts nothing in; exclusions honoured; a bad field is a 400; without `--notes` the field changes nothing); `is_past` against CPython for 40 texts (`tools/notes/past_cases.py`, which reports a deliberately wrong row); the order key; the C library's `log` bit for bit; the n-gram packing. `python3 tools/zig/lean_check.py`: 527 problems on `main` and on this branch (1,375 and 1,381 files); none in the new files.

After `14ddbdf5`, codexmb's review found that the vendored `Scratch.init` predated LLWZ `f54344f`: when one of its allocations failed, the ones before it were not freed, and in a long-lived server each such request leaks again. The fix is LLWZ's (`errdefer` for each), with two new tests in `notes_test.zig` (four counted twice): `Scratch.init` and `Index.load` under `std.testing.checkAllAllocationFailures` (each allocation fails in turn and all memory must come back), and a store loaded and asked twice with each of its own allocations failing in turn, by hand, as a failed keep of a scratch frees it and succeeds. Control: with the old `Scratch.init` both fail (464 bytes leaked when the second of its five allocations fails). Measured with a warm cache, not yet the empty-cache run of the table: `zig build test test-golden -Dcpu=apple_m1`, 164 of 164 steps, both server test binaries 225 of 225, the golden corpus 309 of 319 equal with 0 unexpected differences; the lean checker 527 problems, as before.

**`is_past`** is exact on ASCII and on the 40 checked texts, which include the Unicode cases Python's `re` treats specially (`ı`, `İ` and `ſ` folding, `\s` beyond ASCII, combining marks, `²`). Other non-ASCII text may be read differently from CPython (INFERRED: Python's `\w` is every alphanumeric code point, ported here as a table of the common punctuation and symbol blocks); a client can send `notes_past` to decide.

## Live writes (`/v1/notes`)

Written 16 October 2026 on branch `notes-live-writes` (from `notes-in-engine` at `1f3f5693`), for LLWZ ("Fast to Write, Slow to Learn"). Not pushed; no pull request. Every number in this section was measured on this Mac on 16 October 2026 (the machine above: Apple M5 Max, 18 cores, 128 GiB, macOS 27.0.1), with Zig 0.17.0, LLWZ at `origin/main` `2083ee9` (its tree is `4e43361`'s), CPython 3.12.8 and `tokenizers` 0.23.2.

### What a running server now does

| Request | What it does | Reply |
| --- | --- | --- |
| `POST /v1/notes` `{"text", "subject"?, "replaces"?}` | a new note of `subject` (default `"me"`), through the intake; with `replaces`, a change of that note | 201 `{id, version, state, verdict, written, source, told, superseded, same_as, note}`; 200 when the intake writes nothing (`ALREADY_KNOWN`) |
| `POST` or `PUT /v1/notes/ID` `{"text"}` | a change of mind: a new version on the note's pair; the old one retired (superseded), kept for "used to be" questions | as above |
| `DELETE /v1/notes/ID` `[{"text"}]` | a take-back: a take-back note (the user's own words, or "I take that back." when none are sent) written, the note retired as withdrawn and kept for questions about the past | as above, `tombstoned` |
| `DELETE /v1/notes/ID?erase=true` | erase: the store rebuilt from the snapshot and the journal without the note's write (LLWZ's `delete`: never taught) | 200 `{erased, removed: [sources], renumbered: [{from, to}], complete, remaining}` |
| `GET /v1/notes[?history=1]`, `GET /v1/notes/ID` | the current notes (with `history`, the retired ones too), each `{id, version, state, kind, subject, text, line, source, told, superseded_by, tombstoned_by}` | 200 |
| `POST /v1/chat/completions` with `"notes": true` | after the request's own lookup and before its reply, its last message, when it is the user's statement, goes through the intake as `POST /v1/notes` would take it | the reply's `notes.write`: a verdict and id, or `skipped` and why, or `failed` |

All of them sit behind the key check every `/v1` route has (401 without a valid key when the server has keys). Refusals: an unknown id is a 404; a change or take-back of a note that is no longer current, a take-back of a take-back, and an erase of a snapshot note are 409s; bad JSON, a missing or empty `text`, an unknown field, a bad `subject` or `replaces` are 400s; a `text` over 16 KiB or a body over 1 MiB is a 413; a store with no journal answers writes with 503; a write the journal cannot store is a 500 that changes nothing; a write the journal can neither store nor roll back is a 500 that says nothing was applied in memory and the disk may hold part of it, and every write after it a 503 ("the notes journal needs recovery, restart the server") while lookups go on. Off switches for the chat writes: `--no-notes-write` (the server) and `"notes_write": false` (a request; a 400 without `"notes": true`).

**The intake (READ: `zengine/intake.py`; what is ported).** `intake.classify` needs a lesson in the rule book's form (entity, attribute, operation, value, dates) and the rule book's oracle (`lwlogic.answer` over every question about the pair, about 6,700 lines of Python with the wording tables the parser reads). A sentence of free text has neither. The server ports the part that needs neither, and runs LLWZ's own `NoteStore` code for the rest (each step below is `_apply`, `retire`, `add`, `line` or `delete`, unchanged in effect):
- `ALREADY_KNOWN`: a new note whose text has the normal form (`intake.norm`, ASCII letters lowered) of a current fact of the same subject (for a change: of the same pair) writes nothing; the reply names the note it is the same as.
- `REPLACES`: an explicit change (`replaces`, or `POST /v1/notes/ID`) of a current fact; a take-back of a current fact. A change of a current take-back is `NEW` (the value was not known), as `intake.py`'s golden case "a change after 'not red anymore' is new".
- `NEW`: anything else.
- `IMPLIED` only on replay: a take-back of a note that an erase has since removed takes back nothing and writes nothing.
- Not ported: `REPLACES` without an explicit target (a free-text "My favourite colour is green now." after "... blue." is written as `NEW`, and both stay current unless the client names the note it changes), and `IMPLIED` ("follows from what is stored"). Both need the sentence read into a lesson (the parser over `lwlogic.T`, or the model extractor) and the rule book's answers over the pair. A take-back's label under the snapshot setting `takeback: "explicit"` depends on whether the attribute holds several values, which a snapshot does not record, so take-backs of snapshot notes are refused under that setting (the default `"plain"` reads the same either way).

**A chat request's own message.** Only the last message, and only when it is the user's: a conversation that ends in the model's or a tool's message writes nothing, and system messages, earlier messages and the model's answers never do (the model's answer can be wrong; storing it would keep the mistake). The lookup runs first, so a request's own block is the store before its message; the write is on disk before the reply, so the next request's lookup finds it. Before the intake, the message passes the server's gate (`notes/question.zig` and `intake.statement`; this gate is the chat path's alone: an explicit `POST /v1/notes` writes whatever text it is given, as LLWZ's `write` takes a lesson):

- **A question mark at the end.** Past trailing spaces (Python's `isspace`), quotes (`" ' `` ` `` ´ ‘ ’ “ ” « » ‹ ›` and the CJK and full-width ones), brackets (`( ) [ ] { } < >` and the CJK and full-width ones), emoji (U+1F000 to U+1FAFF, U+2300 to U+23FF, U+2600 to U+27BF, U+2B00 to U+2BFF, with variation selectors, joiners, keycaps and tags) and `!`, the message ends in any of the 25 question marks Unicode 16 names, punctuation or symbol (`?`, `¿`, `；`, `՞`, `؟`, `፧`, `᥅`, `⁇`, `⁈`, `⁉`, `‽`, `❓`, `❔`, `⳺`, `⳻`, `⸮`, `⹔`, `꘏`, `꛷`, `︖`, `﹖`, `？`, Chakma, Adlam and the squared one). A question mark (`¿`) opening the message counts too.
- **A question's first word.** Lower-cased (ASCII), past the same opening spaces, quotes, brackets and emoji: who, what, where, when, why, how, which, whose, whom, is, are, am, was, were, do, does, did, can, could, will, would, should, shall, may, might, have, has, had. A contraction counts as its first part ("what's" is what; "isn't", "don't", "doesn't", "can't" are is, do, does, can; "won't" is will). Only the first word: "This is my car." is a statement.
- **A request.** The message (after one leading "please") opens with the whole words "tell me", "remind me", "do you know", "show me", "list" or "explain".
- **Not one sentence.** No letter or digit (spaces, punctuation and emoji alone), a line break, or over 400 bytes.

Anything else the user says is written as a note of `"me"`. Caught, each in `notes/question.zig`'s list and the chat test: "What car does my sister drive" (no mark), `"Where do I live?"`, `(what's my name?)`, `？`, `؟`, `⸮`, `;` (Greek), a `?` followed by spaces, emoji or `!`, a `❓`, "tell me ...", "Please tell me ...", "do you know ...", "remind me", "show me", "list", "explain", and every opener above, contractions included. Written, as statements: "My sister is Anna.", "I live in Helsinki", "Anna drives a red Volvo", "yes, that's right" (a confirmation is the user's input), "This is my car.", "Isabel is my sister.", "Whoever calls, I am out.", "Listening to jazz relaxes me.", "Explanations bore me.", "Telling me twice helps.", "Anna asked me where I live." **What it does not catch, or catches wrongly** (English only, by design): a question in another language without a question mark ("Missä asun", "Wo wohne ich"); a question worded as a statement ("I wonder what my sister drives", "my sister drives what car"); a request outside the six ("Give me my sister's name", "Help me remember my car"); and it skips statements that open with an opener used otherwise ("Will is my brother.", "May is my sister's name.", "Do remember that I like tea.", "Have a look: my car is red."), and a statement ending in a quoted question (`He asked "why?"`). Letters are lowered as ASCII only.

**Ids, sources and time.** A note's id is `NoteStore`'s: the next after the highest. A write's source is `w1`, `w2`, ... and is never used twice (the journal's header keeps the next one across erases). A write is told at `max(the last write's tick + 100, today's first tick)`, today being the server's local date, as `_apply` does. An erase renumbers: the store is rebuilt and every note after the erased one moves down (the reply lists every move). An erase also takes out the writes the intake kept out as the same as the note, and the take-backs of it (they take back nothing once it is gone, so no other note changes); the changes of it stay, as the user's later words.

**Concurrency: copy-on-write.** The server keeps the notes as a model (`notes/model.zig`: what a snapshot holds) and builds the index from it; a snapshot loads the same way, so the index after a write is exactly what a snapshot of that store would load. A write (one at a time, under a writer lock) applies itself to the model, builds a new index version, appends to the journal and syncs it, and only then swaps the version in; on any failure before the sync the model is put back (undone) and the new version freed. A lookup takes the current version (a reader count) and reads it without any lock; a retired version is freed by the writer once no lookup holds it. No lookup ever waits for a write, and none can see half of one. The cost is the write: it rebuilds the whole index (below).

**Durability: the journal.** `SNAPSHOT.journal` beside the snapshot (format `tf-notes-journal/2`), made at the first write with a header naming the snapshot's SHA-256. Each write is two lines: the write itself (the request, not its effect; the text as UTF-8), written and `F_FULLFSYNC`ed (macOS; `fsync` elsewhere), then its commit line `{"commit": SOURCE}`, written and synced; only then is it answered as stored. Replay counts a write only with its commit line after it: a write without one (its sync failed, or the process stopped) and anything torn after it are cut at the next start, under the lock, and never applied; a write followed by something other than its commit line stops the start. Every result on the append path is checked. A failed write or sync cuts the file back to its last committed write and syncs that: refused, nothing changed. If that rollback fails too (its truncate or its sync), the journal is poisoned: every later write (the chat's own included) is refused with 503 until a restart, lookups go on from the last good version, and the failed write's reply says nothing was applied in memory and either that a restart drops it (its commit line was never written: the case codexmb found in `2e029302`, where a whole write whose sync failed would have been replayed) or, in the one narrow case where its commit line was written but its sync then failed and the rollback failed too, that the disk state is unknown and a restart may apply it. A journal of the first format (no commit lines, every whole line a write) is replayed whole and rewritten as format 2 at open, by the temporary-file rules below. (codexmb's reviews: of `7a00935d`, the rollback's results were ignored, so "nothing changed" was claimed without being established; of `2e029302`, a whole write whose sync and rollback failed came back at the restart.) At startup the journal is replayed over the snapshot; a last line without its newline (a crash mid-write) is cut; a line that is not a write, or a journal naming another snapshot, stops startup; a second server on the same journal finds it locked (`flock`) and does not start. An erase writes the journal anew without the erased writes into a new file beside it, named `JOURNAL.tmp.PID.COUNTER.RANDOM` (64 random bits from `arc4random_buf`), made `O_CREAT|O_EXCL|O_NOFOLLOW` at mode 0600 (a file or a link already at that name is refused, and the next name tried); it is synced, locked, renamed over the journal, and the folder synced. If anything fails before the rename, only that file is removed, and only while its name is still that file (device and inode). A starting server takes the journal's lock before anything else; only then does it remove temporary files a rewrite left behind (a crash before its rename), and only names of that pattern or the old `JOURNAL.tmp`, never a directory, and `unlink` removes a link itself, never what it points to. (codexmb's review of `b73829ec` found the old order: the old fixed `.tmp` name was unlinked before the lock, so a second server could remove a live rewrite's file, and opened with `O_CREAT|O_TRUNC`, so a link planted there could truncate another file.)

**Erase (LLWZ paper 4.5: "gone from every structure, caches included").** After an erase: the old index versions are freed once no lookup holds them (the erase waits for that before it answers), with the old model, the old journal records and every lookup scratch made before it (a scratch keeps the last block it rendered); all of the store's memory goes through an allocator that zeroes what it frees. The model tokenizer's encode memo (`memo.zig`: every segment of 1 KiB or more, which a notes block is) is cleared, its text and ids zeroed. The journal is rewritten without it. What the server cannot reach: the engine's prompt cache (kept prompts carry the block's tokens; the reply says `"complete": false` and names it whenever the engine keeps one; serve with `--prompt-cache-gib 0` for an erase that reaches every cache) and learned prompt states on disk (`--learn`); `TENSORFOLD_REQUEST_LOG`, which keeps chat bodies (a user's statement among them) when the operator sets it; freed blocks on the disk (APFS writes new blocks; the old ones are not overwritten); request memory already freed. Snapshot notes cannot be erased by the server (409): erasing one changes what LLWZ's intake decided about every later lesson, which needs the rule book; erase it in LLWZ and export again.

### Against LLWZ Python (MEASURED)

**With the model's tokenizer, on a real server** (`tools/notes/live.py`): each store of the 1,568-question set is built in LLWZ's `NoteStore` with the server's intake for later writes (`tools/notes/live_intake.py`: `classify` and `no_longer_current` take the deterministic part for HTTP writes and stay LLWZ's for the set's own lessons; nothing else is changed), exported, and served by `tensorfold-native` built from `ed09efd2` (`--prompt-cache-gib 0 --context 32768`). The same 16 steps then run over HTTP and in Python: 12 writes (adds, a normal-form duplicate, two subjects, a chat request's own statement, a change of a snapshot note, a change of a written note, a take-back of a snapshot note and of a written one with the user's words, a change of a take-back, a same-as) with checkpoint A after the first five, checkpoint B, then a take-back and three erases (one with its duplicate, one with its take-back, one of a change, which brings the snapshot note back). At checkpoints A, B and C every question is asked with `"notes": true` (thinking off, `max_tokens` 1) and must give Python `retrieve()`'s block byte for byte with the same ids, tokens and past flag; for l6-teach and the five nights also with the past view forced, two notes excluded, and both, as the 1,568 set asks them. The listing must equal Python's notes (id, version, state, line), and every write's reply Python's (verdict, id, source, told). Then the server is restarted on the snapshot and the journal and checkpoint C asked again, and Python's own export of the written store is served from a fresh folder and asked again.

| Store | Notes | Variants | A | B | C | C after restart | C from Python's export | Listing equal | Moved at C (control) | Replies equal |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| l6-teach | 29 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 220 of 224 | all 16 |
| nights-day1 | 10 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 214 of 224 | all 16 |
| nights-day2 | 20 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 216 of 224 | all 16 |
| nights-day3 | 29 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 220 of 224 | all 16 |
| nights-day4 | 32 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 220 of 224 | all 16 |
| nights-day5 | 32 | 4 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | 224 of 224 | all 5 | 220 of 224 | all 16 |
| sweep-100 | 100 | plain | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | all 5 | 55 of 56 | all 16 |
| sweep-1000 | 1,000 | plain | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | all 5 | 34 of 56 | all 16 |
| sweep-10000 | 10,000 | plain | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | all 5 | 12 of 56 | all 16 |
| sweep-100000 | 100,000 | plain | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | 56 of 56 | all 5 | 14 of 56 | all 16 |
| **All** | | | **1,568 of 1,568** | **1,568 of 1,568** | **1,568 of 1,568** | **1,568 of 1,568** | **1,568 of 1,568** | 10 of 10 stores | 1,425 of 1,568 | 0 differ |

Each cell: blocks equal (with the same ids, tokens and past flag) of the questions asked; "4" variants are as asked, past forced, two excluded, both. In all, 7,840 of 7,840 comparisons equal; the listing equal in all 50 checks; all 160 replies (13 writes and 3 erases a store) give Python's verdict, id, source and tick, the erases its removed writes and renumbering. The control: 1,425 of the 1,568 blocks at checkpoint C differ from the same question's block before any write (the writes reach most questions; the sweeps' distractors push the new notes out of some blocks), so the comparison is not of blocks the writes left alone. Python built the 100,000-note store in 704 s; its five deletes for the erases (each rebuilds the owner through LLWZ's own intake) took most of the run's 105 minutes. `docs/notes-in-engine/live-summary.json` holds these counts.

**With the byte tokenizer, in the unit tests** (`notes_live_test.zig`): `tools/notes/fixture.py` runs the 12 writes and 3 erases of its own script through the same Python store under the byte tokenizer and records every reply, and at three checkpoints every one of the 82 fixture cases (ids, tokens, candidates, the block's SHA-256) and every note's line. The server's test runs the script over HTTP (the three change forms in turn) and gets all of it, the same after a restart. Controls: the same script with one take-back left out differs at the next checkpoint (built in); with the retired notes' label dated by the old note's day instead of the replacing write's, the test fails (by hand, then reverted); with the journal not rewritten on erase, the restart check differs in 83 places (by hand, reverted).

### Writes and lookups at once (MEASURED)

`zig build notes-live-bench` (ReleaseSafe, as the server's HTTP side), the model's tokenizer, 8 threads looking up L6-seed1's 56 questions without pause as a chat request does (encode, lookup, `fit()`): 2 s alone, then during the writes, then 2 s alone on the store the writes left (the control: every write but a same-as adds a note). The writes: adds, changes, same-as adds and take-backs in turn, every hundredth an erase and an add; each write's time includes the index build and the journal sync. Load averages 11.3 to 13.2 (a shared machine: an idle Python TensorFold server, TensorFold.app's engine, another agent's test server, this branch's cross-check rebuilding the 100,000-note store in Python). Binary built from `ed09efd2`.

| Store (notes before, after) | Writes (erases) | Lookup p50 / p95 (us): alone before | during the writes | alone after | Write p50 / p95 (ms) | Erase p50 / p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| L6-seed1 teach (29, 769) | 990 (10) | 7.1 / 40.0 (898,787) | 8.1 / 40.2 (2,368,143) | 7.8 / 35.2 (1,300,663) | 3.9 / 4.3 | 35.0 / 43.0 |
| sweep 10,000 (10,000, 10,740) | 990 (10) | 51.7 / 79.6 (320,483) | 52.0 / 86.8 (1,984,098) | 52.4 / 81.5 (314,775) | 14.5 / 17.2 | 90.7 / 104.8 |
| sweep 100,000 (100,000, 100,148) | 198 (2) | 233.5 / 379.8 (73,024) | 248.3 / 410.9 (686,399) | 256.4 / 444.6 (60,937) | 121.0 / 141.2 | 588.5 / 630.4 |

(In parentheses: the lookups timed.) No lookup failed.

- **Lookups barely move while writes land.** At 100,000 notes the p50 and p95 during the writes lie between the runs alone before and after; at 10,000 the p50 does and the p95 is 6.5 % above the slower run alone (86.8 against 81.5 us); at 29 to 769 notes the p50 is 0.3 us (4 %) and the p95 0.2 us above it. No lookup waits for a write; the writer builds the next index on another core meanwhile (INFERRED: the small rise is that build's memory traffic, not measured apart).
- **A write costs the index rebuild plus the sync.** 3.9 ms at 29 to 769 notes (mostly the `F_FULLFSYNC`), 14.5 ms at 10,000 and 121 ms at 100,000 (p50; copy-on-write rebuilds the whole index; an index changed in place would cost microseconds, and is not built). Before `ed09efd2` the build grouped notes by entity in a loop over every note per entity: a write at 100,000 notes took 478 ms. An erase re-reads the snapshot and replays the journal: 35 ms, 91 ms and 589 ms.
- **In the unit tests** (Debug build, byte tokenizer, `notes_concurrency_test.zig`): 8 threads during 1,000 writes and 10 erases made 2,038,101 lookups over 761 versions; after each write the writer asked every question alone on the new version, and all 2,038,101 blocks equal their version's (0 torn, 0 of a version the writer did not make).

### End to end (MEASURED)

A test server on port 18312 (`tensorfold-native` from `ed09efd2`, the model above, `--prompt-cache-gib 0 --context 32768 --notes empty.snap.json`, an owner with no notes exported by LLWZ with the model's tokenizer); requests with temperature 0 (the model's default samples at 1.0), thinking off, `max_tokens` 32, `"notes": true, "notes_echo": true`:

```
POST /v1/notes {"text": "My favourite colour is green."}  -> 201 {"id": 1, "version": 1, "state": "current", "verdict": "NEW", "source": "w1"}
"What colour do I like?"  -> "Your favourite colour is green."   notes [1], block: Current: [1] "My favourite colour is green."
DELETE /v1/notes/1        -> 201 {"id": 2, "verdict": "REPLACES", "tombstoned": [1]}   [2] "I take that back." (this takes back something said earlier)
GET /v1/notes?history=1   -> [1] tombstoned "(the user withdrew this on 16 October 2026, in [2])", [2] current
"What colour do I like?"  -> "Based on the context provided, you like the colour **blue**. This is inferred from your statement "I take that back," ..."   notes [2]
```

The note is used, and after the take-back it is not: the second block holds only the take-back line, and neither block mentions green afterwards. The model then invented "blue" from a block that names no colour, the failure LLWZ's paper already reports for take-backs ("they do not yet stop invented answers after a take-back"; `takeback: "explicit"` is LLWZ's answer to it). The questions were not written (`"write": {"skipped": "a question: it asks, it does not tell"}`). The server was stopped after the run.

### Tests (MEASURED)

New in `zig build test` (each server test runs in two binaries): the line renderer and dates against Python's (`line.zig`), `norm` against `intake.norm` for the fixture's texts, the statement gate, `Memo.clear`, the zeroing allocator; the fixture equivalence and its control (above); each endpoint's happy path and 27 refusals, writes off without a journal and without `--notes`, the key gate over a real listener (401 without or with a wrong key, 201 with it, nothing written without it); the erase test (a tracking allocator sees every live allocation of the store: before the erase the text is in some, after it in none; nor in any file of the folder, nor the journal; the erased text's token ids in no note and their keys in no n-gram or phrase; the tokenizer asked to forget; the same after a restart); the failing allocator over every write path (add, add with a new subject, already known, change of a snapshot and of a written note, take-back of each, erase: 6 to 288 allocation points each, every one failed in turn; after each failure the notes, the journal and the log are as before, the same write then succeeds, and no byte leaks); the journal (on disk before the reply, the same blocks after a restart, a torn line cut, a bad line, a journal for another snapshot and a locked one refused, a journal that can be neither written nor truncated a 500, poisoned, later writes 503; with faults injected (a test-only hook fails an append's Nth write, truncate or sync, a failing write putting down half its bytes): a failed write rolled back changes nothing and the next write is stored, a failed write whose rollback truncate fails or whose rollback sync fails poisons the journal (writes, erases and the chat's own write refused, the same block and listing as before), and the half record it left is cut at the next start, which replays to the last whole record; with the truncate's result ignored again test (b) fails, with the sync's ignored test (c) fails; (e) a whole write whose sync fails and whose rollback truncate fails is cut at the restart and never applied (with a write lacking its commit line counted anyway, (e) fails); (f) a commit line written whose sync fails, rollback failing: the reply says a restart may apply it, and the restart does; (g) a format-1 journal is replayed whole and rewritten as format 2; a second process opening the journal while the first is between its rewrite's sync and its rename is refused as Locked and leaves the first's file, and the rewrite completes; a symlink and a hardlink planted at the old `.tmp` name and at every name a rewrite tries, each to a sentinel, leave both sentinels unchanged, and the next start removes the 9 planted names; with the cleanup moved back before the lock, or the file opened without `O_EXCL|O_NOFOLLOW`, the respective test fails); writes from chat (a statement written and found by the next lookup, a duplicate skipped, a confirmation written and kept over a restart, no assistant, tool or system text and no earlier user message ever stored, the off switches; the gate: each of `question.zig`'s 55 questions and requests skipped in a chat request and its 18 statements written, the documented misses and wrong skips pinned, and with the gate reverted by hand to the trailing-`?` rule three tests fail, the first on "What car does my sister drive" being written); the concurrency test (above). Controls by hand, each reverted: the user-only rule removed (the assistant test fails); old scratches kept through an erase (the erase test finds the text in one live allocation); the journal not rewritten (the erase test finds it in the journal).

`zig build test test-golden -Dcpu=apple_m1 --summary all`, Zig 0.17.0, an empty local cache (a new `--cache-dir`), at `0a13245b`: 164 of 164 steps succeeded, 2,060 of 2,068 tests passed, 8 skipped, 0 failed, exit 0; the golden corpus 309 of 319 equal, 0 unexpected differences. Before: 2,013 of 2,021 at `f2b0ec49` (the table above) and 4 more at `1f3f5693`; the 43 new ones are 21 server tests counted twice (each server test binary: 246, from 225) and `Memo.clear`. `python3 tools/zig/lean_check.py`: 527 problems in 1,400 files, as on `main`; none in the new files. `dbd9d964` changed one read in `notes_store.zig` after that run (a race with an erase, found reviewing the code; no test caught it): `zig build test-server-cpu -Dcpu=apple_m1`, 246 of 246. The server binary of the cross-check, the bench and the end-to-end run is `ed09efd2`'s; the code it serves differs from `dbd9d964`'s only in that read. After codexmb's review (`0a88ba10`, the chat gate; `7cde695c`, the journal's temp files), at `7cde695c` with a warm cache: 164 of 164 steps, exit 0, every test that ran passed (508 of 508: the two server test binaries, 254 each), the golden corpus 309 of 319 equal with 0 unexpected differences, the lean checker 527 problems in 1,403 files. The 16 tests added since `0a13245b` (8 counted twice) make the whole count 2,076 of 2,084 passed and 8 skipped: derived, not run again with an empty cache, which the disk (under 25 GiB free) did not allow. The 1,568-question cross-check again at `7cde695c` (`docs/notes-in-engine/live-summary-7cde695c.json`): 1,568 of 1,568 blocks equal at each of the five checkpoints (7,840 of 7,840), every listing (50 of 50) and reply (160 of 160) equal, and the control the same as before (1,425 of 1,568 blocks moved at C). This run served the stores with `fake_serve` (the golden harness: this branch's `serve` code, the model's own `tokenizer.json`, `tokenizer_config.json` and chat template, a scripted engine instead of the weights; a Debug build), because a second model server had pushed this Mac into 14 GB of swap with its free disk under 18 GiB. Every compared field is decided by the server before the engine runs, so the weights take no part in it; `fake_serve` now passes `TF_FAKE_TOKENIZER`'s folder as the model folder, so `--notes` checks the snapshot's tokenizer hash there (the goldens: 309 of 319, unchanged). After codexmb's next two reviews (`2e029302`: a failed rollback poisons the journal; `a9cfab93`: commit lines), at `a9cfab93` with a warm cache: 164 of 164 steps, exit 0, each server test binary 261 of 261, golden 309 of 319 equal with 0 unexpected differences, the lean checker 527; the whole count derived as above, 2,090 of 2,098 passed and 8 skipped. The cross-check at `a9cfab93` (`fake_serve`, `docs/notes-in-engine/live-summary-a9cfab93.json`): 7,840 of 7,840 blocks equal and 50 of 50 listings, the control unchanged; 159 of 160 replies at first, because the run passed midnight while the harness had fixed "today" at its start, and the server (rightly, as `_apply` does) told the write made after midnight on the new day; that write was erased at the next step, so no block saw it. With the harness taking the date per write, the 100,000-note store run again: 280 of 280 blocks equal, the listing and all 16 replies equal, the control unchanged (`live-summary-a9cfab93-sweep-100000-again.json`); so at `a9cfab93` all 7,840 blocks and, with the date taken per write, all 160 replies equal Python.

### Not done (writes)

- `REPLACES` and `IMPLIED` from free text (above): the parser or the model extractor, and the rule book.
- One owner per server, as before; one server per snapshot (the journal is locked).
- A write rebuilds the whole index: 121 ms (p50) at 100,000 notes. An index changed in place under a short write lock would cost microseconds; not built.
- Erase cannot reach the engine's prompt cache or `--learn`'s states on disk (the reply says so), nor a request log the operator set; snapshot notes are not erasable in the server.
- A chat request's own statement is written unless the English-only gate above reads it as a question or a request: a question worded as a statement, or one in another language without a question mark, is written; a statement opening with "Will", "May", "Do" or "Have" is not. A client that resends an old conversation ending in the user's message writes that message again (unless it is the same as a current note), even after it was taken back.
- `/v1/completions`, `/v1/responses` and `/v1/messages` neither look up nor write.

## Reproducing

```sh
zig build native -Dcpu=apple_m1 -Dversion=1.0.0
```

```sh
PYTHONHASHSEED=0 python tools/notes/export.py LLWZ_DIR MODEL_DIR/tokenizer.json OUT
```

```sh
zig-out/native/bin/tensorfold-native serve MODEL_DIR --port 18301 --prompt-cache-gib 0 --context 32768 --notes OUT/l6-teach.snap.json
```

```sh
python3 tools/notes/run.py compare http://127.0.0.1:18301 OUT/l6-teach.ref.json cmp.jsonl
```

```sh
python3 tools/notes/run.py bench http://127.0.0.1:18301 OUT/sweep-100000.ref.json docs/notes-in-engine/bench-sweep-100000.jsonl
```

```sh
python3 tools/notes/report.py docs/notes-in-engine docs/notes-in-engine 100 1000 10000 100000
```

Live writes:

```sh
PYTHONHASHSEED=0 python tools/notes/fixture.py LLWZ_DIR
```

```sh
zig build test-server-cpu -Dcpu=apple_m1
```

```sh
PYTHONHASHSEED=0 python tools/notes/live.py LLWZ_DIR MODEL_DIR zig-out/native/bin/tensorfold-native OUT
```

```sh
zig build notes-live-bench -Dcpu=apple_m1
```

```sh
zig-out/bin/notes-live-bench MODEL_DIR OUT/sweep-10000.snap.json OUT/sweep-10000.ref.json BENCH_DIR 1000
```

`fixture.py` now also writes `l6_bytes_writes.json` (the write script's replies and checkpoints); it needs `PYTHONHASHSEED=0`, or one of the 82 old cases comes out otherwise (a float tie). `live.py` starts and stops its own servers on port 18311 and builds the sweep stores in Python as `export.py` does (the 100,000-note one takes about 13 minutes). `docs/notes-in-engine/live-summary.json` and `docs/notes-in-engine/bench-live-*.json` are this run's receipts.

`export.py` needs a Python with `tokenizers` (CPython 3.12.8 and `tokenizers` 0.23.2 here); growing the 100,000-note store took 811 s. `run.py` and `report.py` are standard library only. `docs/notes-in-engine/` holds the receipts: `equivalence.json` (every compare run above, per question: the checks, both id lists, both token SHAs and counts), `bench-sweep-N.jsonl` and `bench-rotated-sweep-N.jsonl` (every timed request, compacted to its numbers and a same-as-Python verdict), and `sweep-N.ref.json` (Python's blocks and times for those stores); `report.py` on that folder prints the timing tables above exactly. `tools/notes/fixture.py LLWZ_DIR` rewrites the unit tests' fixture (written here with CPython 3.14.3, standard library only).
