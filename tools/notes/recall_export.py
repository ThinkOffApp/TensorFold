"""The paper's recall sets as note snapshots, with the notes each question's right answer depends on.

  PYTHONDONTWRITEBYTECODE=1 PYTHONHASHSEED=0 python tools/notes/recall_export.py LLWZ_DIR TOKENIZER_JSON OUT_DIR

For each set (levels 1 to 6: examples/L1-seed1 to L5-seed1 and L6-seed1 to L6-seed3; level 7: examples/L7-seed1) and
each phase LLWZ's `notes.py recall` measures (recall_phases), the phase's store as recall_records builds it, written
as SET.PHASE.snap.json (zengine/notes_export.py's snapshot), and SET.PHASE.ref.json: per question its text, the
past flag, the needed note ids (needed_notes) and Python retrieve()'s ids, tokens, candidates and block at cap 512,
so notes-recall can check the engine's lookup against Python's and count recall at the cap. Needs a Python with the
`tokenizers` package; reads LLWZ, writes nothing there.
"""
import json
import os
import sys

L16 = ["L1-seed1", "L2-seed1", "L3-seed1", "L4-seed1", "L5-seed1", "L6-seed1", "L6-seed2", "L6-seed3"]
L7 = ["L7-seed1"]


def main():
    llwz, tokenizer, out = sys.argv[1:4]
    sys.path.insert(0, os.path.join(llwz, "zengine"))
    import notes as nm  # noqa: E402  (LLWZ's)
    import notes_export as nx  # noqa: E402
    os.makedirs(out, exist_ok=True)
    tok = nm.load_tokenizer(tokenizer)
    index = []
    for group, names in (("L1-L6", L16), ("L7", L7)):
        for name in names:
            S = nm.load_set(os.path.join(llwz, "examples", name + ".json"))
            for ph in nm.recall_phases(S):
                pstore = next(p["store"] for p in S["phases"] if p["name"] == ph)
                lessons = nm.store_lessons(S, pstore)
                ns, _w = nm.set_store(S, pstore, tok)
                snap, _v = nx.snapshot(ns, "user", meta={"set": S["id"], "phase": ph})
                stem = f"{name}.{ph}"
                nx.write(snap, os.path.join(out, stem + ".snap.json"))
                qs = []
                for q in S["questions"]:
                    r = ns.retrieve("user", q["text"])
                    need = nm.needed_notes(ns, "user", S, lessons, q)
                    qs.append({"qid": q["qid"], "question": q["text"], "type": q["type"], "past": r["past"], "need": need,
                               "ids": r["ids"], "tokens": r["tokens"], "candidates": r["candidates"], "block": r["block"]})
                with open(os.path.join(out, stem + ".ref.json"), "w") as f:
                    json.dump({"set": S["id"], "phase": ph, "group": group, "notes": len(snap["notes"]), "questions": qs}, f)
                need_n = sum(1 for q in qs if q["need"])
                hit = sum(1 for q in qs if q["need"] and set(q["need"]) <= set(q["ids"]))
                index.append({"stem": stem, "group": group, "questions": len(qs), "with_needed": need_n, "recall": hit})
                print(f"{stem}: {len(snap['notes'])} notes, {len(qs)} questions, recall {hit}/{need_n}", flush=True)
    with open(os.path.join(out, "index.json"), "w") as f:
        json.dump(index, f, indent=1)
    for group in ("L1-L6", "L7"):
        rows = [x for x in index if x["group"] == group]
        print(f"{group}: {sum(x['questions'] for x in rows)} questions, recall {sum(x['recall'] for x in rows)}/"
              f"{sum(x['with_needed'] for x in rows)}")


if __name__ == "__main__":
    main()
