"""Row invariance of the GGUF projections on real 27B tensors: every row count gives every row the same bits.

    python tools/gguf_rows_check.py MODEL.gguf [--gguf-py DIR]

One tensor of each quant type in the file. For each: 80 random fp32 rows through ``gguf.linear`` at once, then row
counts 1..17, 24, 28, 32, 42, 48, 56, 64 and one row at a time must match those bits exactly. The negative control
(bf16 dequant then matmul) must NOT match bitwise, or the check could not fail; its relative error must stay small.
"""

from __future__ import annotations

import argparse
import sys

import torch


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--gguf-py", default=None, help="llama.cpp's gguf-py directory, if gguf is not installed")
    ap.add_argument("--rows", type=int, default=80)
    args = ap.parse_args()
    if args.gguf_py:
        sys.path.insert(0, args.gguf_py)
    from gguf import GGUFReader

    from tensorfold.cuda import gguf

    reader = GGUFReader(args.model)
    picked = {}
    for t in reader.tensors:                       # the smallest 2D tensor of each type keeps the run short
        q = int(t.tensor_type)
        if q in gguf.QUANT and len(t.shape) == 2 and (q not in picked or t.n_elements < picked[q].n_elements):
            picked[q] = t
    counts = sorted({*range(1, 18), 24, 28, 32, 42, 48, 56, 64})
    torch.manual_seed(0)
    failed = 0
    for q, t in sorted(picked.items()):
        k, n = int(t.shape[0]), int(t.shape[1])            # GGUF lists the input dimension first
        w = torch.from_numpy(t.data.reshape(-1).view("uint8").copy()).cuda()
        x = torch.randn(args.rows, k, device="cuda") * 0.5
        ref = gguf.linear(x, w, q, n)
        bad = [m for m in counts if m <= args.rows and not torch.equal(gguf.linear(x[:m], w, q, n), ref[:m])]
        single = torch.cat([gguf.linear(x[i:i + 1], w, q, n) for i in range(args.rows)])
        if not torch.equal(single, ref):
            bad.append("one-at-a-time")
        dense = gguf.dequant(w, q, n * k).view(n, k).float()
        other = x @ dense.T
        rel = ((other - ref).norm() / ref.norm()).item()
        control = "differs (ok)" if not torch.equal(other, ref) else "EQUAL (control cannot fail)"
        ok = not bad and rel < 2e-2 and not torch.equal(other, ref)
        failed += not ok
        print(f"{t.tensor_type.name:7} {t.name:28} N={n:6} K={k:6}  invariant={'yes' if not bad else bad}  "
              f"vs dequant: rel={rel:.2e} {control}  {'PASS' if ok else 'FAIL'}", flush=True)
    print("ALL PASS" if not failed else f"{failed} FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
