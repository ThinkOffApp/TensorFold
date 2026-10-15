"""Note snapshots for --notes and LLWZ Python's retrieve() answers for each question, under the model's tokenizer.

  python tools/notes/export.py LLWZ_DIR TOKENIZER_JSON OUT_DIR [--sizes 100,1000,10000,100000] [--only NAME,...]

Writes NAME.snap.json (zengine/notes_export.py's snapshot) and NAME.ref.json (per question: the text, the past flag,
the note ids, the tokens, the candidates, the block and Python's own lookup time) for the stores below; for l6-teach
and the nights days also NAME.past, NAME.excl2 and NAME.past-excl2 (past forced, the first two ids excluded, both):
  l6-teach            examples/L6-seed1.json, phase teach (owner "user")
  nights-day1..day5   examples/nights/L6-seed1-nights.json, each day phase
  l6-delB             L6-seed1 phase del-B: a wrong snapshot for the teach questions (negative control)
  l6-teach-hopnone    L6-seed1 teach with the hop off: a wrong snapshot by its settings (negative control)
  sweep-N             notes.py's sweep stores (the teach notes of owner u0, then distractors, seed 1) at each size
Needs a Python with the `tokenizers` package; run with PYTHONHASHSEED=0 so Python's float-order ties are fixed.
"""
import argparse
import json
import os
import sys
import time


def refs(ns, owner, S, past=None, exclude_first=0):
    """retrieve() for each question; with `past` forced, and with the first `exclude_first` ids it gives excluded."""
    out = []
    for q in S["questions"]:
        ex = ns.retrieve(owner, q["text"], past=past)["ids"][:exclude_first] if exclude_first else []
        r = ns.retrieve(owner, q["text"], past=past, exclude=ex)
        out.append({"qid": q["qid"], "question": q["text"], "past": r["past"], "ids": r["ids"], "tokens": r["tokens"],
                    "candidates": r["candidates"], "block": r["block"], "lookup_us": r["lookup_us"],
                    "past_given": past, "exclude": ex})
    return out


def save(nx, out_dir, name, ns, owner, S, meta, log, variants=False):
    t0 = time.time()
    snap, _v = nx.snapshot(ns, owner, meta=meta)
    nx.write(snap, os.path.join(out_dir, name + ".snap.json"))
    rs = refs(ns, owner, S)
    head = {"name": name, "owner": owner, "meta": meta, "notes": len(snap["notes"]), "current": snap["n"]["current"],
            "settings": snap["settings"]}
    with open(os.path.join(out_dir, name + ".ref.json"), "w") as f:
        json.dump(dict(head, questions=rs), f)
    if variants:   # the past view and exclude, as a request's notes_past and notes_exclude ask for them
        for suffix, kw in ((".past", {"past": True}), (".excl2", {"exclude_first": 2}),
                           (".past-excl2", {"past": True, "exclude_first": 2})):
            with open(os.path.join(out_dir, name + suffix + ".ref.json"), "w") as f:
                json.dump(dict(head, questions=refs(ns, owner, S, **kw), variant=kw), f)
    log(f"{name}: {len(snap['notes'])} notes ({snap['n']['current']} current), {sum(1 for r in rs if r['block'])} of "
        f"{len(rs)} questions retrieve notes, exported in {time.time() - t0:.1f} s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("llwz")
    ap.add_argument("tokenizer")
    ap.add_argument("out")
    ap.add_argument("--sizes", default="100,1000,10000,100000")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.llwz, "zengine"))
    import notes as nm  # noqa: E402  (LLWZ's)
    import notes_export as nx  # noqa: E402
    import notes_zig_golden as golden  # noqa: E402
    only = set(x for x in a.only.split(",") if x)
    want = lambda name: not only or name in only or name.split("-")[0] in only  # noqa: E731
    os.makedirs(a.out, exist_ok=True)
    log = lambda m: print(m, flush=True)  # noqa: E731
    tok = nm.load_tokenizer(a.tokenizer)
    L6 = nm.load_set(os.path.join(a.llwz, "examples", "L6-seed1.json"))
    NI = nm.load_set(os.path.join(a.llwz, "examples", "nights", "L6-seed1-nights.json"))
    phase = lambda S, name: next(p for p in S["phases"] if p["name"] == name)  # noqa: E731
    if want("l6-teach"):
        ns, _w = nm.set_store(L6, phase(L6, "teach")["store"], tok)
        save(nx, a.out, "l6-teach", ns, "user", L6, {"set": L6["id"], "phase": "teach"}, log, variants=True)
    if want("l6-delB"):
        ns, _w = nm.set_store(L6, phase(L6, "del-B")["store"], tok)
        save(nx, a.out, "l6-delB", ns, "user", L6, {"set": L6["id"], "phase": "del-B"}, log)
    if want("l6-teach-hopnone"):
        ns, _w = nm.set_store(L6, phase(L6, "teach")["store"], tok, config={"hop": "none"})
        save(nx, a.out, "l6-teach-hopnone", ns, "user", L6, {"set": L6["id"], "phase": "teach", "hop": "none"}, log)
    for ph in NI["phases"]:
        name = "nights-" + ph["name"]
        if ph["name"].startswith("day") and want(name):
            ns, _w = nm.set_store(NI, ph["store"], tok)
            save(nx, a.out, name, ns, "user", NI, {"set": NI["id"], "phase": ph["name"]}, log, variants=True)
    sizes = [int(x) for x in a.sizes.split(",") if x]
    if sizes and want("sweep"):
        for size, ns, secs in golden.grow(L6, tok, sizes):
            log(f"sweep-{size}: grown in {secs:.1f} s")
            save(nx, a.out, f"sweep-{size}", ns, "u0", L6, {"set": L6["id"], "sweep": size, "seed": 1}, log)


if __name__ == "__main__":
    main()
