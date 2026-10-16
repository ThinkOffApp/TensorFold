"""/v1/notes writes on a real tensorfold-native against LLWZ Python, under the model's tokenizer.

  PYTHONHASHSEED=0 python tools/notes/live.py LLWZ_DIR MODEL_DIR SERVER_BIN OUT_DIR [--stores l6-teach,...]

For each store (the 1,568-question set's: l6-teach and nights-day1..5 with the past, excl2 and past-excl2
variants, sweep-100..100000 plain) it builds the store in LLWZ's NoteStore with the server's intake
(live_intake.py), exports it, starts the server on that snapshot (port 18311, --prompt-cache-gib 0), and runs
SCRIPT both ways: over HTTP (a chat request's own statement included) and in Python. At checkpoints A, B and C
every question's block (as a chat request with "notes": true gets it) must equal Python's retrieve() byte for
byte, with the same ids, tokens and past flag, and the listing must equal Python's notes. Then the server is
restarted (snapshot and journal) and checkpoint C asked again, and Python's own export of the written store is
served from a fresh folder and asked again. Writes OUT_DIR/live-STORE.jsonl (every comparison) and prints a table.
Needs a Python with `tokenizers`; the server must be built from this branch. Standard library otherwise.
"""
import argparse
import hashlib
import http.client
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import live_intake  # noqa: E402

PORT = 18311
# a step's target: {"pick": "me"} the base's first current fact of "me", {"pick": "other"} the base's first current
# fact on a pair that holds another current note (else its last current fact), {"step": NAME} the note a step wrote
SCRIPT = [
    {"name": "green", "op": "add", "text": "My favourite colour is green."},
    {"name": "green2", "op": "add", "text": "my favourite  colour is GREEN"},
    {"name": "sister", "op": "add", "text": "My sister's favourite colour is purple.", "subject": "my sister"},
    {"name": "rex", "op": "add", "text": "My friend Ana's dog is called Rex.", "subject": "my friend Ana's dog"},
    {"name": "said", "op": "chat", "text": "I live in Helsinki now."},
    {"check": "A"},
    {"name": "red", "op": "change", "target": {"pick": "me"}, "text": "My favourite colour is red now."},
    {"name": "yellow", "op": "change", "target": {"step": "green"}, "text": "My favourite colour is yellow now."},
    {"name": "back", "op": "take_back", "target": {"pick": "other"}},
    {"name": "noyellow", "op": "take_back", "target": {"step": "yellow"},
     "text": "Yellow is not my favourite colour anymore."},
    {"name": "orange", "op": "change", "target": {"step": "noyellow"}, "text": "My favourite colour is orange."},
    {"name": "sister2", "op": "add", "text": "My sister's favourite colour is purple.", "subject": "my sister"},
    {"name": "walks", "op": "add", "text": "My brother likes long walks.", "subject": "my brother"},
    {"check": "B"},
    {"op": "erase", "target": {"step": "sister"}},
    {"name": "norex", "op": "take_back", "target": {"step": "rex"}, "text": "My friend Ana's dog is not called Rex any more."},
    {"op": "erase", "target": {"step": "rex"}},
    {"op": "erase", "target": {"step": "red"}},
    {"check": "C"},
]


def call(method, path, body=None, timeout=600):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=timeout)
    data = json.dumps(body).encode() if body is not None else None
    c.request(method, path, body=data, headers={"Content-Type": "application/json"} if data else {})
    r = c.getresponse()
    raw = r.read()
    c.close()
    return r.status, json.loads(raw) if raw else None


