"""Tables of tools/notes/run.py bench files: time to first token, prefill tokens and the notes' own times, per arm.

  python3 tools/notes/report.py DATA_DIR RUNS_DIR 100 1000 10000 100000

Reads RUNS_DIR/bench-sweep-N.jsonl and DATA_DIR/sweep-N.ref.json (docs/notes-in-engine holds both, compacted). Each figure is first the median of a question's
repetitions, then the median (p50) or p95 over the questions. (c)'s time to first token with the lookup adds the
server's notes total (question tokens, lookup, fit and the second normalize) to its time_to_first_token, which starts
after the lookup. It also checks every (c) reply's note ids and block SHA-256 against Python's for that question.
"""
import collections
import hashlib
import json
import os
import statistics
import sys


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * p / 100
    lo = int(k)
    return xs[lo] + (xs[min(lo + 1, len(xs) - 1)] - xs[lo]) * (k - lo)


def per_q(rows, f):
    by = collections.defaultdict(list)
    for r in rows:
        v = f(r)
        if v is not None:
            by[r["qid"]].append(v)
    return [statistics.median(v) for v in by.values()]


def same(n, q):
    """A (c) reply's notes against Python's: its ids and block SHA-256 (a compacted receipt keeps the verdict)."""
    if "same_as_python" in n:
        return n["same_as_python"]
    sha = hashlib.sha256(q["block"].encode()).hexdigest() if q["block"] else None
    return n["ids"] == q["ids"] and n["block_sha256"] == sha


def main():
    data, runs, sizes = sys.argv[1], sys.argv[2], [int(x) for x in sys.argv[3:]]
    ttft, tokens, inner, checks = [], [], [], []
    for n in sizes:
        ref = json.load(open(os.path.join(data, f"sweep-{n}.ref.json")))
        py = {q["qid"]: q for q in ref["questions"]}
        rows = [r for r in map(json.loads, open(os.path.join(runs, f"bench-sweep-{n}.jsonl"))) if not r.get("separator")]
        arm = {k: [r for r in rows if r["arm"] == k] for k in "abc"}
        cached = max(r["cached_tokens"] or 0 for r in rows)
        bad = sum(1 for r in arm["c"] if not same(r["notes"], py[r["qid"]]))
        checks.append(f"| {n:,} | {ref['notes']:,} | {ref['current']:,} | {len(arm['c'])} | {len(arm['c']) - bad} | {cached} |")
        for k, label in (("a", "(a) no notes"), ("b", "(b) notes sent by the client"), ("c", "(c) notes looked up in the engine")):
            t = per_q(arm[k], lambda r: r["ttft_s"] * 1e3)
            cf = per_q(arm[k], lambda r: r["client_first_s"] * 1e3 if r["client_first_s"] else None)
            row = f"| {n:,} | {label} | {pct(t, 50):.1f} | {pct(t, 95):.1f} |"
            if k == "c":
                t2 = per_q(arm[k], lambda r: r["ttft_s"] * 1e3 + r["notes"]["total_us"] / 1e3)
                row += f" {pct(t2, 50):.1f} | {pct(t2, 95):.1f} |"
            else:
                row += " | |"
            row += f" {pct(cf, 50):.1f} | {pct(cf, 95):.1f} |"
            ttft.append(row)
            first = [r for r in arm[k] if r["rep"] == 0]
            pt = [r["prompt_tokens"] for r in first]
            tokens.append(f"| {n:,} | {label} | {pct(pt, 50):.0f} | {pct(pt, 95):.0f} | {sum(pt):,} | {len(pt)} |")
        c = arm["c"]
        cells = []
        for key in ("tokenize_us", "lookup_us", "fit_us", "total_us"):
            v = per_q(c, lambda r, key=key: r["notes"][key])
            cells.append(f"{pct(v, 50):.1f} / {pct(v, 95):.1f}")
        pyl = [q["lookup_us"] for q in ref["questions"]]
        cand = per_q(c, lambda r: r["notes"]["candidates"])
        inner.append(f"| {n:,} | " + " | ".join(cells) + f" | {pct(pyl, 50):,.0f} / {pct(pyl, 95):,.0f} | "
                     f"{pct(cand, 50):,.0f} / {pct(cand, 95):,.0f} |")
    print("Time to first token, ms (p50 | p95 over the questions, each the median of its repetitions):\n")
    print("| Notes in store | Arm | Server TTFT p50 | p95 | TTFT + lookup p50 | p95 | Client first byte p50 | p95 |")
    print("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    print("\n".join(ttft))
    print("\nPrompt (prefill) tokens per request, from the server's usage (first repetition):\n")
    print("| Notes in store | Arm | p50 | p95 | Total over the questions | Questions |")
    print("| ---: | --- | ---: | ---: | ---: | ---: |")
    print("\n".join(tokens))
    print("\nThe lookup inside the server, (c), in microseconds (p50 / p95), with Python's retrieve() beside it:\n")
    print("| Notes in store | Question tokens | Lookup (Zig) | fit() count | Total in server | Python retrieve() | Candidates |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    print("\n".join(inner))
    print("\nChecks over the bench replies:\n")
    print("| Notes in store | Notes | Current | (c) replies | Ids and block SHA-256 equal to Python's | Most cached tokens |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: |")
    print("\n".join(checks))


if __name__ == "__main__":
    main()
