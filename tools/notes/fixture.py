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
sys.path.insert(0, HERE)
import live_intake  # noqa: E402  (the server's intake on LLWZ's NoteStore)

# /v1/notes writes on the teach store, run by Python here and by the server's test: base notes by id, written ones by
# the write that made them (an erase renumbers ids), and checkpoints where every case and the listing are compared
SCRIPT = [
    {"op": "add", "text": "My favourite colour is green."},
    {"op": "add", "text": "my favourite  colour is GREEN"},
    {"op": "add", "text": "My sister's favourite colour is purple.", "subject": "my sister"},
    {"op": "add", "text": "My friend Ana's dog is called Rex.", "subject": "my friend Ana's dog"},
    {"check": "A"},
    {"op": "change", "target": {"note": 26}, "text": "My favourite colour is red now."},
    {"op": "change", "target": {"write": "w1"}, "text": "My favourite colour is yellow now."},
    {"op": "take_back", "target": {"note": 28}},
    {"op": "take_back", "target": {"write": "w6"}, "text": "Yellow is not my favourite colour anymore."},
    {"op": "change", "target": {"write": "w8"}, "text": "My favourite colour is orange."},
    {"op": "add", "text": "My sister's favourite colour is purple.", "subject": "my sister"},
    {"op": "add", "text": "My brother likes long walks.", "subject": "my brother"},
    {"check": "B"},
    {"op": "erase", "target": {"write": "w3"}},
    {"op": "take_back", "target": {"write": "w4"}, "text": "My friend Ana's dog is not called Rex any more."},
    {"op": "erase", "target": {"write": "w4"}},
    {"op": "erase", "target": {"write": "w5"}},
    {"check": "C"},
]
TODAY = "2026-10-16"
NORM_TEXTS = ["My favourite colour is green.", "  my   favourite\tcolour\nis green!? ", "My cat\u2019s eyes \u2014 green.",
              "\u201cHi\u201d\u3000there...", "\u00c9mile is here.\u00a0", "?!.", "a\u2028b\u0085c\u1680d\u202fe.",
              "Tom \u2013 and Jerry!", "\u00e9t\u00e9 \u00c9T\u00c9"]
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
    writes = live_script(nm, tok, S, teach, snap, cases)
    os.makedirs(args.out, exist_ok=True)
    for name, value in (("l6_bytes_snapshot.json", snap), ("l6_bytes_cases.json", cases), ("l6_bytes_writes.json", writes)):
        with open(os.path.join(args.out, name), "w") as f:
            json.dump(value, f, separators=(",", ":"))
            f.write("\n")
    print(f"{args.out}: {len(snap['notes'])} notes, {len(cases)} cases")


def live_script(nm, tok, S, teach, snap, cases):
    """SCRIPT through LLWZ's NoteStore with the server's intake: each write's reply, and at each checkpoint every
    case's retrieve() and the notes; also intake.norm (ASCII lowered) of NORM_TEXTS."""
    import intake  # noqa: E402  (LLWZ's, beside notes.py)
    import lwlogic as L  # noqa: E402
    Live = live_intake.make(nm, intake)
    ns, _w = nm.set_store(S, teach["store"], tok, store=Live(tok, schema=S["schema"]))
    base_told = max(n["told"] for n in snap["notes"])
    today = L.tick(TODAY)
    O = lambda: ns.owner("user")  # noqa: E731
    steps, n = [], 0
    for st in SCRIPT:
        if "check" in st:
            got = []
            for c in cases:
                r = ns.retrieve("user", c["question"], cap=c["cap"], past=c["past"], exclude=c["exclude"])
                got.append({"ids": r["ids"], "tokens": r["tokens"], "candidates": r["candidates"], "past_read": r["past"],
                            "block_sha256": hashlib.sha256(r["block"].encode()).hexdigest() if r["block"] else None})
            notes = [{"id": i, "version": x["version"], "state": x["state"], "kind": x["kind"], "subject": x["entity"],
                      "text": x["text"], "line": ns.line(O(), i), "source": x["source"] if x["lesson"].get("http") else None}
                     for i, x in sorted(O().notes.items())]
            steps.append({"check": st["check"], "cases": got, "notes": notes})
            continue
        t = st.get("target")
        if t and "write" in t:
            t = {"source": t["write"]}
        if st["op"] == "erase":
            ns._O = O()
            note = ns._target(t)
            removed, moved = ns.erase("user", note)
            steps.append(dict(st, want={"note": note, "removed": removed, "moved": [list(m) for m in moved]}))
            continue
        n += 1
        src = f"w{n}"
        told = ns.told_next("user", today, base_told)
        e, same = ns.http_write("user", st["op"], st.get("text") or live_intake.DEFAULT_TAKEBACK, told, src,
                                st.get("subject", "me"), t)
        shown = e["note"] or (same[0] if same else None)
        x = O().notes.get(shown) if shown else None
        want = {"source": src, "told": told, "verdict": e["verdict"], "id": shown, "version": x["version"] if x else None,
                "state": x["state"] if x else None, "retired": e["superseded"] or e["tombstoned"], "same_as": same}
        steps.append(dict(st, want=want))
    return {"today": TODAY, "steps": steps,
            "norm": [[t, live_intake.lnorm(intake, t)] for t in NORM_TEXTS]}


if __name__ == "__main__":
    main()