class Server:
    """tensorfold-native serve on PORT with --notes SNAP; started and stopped by this script alone."""

    def __init__(self, binary, model, snap, log):
        self.args = [binary, "serve", model, "--port", str(PORT), "--prompt-cache-gib", "0", "--context", "32768",
                     "--no-update-check", "--notes", snap]
        self.log = log
        self.proc = None

    def start(self):
        self.out = open(self.log, "a")
        self.proc = subprocess.Popen(self.args, stdout=self.out, stderr=subprocess.STDOUT)
        t0 = time.time()
        while time.time() - t0 < 600:
            if self.proc.poll() is not None:
                raise SystemExit(f"the server exited ({self.proc.returncode}); see {self.log}")
            try:
                if call("GET", "/health", timeout=5)[0] == 200:
                    return time.time() - t0
            except OSError:
                pass
            time.sleep(0.5)
        raise SystemExit("the server did not come up in 600 s")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            os.kill(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(120)
            except subprocess.TimeoutExpired:
                os.kill(self.proc.pid, signal.SIGKILL)
                self.proc.wait()
        self.out.close()


def engine_block(q, past=None, exclude=()):
    body = {"model": "m", "messages": [{"role": "user", "content": q}], "max_tokens": 1, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}, "notes": True, "notes_echo": True,
            "notes_write": False}
    if past is not None:
        body["notes_past"] = past
    if exclude:
        body["notes_exclude"] = list(exclude)
    st, r = call("POST", "/v1/chat/completions", body)
    if st != 200:
        raise SystemExit(f"chat failed {st}: {r}")
    return r["notes"]


def checkpoint(ns, owner, S, variants, f, name, base):
    """Every question (and variant) asked of the server and of Python; the listing compared. (equal, asked, listing
    equal, moved): moved counts the server's blocks that differ from the store's before any write (the control)."""
    jobs = [("plain", None, False)]
    if variants:
        jobs += [("past", True, False), ("excl2", None, True), ("past-excl2", True, True)]
    eq = n = moved = 0
    for q in S["questions"]:
        for vname, past, ex in jobs:
            exclude = ns.retrieve(owner, q["text"], past=past)["ids"][:2] if ex else []
            py = ns.retrieve(owner, q["text"], past=past, exclude=exclude)
            en = engine_block(q["text"], past, exclude)
            row = {"check": name, "variant": vname, "qid": q["qid"], "block_equal": (en.get("block") or "") == py["block"],
                   "ids_equal": en["ids"] == py["ids"], "tokens_equal": en["tokens"] == py["tokens"],
                   "past_equal": en["past"] == py["past"], "ids": en["ids"], "python_ids": py["ids"],
                   "block_sha256": en["block_sha256"], "retrieved": bool(py["block"])}
            row["equal"] = all(row[k] for k in ("block_equal", "ids_equal", "tokens_equal", "past_equal"))
            row["moved"] = (en.get("block") or "") != base.get((q["qid"], vname), "")
            moved += row["moved"]
            eq += row["equal"]
            n += 1
            f.write(json.dumps(row) + "\n")
    st, listed = call("GET", "/v1/notes?history=1")
    O = ns.owner(owner)
    mine = [(i, x["version"], x["state"], ns.line(O, i)) for i, x in sorted(O.notes.items())]
    theirs = [(x["id"], x["version"], x["state"], x["line"]) for x in listed["data"]]
    f.write(json.dumps({"check": name, "listing_equal": mine == theirs, "notes": len(mine)}) + "\n")
    return eq, n, mine == theirs, moved


def build(nm, S, store_name, tok, Live, sizes_cache):
    """The base store as export.py builds it, in LLWZ's NoteStore with the server's intake for later writes."""
    phase = lambda name: next(p for p in S["phases"] if p["name"] == name)  # noqa: E731
    if store_name == "l6-teach":
        ns, _ = nm.set_store(S, phase("teach")["store"], tok, store=Live(tok, schema=S["schema"]))
        return ns, "user"
    if store_name.startswith("nights-"):
        ns, _ = nm.set_store(S, phase(store_name.split("-", 1)[1])["store"], tok, store=Live(tok, schema=S["schema"]))
        return ns, "user"
    import notes_zig_golden as golden  # noqa: E402
    size = int(store_name.split("-")[1])
    for _s, ns, _t in golden.grow(S, tok, [size], store=Live(tok, schema=S["schema"])):
        return ns, "u0"


