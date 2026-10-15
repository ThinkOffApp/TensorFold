"""The unit tests' note fixture: an LLWZ store under a byte tokenizer, and Python's retrieve() for each case.

  python3 tools/notes/fixture.py LLWZ_DIR [--out zig/src/server/notes/testdata]

The store is LLWZ's examples/L6-seed1.json, phase teach, written by LLWZ's own notes.set_store with a tokenizer whose
ids are UTF-8 bytes (vocabulary 256), so the server's tests can run it through a byte tokenizer of their own. Each case
is a question with its past flag (as asked, or as notes.is_past reads it), its cap and its excluded notes, and what
NoteStore.retrieve() returned: the ids, the exact tokens and the block (whole for the first few, else its SHA-256).
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "zig", "src", "server", "notes", "testdata")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("llwz")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    sys.path.insert(0, os.path.join(args.llwz, "zengine"))
    import notes as nm  # noqa: E402  (LLWZ's)
    import notes_export as nx  # noqa: E402

    class Bytes(nm.HFTokenizer):
        """Token ids are the text's UTF-8 bytes: the exporter treats it as a model tokenizer with 256 ids."""

        def __init__(self):
            self.sha256 = None
            self.version = "bytes"
            self.name = "bytes"
            self.tok = type("V", (), {"get_vocab_size": lambda _s, with_added_tokens=True: 256})()

        def encode(self, text):
            return list(text.encode("utf-8"))

        def piece(self, i):
            return bytes([i]).decode("utf-8", errors="replace")

        def describe(self):
            return {"name": "bytes"}

    tok = Bytes()
    S = nm.load_set(os.path.join(args.llwz, "examples", "L6-seed1.json"))
    teach = next(p for p in S["phases"] if p["name"] == "teach")
    ns, _w = nm.set_store(S, teach["store"], tok)
    snap, _v = nx.snapshot(ns, "user", meta={"set": S["id"], "phase": "teach", "tokenizer": "bytes"})
    qs = [q["text"] for q in S["questions"]]
    first = ns.retrieve("user", qs[0])
    cases = []
    for k, t in enumerate(qs):
        jobs = [(None, None, ())]
        if k % 4 == 0:
            jobs.append((True, 128, ()))
        if k % 5 == 0:
            jobs.append((False, None, tuple(first["ids"][:2])))
        for past, cap, ex in jobs:
            r = ns.retrieve("user", t, cap=cap, past=past, exclude=ex)
            case = {"question": t, "past": past, "cap": cap, "exclude": list(ex), "past_read": r["past"],
                    "ids": r["ids"], "tokens": r["tokens"], "candidates": r["candidates"],
                    "block_sha256": hashlib.sha256(r["block"].encode()).hexdigest() if r["block"] else None}
            if len(cases) < 4:
                case["block"] = r["block"]
            cases.append(case)
    os.makedirs(args.out, exist_ok=True)
    for name, value in (("l6_bytes_snapshot.json", snap), ("l6_bytes_cases.json", cases)):
        with open(os.path.join(args.out, name), "w") as f:
            json.dump(value, f, separators=(",", ":"))
            f.write("\n")
    print(f"{args.out}: {len(snap['notes'])} notes, {len(cases)} cases")


if __name__ == "__main__":
    main()
