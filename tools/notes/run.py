"""Equivalence and timing of --notes against LLWZ Python's retrieve(), on a running tensorfold-native server.

  python3 tools/notes/run.py compare URL REF.json OUT.jsonl [--max-tokens 160] [--client-ref REF2.json] [--perturb]
  python3 tools/notes/run.py bench URL REF.json OUT.jsonl [--reps 4] [--max-tokens 8] [--warmup 6]
  python3 tools/notes/run.py tokens URL REF.json TOKENIZER_JSON

compare: each question twice at temperature 0, thinking off: (engine) the user message with "notes": true (and the
reference's notes_past and notes_exclude, when it forced them), and (client) Python's block for it sent as the first
system message (none when Python retrieved nothing). The engine's block, ids, tokens and past flag must equal
Python's, and the two replies must be the same tokens (the server's token_sha, completion and prompt token counts,
and the text). --client-ref takes the client's blocks from another reference; --perturb drops the client block's
last line: both are negative controls, which must make it differ.
bench: per question and repetition, (a) no notes, then (b) Python's block sent by the client and (c) "notes": true,
each after an (a) request (a separator, not counted), (b) first in even repetitions and (c) first in odd ones,
streamed: the server's own time_to_first_token, prefill seconds, prompt and cached tokens and the notes timings, with
the client's time to the first content byte beside them. tokens: /tokenize ids of each question and block against
the tokenizer.json read with the `tokenizers` package. Standard library only (except tokens).
"""
import argparse
import http.client
import json
import sys
import time
import urllib.parse


def post(url, path, body, stream=False, timeout=600):
    u = urllib.parse.urlparse(url)
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=timeout)
    data = json.dumps(body).encode()
    t0 = time.perf_counter()
    c.request("POST", path, body=data, headers={"Content-Type": "application/json"})
    r = c.getresponse()
    if not stream:
        raw = r.read()
        c.close()
        return r.status, json.loads(raw), time.perf_counter() - t0, None
    first, last, content = None, None, []
    while True:
        line = r.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith(b"data: ") or line == b"data: [DONE]":
            continue
        ev = json.loads(line[6:])
        for ch in ev.get("choices") or []:
            d = ch.get("delta") or {}
            if (d.get("content") or d.get("reasoning_content")) and first is None:
                first = time.perf_counter() - t0
            content.append(d.get("content") or "")
        if "tensorfold" in ev or "usage" in ev:
            last = dict(last or {}, **{k: ev[k] for k in ("tensorfold", "usage", "notes") if k in ev})
    c.close()
    out = dict(last or {})
    out["content"] = "".join(content)
    return r.status, out, time.perf_counter() - t0, first