def run_store(a, nm, nx, intake, L, tok, S, store_name, variants):
    Live = live_intake.make(nm, intake)
    t0 = time.time()
    ns, owner = build(nm, S, store_name, tok, Live, {})
    built = time.time() - t0
    d = os.path.join(a.out, store_name)
    os.makedirs(d, exist_ok=True)
    if os.path.exists(os.path.join(d, "base.snap.json.journal")):
        os.remove(os.path.join(d, "base.snap.json.journal"))  # an earlier run's writes
    snap, _v = nx.snapshot(ns, owner, meta={"store": store_name})
    path = os.path.join(d, "base.snap.json")
    nx.write(snap, path)
    base_told = max(n["told"] for n in snap["notes"])
    today = L.tick(time.strftime("%Y-%m-%d"))
    srv = Server(a.server, a.model, path, os.path.join(d, "server.log"))
    load_s = srv.start()
    out = open(os.path.join(a.out, f"live-{store_name}.jsonl"), "w")
    tally, src, n, bad_replies = [], {}, 0, 0
    O = lambda: ns.owner(owner)  # noqa: E731
    base_ids = sorted(i for i, x in O().notes.items() if not x["lesson"].get("http"))
    cur = [i for i in base_ids if O().notes[i]["state"] == nm.CURRENT and O().notes[i]["kind"] == nm.FACT]
    pick_me = next(i for i in cur if O().notes[i]["entity"] == "me")
    pairs = {}
    for i in cur:
        pairs.setdefault((O().notes[i]["entity"], O().notes[i]["attribute"]), []).append(i)
    pick_other = next((i for i in cur if i != pick_me and len(pairs[(O().notes[i]["entity"], O().notes[i]["attribute"])]) > 1),
                      [i for i in cur if i != pick_me][-1])
    base = {}
    for q in S["questions"]:
        for vname, past, ex in [("plain", None, False)] + ([("past", True, False), ("excl2", None, True), ("past-excl2", True, True)] if variants else []):
            exclude = ns.retrieve(owner, q["text"], past=past)["ids"][:2] if ex else []
            base[(q["qid"], vname)] = ns.retrieve(owner, q["text"], past=past, exclude=exclude)["block"]
    try:
        for st in SCRIPT:
            if "check" in st:
                tally.append((st["check"], *checkpoint(ns, owner, S, variants, out, st["check"], base)))
                continue
            t = st.get("target")
            if t and "pick" in t:
                target = {"note": pick_me if t["pick"] == "me" else pick_other}
            elif t:
                target = {"source": src[t["step"]]}
            else:
                target = None
            ns._O = O()
            tid = ns._target(target) if target else None
            if st["op"] == "erase":
                code, r = call("DELETE", f"/v1/notes/{tid}?erase=true")
                removed, moved = ns.erase(owner, tid)
                ok = code == 200 and r["removed"] == removed and [[m["from"], m["to"]] for m in r["renumbered"]] == [list(m) for m in moved]
                bad_replies += not ok
                out.write(json.dumps({"step": "erase", "ok": ok, "server": r, "python": [removed, moved]}) + "\n")
                continue
            n += 1
            told = ns.told_next(owner, today, base_told)
            text = st.get("text") or live_intake.DEFAULT_TAKEBACK
            if st["op"] == "chat":
                body = {"model": "m", "messages": [{"role": "user", "content": text}], "max_tokens": 1, "temperature": 0,
                        "chat_template_kwargs": {"enable_thinking": False}, "notes": True}
                code, r = call("POST", "/v1/chat/completions", body)
                w = r["notes"]["write"]
                server = {"verdict": w.get("verdict"), "id": w.get("id"), "source": w.get("source")}
                op = "add"
            else:
                op = st["op"]
                if op == "add":
                    code, r = call("POST", "/v1/notes", {"text": text, **({"subject": st["subject"]} if "subject" in st else {})})
                elif op == "change":
                    code, r = call("POST", f"/v1/notes/{tid}", {"text": text})
                else:
                    code, r = call("DELETE", f"/v1/notes/{tid}", {"text": text} if st.get("text") else None)
                server = {"verdict": r.get("verdict"), "id": r.get("id"), "source": r.get("source"), "told": r.get("told")}
            e, same = ns.http_write(owner, op, text, told, server["source"], st.get("subject", "me"), target)
            src[st["name"]] = server["source"]
            shown = e["note"] or (same[0] if same else None)
            python = {"verdict": e["verdict"], "id": shown, "source": server["source"], "told": told}
            ok = all(server.get(k, python[k]) == python[k] for k in python) and server["source"] == f"w{n}"
            bad_replies += not ok
            out.write(json.dumps({"step": st["name"], "ok": ok, "server": server, "python": python}) + "\n")
        # restart: the snapshot and the journal again
        srv.stop()
        srv.start()
        tally.append(("C after restart", *checkpoint(ns, owner, S, variants, out, "C after restart", base)))
        srv.stop()
        # Python's own export of the written store, served from a fresh folder (no journal)
        snap2, _ = nx.snapshot(ns, owner, meta={"store": store_name, "after": "SCRIPT"})
        d2 = os.path.join(d, "exported")
        os.makedirs(d2, exist_ok=True)
        p2 = os.path.join(d2, "after.snap.json")
        nx.write(snap2, p2)
        if os.path.exists(p2 + ".journal"):
            os.remove(p2 + ".journal")
        srv = Server(a.server, a.model, p2, os.path.join(d, "server-exported.log"))
        srv.start()
        tally.append(("C from Python's export", *checkpoint(ns, owner, S, variants, out, "C from Python's export", base)))
    finally:
        srv.stop()
        out.close()
    return {"store": store_name, "notes": len(snap["notes"]), "built_s": round(built, 1), "load_s": round(load_s, 1),
            "replies_differing": bad_replies, "checks": tally}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("llwz")
    ap.add_argument("model")
    ap.add_argument("server")
    ap.add_argument("out")
    ap.add_argument("--stores", default="l6-teach,nights-day1,nights-day2,nights-day3,nights-day4,nights-day5,"
                                        "sweep-100,sweep-1000,sweep-10000,sweep-100000")
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.llwz, "zengine"))
    import notes as nm  # noqa: E402
    import notes_export as nx  # noqa: E402
    import intake  # noqa: E402
    import lwlogic as L  # noqa: E402
    os.makedirs(a.out, exist_ok=True)
    tok = nm.load_tokenizer(os.path.join(a.model, "tokenizer.json"))
    L6 = nm.load_set(os.path.join(a.llwz, "examples", "L6-seed1.json"))
    NI = nm.load_set(os.path.join(a.llwz, "examples", "nights", "L6-seed1-nights.json"))
    results = []
    for name in a.stores.split(","):
        S = NI if name.startswith("nights-") else L6
        r = run_store(a, nm, nx, intake, L, tok, S, name, variants=not name.startswith("sweep"))
        results.append(r)
        print(json.dumps(r), flush=True)
    with open(os.path.join(a.out, "live-summary.json"), "w") as f:
        json.dump(results, f, indent=1)
    total = {}
    for r in results:
        for name, eq, asked, listing, moved in r["checks"]:
            t = total.setdefault(name, [0, 0, 0, 0, 0])
            t[0] += eq
            t[1] += asked
            t[2] += listing
            t[3] += 1
            t[4] += moved
    for name, (eq, asked, listing, stores, moved) in total.items():
        print(f"{name}: {eq} of {asked} blocks equal; listing equal in {listing} of {stores} stores; {moved} blocks"
              " differ from the store's before the writes")
    print("replies differing from Python:", sum(r["replies_differing"] for r in results))


if __name__ == "__main__":
    main()
