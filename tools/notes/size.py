"""The bytes of note snapshots against their plain text, and the engine's bytes from notes-size-bench beside them.

  python3 -I tools/notes/size.py BENCH.jsonl SNAPSHOT...

For each snapshot, read from the file itself: the note texts (each line's quoted text, decoded) in UTF-8 bytes, the
token ids, and the file's bytes by top-level section (the file is json.dump(snap, separators=(",", ":")), and this
checks that re-serializing it gives the same bytes, so the section sizes add up to the file). BENCH.jsonl is
notes-size-bench's output for the same snapshots (zig build notes-size-bench); its text and token counts must equal
these. Prints the per-note table and the breakdown of the largest store. Standard library only.
"""
import json
import os
import sys

PARTS = ("notes", "grams", "entities", "vocab", "other")
NAMES = {"notes": "note records, texts, lines, token ids", "grams": "n-gram keys and postings",
         "entities": "entity and subject tables", "vocab": "tokenizer tables (fixed per vocabulary)",
         "other": "structs, fixed strings, arena slack"}


def read_snapshot(path):
    raw = open(path, "rb").read()
    d = json.loads(raw)
    same = json.dumps(d, separators=(",", ":")).encode() == raw
    sections = {k: len(json.dumps(k)) + 1 + len(json.dumps(v, separators=(",", ":"))) for k, v in d.items()}
    framing = 2 + len(sections) - 1   # the braces and the commas between sections
    dec = json.JSONDecoder()
    text = tokens = 0
    for n in d["notes"]:
        line = n["line"]
        start = line.index(" ") + 1   # "[id] " then the quoted text
        t, _end = dec.raw_decode(line, start)
        text += len(t.encode("utf-8"))
        tokens += len(n["tokens"])
    return {"file": len(raw), "same": same, "sections": sections, "framing": framing, "notes": len(d["notes"]),
            "text": text, "tokens": tokens}


def main():
    bench = {}
    for ln in open(sys.argv[1]):
        b = json.loads(ln)
        bench[b["snapshot"]] = b
    rows = []
    for path in sys.argv[2:]:
        s = read_snapshot(path)
        b = bench[os.path.basename(path)]
        assert s["same"], f"{path}: re-serializing does not give the file's bytes"
        assert sum(s["sections"].values()) + s["framing"] == s["file"] == b["file_bytes"], path
        assert (s["notes"], s["text"], s["tokens"]) == (b["notes"], b["text_bytes"], b["token_ids"]), path
        assert b["model_gap"] == 0 and b["index_gap"] == 0, f"{path}: the walk does not come to the counters' bytes"
        assert b["ids_equal_encode"] == b["notes"] and b["ids_as_python"] == b["asked"], path
        rows.append((s, b))

    print("Checks: every file re-serializes to its own bytes; Python's and the engine's note, text and token counts "
          "agree; the field walk equals the counting allocators to the byte; every note's ids equal the engine "
          "tokenizer's encode of its text; the store's lookups give Python retrieve()'s ids for every question.\n")
    print("| Notes in store | Text bytes/note | Token-id bytes/note | Snapshot bytes/note (without vocab) "
          "| Engine bytes/note (without vocab) | Engine / text | malloc blocks bytes/note | + one lookup scratch, bytes/note |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for s, b in rows:
        n = b["notes"]
        vocab_file = s["sections"]["vocab"]
        vocab_mem = sum(it["bytes"] for it in b["items"] if it["part"] == "vocab")
        print(f"| {n:,} | {b['text_bytes'] / n:,.1f} | {b['token_ids'] * b['token_id_width'] / n:,.1f} "
              f"| {s['file'] / n:,.0f} ({(s['file'] - vocab_file) / n:,.0f}) "
              f"| {b['store_live'] / n:,.0f} ({(b['store_live'] - vocab_mem) / n:,.0f}) "
              f"| {b['store_live'] / b['text_bytes']:,.1f} ({(b['store_live'] - vocab_mem) / b['text_bytes']:,.1f}) "
              f"| {b['store_held'] / n:,.0f} | {b['scratch'] / n:,.1f} |")
    print("\n| Notes | Text bytes | Token ids | Snapshot bytes | of which vocab section | Engine bytes (Store.open) "
          "| of which vocab tables | malloc blocks | Startup peak (bytes asked) | Lookup scratch |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for s, b in rows:
        vocab_mem = sum(it["bytes"] for it in b["items"] if it["part"] == "vocab")
        print(f"| {b['notes']:,} | {b['text_bytes']:,} | {b['token_ids']:,} | {s['file']:,} | {s['sections']['vocab']:,} "
              f"| {b['store_live']:,} | {vocab_mem:,} | {b['store_held']:,} | {b['store_open_peak']:,} | {b['scratch']:,} |")

    s, b = rows[-1]
    n = b["notes"]
    wrapper = b["store_live"] - b["model_live"] - b["index_live"]
    print(f"\nBreakdown at {n:,} notes ({b['current']:,} current, {b['history']:,} earlier; {b['entities']:,} entities, "
          f"{b['pairs']:,} pairs, {b['grams']:,} distinct n-grams, {b['postings']:,} postings):\n")
    print("| Part | Bytes | Bytes/note | Share | x text |")
    print("| --- | ---: | ---: | ---: | ---: |")
    total = b["store_live"]
    for part in PARTS:
        x = sum(it["bytes"] for it in b["items"] if it["part"] == part) + (wrapper if part == "other" else 0)
        print(f"| {NAMES[part]} | {x:,} | {x / n:,.1f} | {100 * x / total:.1f}% | {x / b['text_bytes']:.2f} |")
    print(f"| **all** | {total:,} | {total / n:,.1f} | 100% | {total / b['text_bytes']:.2f} |")
    print("\n| Part | Item | Bytes | Bytes/note | Grade |")
    print("| --- | --- | ---: | ---: | --- |")
    for it in sorted(b["items"], key=lambda it: (PARTS.index(it["part"]), -it["bytes"])):
        print(f"| {it['part']} | {it['what']} | {it['bytes']:,} | {it['bytes'] / n:,.1f} | {it['grade']} |")
    print(f"| other | server wrapper (Store, Version, the snapshot and journal paths) | {wrapper:,} | {wrapper / n:,.3f} | measured |")
    print("\nSnapshot file by section at this size:")
    for k, v in sorted(s["sections"].items(), key=lambda kv: -kv[1]):
        print(f"  {k}: {v:,} bytes ({v / n:,.1f}/note)")
    print(f"  braces and commas: {s['framing']}")
    print(f"\nResidency (mincore, the server's copy): the index arena's unused newest-node tail {b['arena_tail']:,} bytes, "
          f"{b['arena_tail_resident']:,} resident; the note list's spare capacity {b['spare']:,}, {b['spare_resident']:,} "
          f"resident; control, the postings' whole pages {b['post_whole_pages']:,}, {b['post_resident']:,} resident.")


if __name__ == "__main__":
    main()