def chat(question, block=None, **extra):
    msgs = ([{"role": "system", "content": block}] if block else []) + [{"role": "user", "content": question}]
    body = {"model": "m", "messages": msgs, "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}
    body.update(extra)
    return body


def reply_of(d):
    rt = d.get("tensorfold") or {}
    msg = (d.get("choices") or [{}])[0].get("message") or {}
    return {"content": msg.get("content") if msg else d.get("content"), "token_sha": rt.get("token_sha"),
            "completion_tokens": (d.get("usage") or {}).get("completion_tokens"),
            "prompt_tokens": (d.get("usage") or {}).get("prompt_tokens")}


def answer(r):
    """The reply's tokens as the server reports them: its token SHA, their count and the text."""
    return (r["token_sha"], r["completion_tokens"], r["content"])


def compare(a):
    ref = json.load(open(a.ref))
    client = json.load(open(a.client_ref)) if a.client_ref else ref
    cblocks = {q["qid"]: q["block"] for q in client["questions"]}
    tally = {"questions": 0, "block_equal": 0, "ids_equal": 0, "tokens_equal": 0, "past_equal": 0, "reply_equal": 0,
             "prompt_tokens_equal": 0, "with_block": 0, "both_equal": 0}
    with open(a.out, "w") as f:
        for q in ref["questions"]:
            asked = {"notes_past": q["past_given"]} if q.get("past_given") is not None else {}
            if q.get("exclude"):
                asked["notes_exclude"] = q["exclude"]
            st, e, _, _ = post(a.url, "/v1/chat/completions", chat(q["question"], max_tokens=a.max_tokens, notes=True,
                                                                   notes_echo=True, **asked))
            if st != 200:
                raise SystemExit(f"engine request failed {st}: {e}")
            cb = cblocks[q["qid"]]
            if a.perturb and cb:
                cb = cb.rsplit("\n", 1)[0]
            st, c, _, _ = post(a.url, "/v1/chat/completions", chat(q["question"], cb or None, max_tokens=a.max_tokens))
            if st != 200:
                raise SystemExit(f"client request failed {st}: {c}")
            n = e["notes"]
            re_, rc = reply_of(e), reply_of(c)
            row = {"qid": q["qid"], "block_equal": (n.get("block") or "") == q["block"], "ids_equal": n["ids"] == q["ids"],
                   "tokens_equal": n["tokens"] == q["tokens"], "past_equal": n["past"] == q["past"],
                   "reply_equal": answer(re_) == answer(rc), "prompt_tokens_equal": re_["prompt_tokens"] == rc["prompt_tokens"],
                   "engine": {"ids": n["ids"], "tokens": n["tokens"], "past": n["past"], "lookup_us": n["lookup_us"],
                              "total_us": n["total_us"], "block_sha256": n["block_sha256"], **re_},
                   "python": {"ids": q["ids"], "tokens": q["tokens"], "past": q["past"]}, "client": rc}
            tally["questions"] += 1
            tally["with_block"] += bool(q["block"])
            for k in ("block_equal", "ids_equal", "tokens_equal", "past_equal", "reply_equal", "prompt_tokens_equal"):
                tally[k] += row[k]
            tally["both_equal"] += row["block_equal"] and row["reply_equal"] and row["prompt_tokens_equal"]
            f.write(json.dumps(row) + "\n")
    print(json.dumps({"ref": a.ref, "client_ref": a.client_ref, "perturb": a.perturb, **tally}))


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100
    lo = int(k)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (k - lo)


def bench(a):
    ref = json.load(open(a.ref))
    qs = ref["questions"]
    arms = {"a": lambda q: chat(q["question"], max_tokens=a.max_tokens, stream=True),
            "b": lambda q: chat(q["question"], q["block"] or None, max_tokens=a.max_tokens, stream=True),
            "c": lambda q: chat(q["question"], max_tokens=a.max_tokens, stream=True, notes=True)}
    for q in qs[:a.warmup]:
        for arm in arms.values():
            post(a.url, "/v1/chat/completions", arm(q), stream=True)
    with open(a.out, "w") as f:
        for rep in range(a.reps):
            for q in qs:
                # a short request before each long one: a long prefill right after another long one runs slower
                for slot, name in enumerate("abac" if rep % 2 == 0 else "acab"):
                    st, d, wall, first = post(a.url, "/v1/chat/completions", arms[name](q), stream=True)
                    if st != 200:
                        raise SystemExit(f"{name} request failed {st}: {d}")
                    rt, us, n = d.get("tensorfold") or {}, d.get("usage") or {}, d.get("notes")
                    f.write(json.dumps({"rep": rep, "qid": q["qid"], "arm": name, "slot": slot, "separator": slot == 2,
                                        "ttft_s": rt.get("time_to_first_token"),
                                        "prefill_s": rt.get("prefill_seconds"), "prompt_tokens": us.get("prompt_tokens"),
                                        "cached_tokens": (us.get("prompt_tokens_details") or {}).get("cached_tokens"),
                                        "completion_tokens": us.get("completion_tokens"), "client_first_s": first,
                                        "client_wall_s": wall, "notes": n,
                                        "python_lookup_us": q["lookup_us"] if name == "b" else None}) + "\n")
                    time.sleep(a.gap)
    print(json.dumps({"ref": a.ref, "out": a.out, "reps": a.reps, "questions": len(qs)}))


def tokens(a):
    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(a.tokenizer)
    ref = json.load(open(a.ref))
    same = 0
    for q in ref["questions"]:
        st, d, _, _ = post(a.url, "/tokenize", {"prompt": q["question"], "add_special_tokens": False})
        same += st == 200 and d["tokens"] == tok.encode(q["question"], add_special_tokens=False).ids
        if q["block"]:
            st, d, _, _ = post(a.url, "/tokenize", {"prompt": q["block"], "add_special_tokens": False})
            same += st == 200 and d["tokens"] == tok.encode(q["block"], add_special_tokens=False).ids
    texts = len(ref["questions"]) + sum(1 for q in ref["questions"] if q["block"])
    print(json.dumps({"ref": a.ref, "texts": texts, "ids_equal": same}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("url")
    c.add_argument("ref")
    c.add_argument("out")
    c.add_argument("--max-tokens", type=int, default=160)
    c.add_argument("--client-ref")
    c.add_argument("--perturb", action="store_true")
    b = sub.add_parser("bench")
    b.add_argument("url")
    b.add_argument("ref")
    b.add_argument("out")
    b.add_argument("--reps", type=int, default=4)
    b.add_argument("--max-tokens", type=int, default=8)
    b.add_argument("--warmup", type=int, default=6)
    b.add_argument("--gap", type=float, default=0.05)
    t = sub.add_parser("tokens")
    t.add_argument("url")
    t.add_argument("ref")
    t.add_argument("tokenizer")
    a = ap.parse_args()
    {"compare": compare, "bench": bench, "tokens": tokens}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
