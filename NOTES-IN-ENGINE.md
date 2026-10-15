# The note lookup inside the native server (`--notes`)

LLWZ's note lookup (paper section 4.2) run inside `tensorfold-native`, per chat request, before the prompt is rendered and prefilled, and checked against LLWZ's own Python question by question. Written 15 October 2026 on branch `notes-in-engine` of our fork (ThinkOffApp/TensorFold), from upstream `main` at `c7137bb3`. Not pushed; no pull request.

Grades, as in LLWZ's NOTES-ZIG.md: **MEASURED** means we ran it, on the machine stated above each table. **READ** means we read it in code or a document. **INFERRED** means our own reasoning, not checked by a run. Every number below was measured on this Mac on 15 October 2026.

## In short

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

**Not done:** writes (intake, supersede, take-back, delete) stay in Python, and the server reads a snapshot once, at startup, so a write reaches it only by a new export and a restart; one owner per server; `/v1/completions`, `/v1/responses` and `/v1/messages` do not take the fields; no request with several lookups at once was measured.

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

**`is_past`** is exact on ASCII and on the 40 checked texts, which include the Unicode cases Python's `re` treats specially (`ı`, `İ` and `ſ` folding, `\s` beyond ASCII, combining marks, `²`). Other non-ASCII text may be read differently from CPython (INFERRED: Python's `\w` is every alphanumeric code point, ported here as a table of the common punctuation and symbol blocks); a client can send `notes_past` to decide.

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

`export.py` needs a Python with `tokenizers` (CPython 3.12.8 and `tokenizers` 0.23.2 here); growing the 100,000-note store took 811 s. `run.py` and `report.py` are standard library only. `docs/notes-in-engine/` holds the receipts: `equivalence.json` (every compare run above, per question: the checks, both id lists, both token SHAs and counts), `bench-sweep-N.jsonl` and `bench-rotated-sweep-N.jsonl` (every timed request, compacted to its numbers and a same-as-Python verdict), and `sweep-N.ref.json` (Python's blocks and times for those stores); `report.py` on that folder prints the timing tables above exactly. `tools/notes/fixture.py LLWZ_DIR` rewrites the unit tests' fixture (written here with CPython 3.14.3, standard library only).
