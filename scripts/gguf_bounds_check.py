"""GPU-side bounds check for the GGUF fast prefill (``tf_gguf_prefill_linear``): no route touches memory past its buffers.

    python scripts/gguf_bounds_check.py                    # guard pages, every route, controls first
    python scripts/gguf_bounds_check.py --mode sentinel    # tail patterns: does anything past the buffer change y?

The CPU model (tests/test_gguf_q8_bounds.py) derives every access from the kernel source. This script tests the same
claim on the device, calling libtfgguf's C entry points through ctypes with buffers it places itself:

``guard`` (default): the Q8_1 activation buffer, the output ``y`` and the weight are each placed so their last byte is
the last mapped byte of a HIP virtual-memory mapping (hipMemAddressReserve + hipMemMap), with an unmapped reserved
range after it. Any read or write past the end is a GPU page fault, which kills the process, so each (type, shape)
runs in a child process that prints the case before each launch; the parent restarts it after a fault. The
activation buffer's slack is filled with 0xFF (NaN scales) and ``y`` must equal the binding's normal call bit for bit.
Controls run first and MUST fault: Q8_0, m=256, K=5120 at 96 rows with the old exact-size buffer (the Strix fault
f328ee8 fixed), and at 129 rows with 5 slack tiles (the model says 6 is the least that fits). If they do not fault,
the guard is not working and the run reports so and fails instead of passing.

``sentinel``: no VMM; the activation buffer sits inside a larger torch tensor whose tail is filled with 0x00, 0xFF and
0x7F in turn; ``y`` must be identical bit for bit across the patterns and the tail must be unchanged after the call.

What it can prove: guard mode, every launched (type, rows, m, K) case touched no byte past the end of q8 or y
(weight: past the end rounded down to 256 bytes, kept for alignment) on this device and build. Sentinel mode only
that bytes past the end did not CHANGE the output; it cannot see over-reads whose values are discarded, which is
exactly the Q8_0 W8A8 over-read (those tokens are never stored), so on its own it would pass the unfixed buffer.
What neither can prove: rows, shapes or types not run (the CPU model covers rows 1..4096 symbolically); a different
build or Gufo revision; fault granularity (only bytes past the buffer end are unmapped, nothing before its start); or
that the wave64 kernels compiled for this architecture are the ones another architecture would select.
"""

from __future__ import annotations

import argparse
import ctypes
import glob
import os
import subprocess
import sys

import torch

from tensorfold.cuda import gguf

TYPES = {"Q8_0": gguf.Q8_0, "Q3_K": gguf.Q3_K, "Q4_K": gguf.Q4_K, "Q5_K": gguf.Q5_K, "Q6_K": gguf.Q6_K,
         "IQ4_NL": gguf.IQ4_NL, "IQ3_S": gguf.IQ3_S, "IQ4_XS": gguf.IQ4_XS}
# (block elements, block bytes, fp16 field offsets set to a small finite value so no output is NaN by construction)
BLOCKS = {"Q8_0": (32, 34, (0,)), "Q3_K": (256, 110, (108,)), "Q4_K": (256, 144, (0, 2)), "Q5_K": (256, 176, (0, 2)),
          "Q6_K": (256, 210, (208,)), "IQ4_NL": (32, 18, (0,)), "IQ3_S": (256, 110, (0,)), "IQ4_XS": (256, 136, (0,))}
# Route coverage (prefill_quant_gemm.hip:1501-1555, prefill_quant_wave64.hip:6-44): m=256 keeps Q8_0 on the unbounded
# W8A8 kernel at every row count (wave64 needs m >= 1024); m=17408/K=5120 has m >= 3K (BN=32 at <= 8 rows) and takes
# wave64 at >= 96; K=1056 (not a multiple of 256) declines wave64 at any m; m=6144 > K=5120 declines IQ4_XS's wave64.
SHAPES = {"Q8_0": [(256, 5120), (17408, 5120), (5120, 17408), (1024, 1056)],
          "IQ4_NL": [(256, 5120), (6144, 5120), (1024, 1056)],
          "IQ4_XS": [(256, 5120), (6144, 5120), (5120, 17408)]}
DEFAULT_SHAPES = [(256, 5120), (6144, 5120), (5120, 17408)]
ROWS = [1, 2, 7, 8, 9, 15, 16, 17, 63, 64, 65, 80, 95, 96, 97, 112, 113, 127, 128, 129, 144, 145, 255, 256, 257, 1000,
        2048, 4096]
TILE_BYTES, SUM_TILE_BYTES = 576, 64


def quantized_bytes(rows: int, k: int) -> int:
    """Gufo's QuantizedActivationBytes: payload tiles plus the sum sidecar, no slack."""

    return -(-rows // 16) * (k // 32) * (TILE_BYTES + SUM_TILE_BYTES)


def q8_size(lib, rows: int, k: int, size: str) -> int:
    if size == "slack":
        return lib.tf_gguf_q8_1_bytes(rows, k)
    if size == "exact":
        return quantized_bytes(rows, k)
    return quantized_bytes(rows, k) + int(size.split(":")[1]) * (k // 32) * TILE_BYTES       # tiles:N


def weight(name: str, m: int, k: int, seed: int) -> torch.Tensor:
    qk, nbytes, halves = BLOCKS[name]
    g = torch.Generator().manual_seed(seed)
    w = torch.randint(0, 256, (m, k // qk, nbytes), dtype=torch.uint8, generator=g)
    small = torch.tensor([0.01], dtype=torch.float16).view(torch.uint8)
    for off in halves:
        w[..., off:off + 2] = small
    return w.reshape(-1).cuda()


def library():
    lib = ctypes.CDLL(str(gguf._library()))
    lib.tf_gguf_q8_1_bytes.restype = ctypes.c_size_t
    lib.tf_gguf_q8_1_bytes.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    lib.tf_gguf_prefill_linear.restype = ctypes.c_int
    lib.tf_gguf_prefill_linear.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int,
                                           ctypes.c_void_p, ctypes.c_void_p] + [ctypes.c_size_t] * 3 + [ctypes.c_void_p]
    return lib


def run(lib, qtype: int, w: int, x: torch.Tensor, q8: int, y: int, rows: int, m: int, k: int) -> None:
    stream = torch.cuda.current_stream().cuda_stream
    err = lib.tf_gguf_prefill_linear(qtype, w, x.data_ptr(), 1, q8, y, rows, m, k, stream)
    torch.cuda.synchronize()                                   # a fault surfaces here, at the case that caused it
    assert err == 0, f"HIP error {err}"


# --- guard pages: HIP virtual memory (hip_runtime_api.h) -------------------------------------------------------------

class _Location(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("id", ctypes.c_int)]


class _Prop(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("requestedHandleType", ctypes.c_int), ("location", _Location),
                ("win32HandleMetaData", ctypes.c_void_p), ("compressionType", ctypes.c_ubyte),
                ("gpuDirectRDMACapable", ctypes.c_ubyte), ("usage", ctypes.c_ushort), ("_reserved", ctypes.c_byte * 64)]


class _Access(ctypes.Structure):
    _fields_ = [("location", _Location), ("flags", ctypes.c_int)]


def _hip():
    for name in ["libamdhip64.so", *glob.glob(os.path.join(os.path.dirname(torch.__file__), "lib", "libamdhip64.so*"))]:
        try:
            return ctypes.CDLL(name)
        except OSError:
            continue
    raise SystemExit("libamdhip64.so not found")


class Guarded:
    """``size`` bytes ending exactly at the end of a mapping, followed by reserved but unmapped address space."""

    def __init__(self, hip, size: int, align: int = 16):
        self.hip = hip
        dev = torch.cuda.current_device()
        self.prop = _Prop(type=1, requestedHandleType=0, location=_Location(type=1, id=dev))   # pinned, device
        gran = ctypes.c_size_t()
        self._ok(hip.hipMemGetAllocationGranularity(ctypes.byref(gran), ctypes.byref(self.prop), 0))
        g = gran.value
        self.mapped = -(-size // g) * g
        self.reserved = self.mapped + 4 * g
        self.base = ctypes.c_void_p()
        self._ok(hip.hipMemAddressReserve(ctypes.byref(self.base), ctypes.c_size_t(self.reserved), ctypes.c_size_t(g),
                                          None, ctypes.c_ulonglong(0)))
        self.handle = ctypes.c_void_p()
        self._ok(hip.hipMemCreate(ctypes.byref(self.handle), ctypes.c_size_t(self.mapped), ctypes.byref(self.prop),
                                  ctypes.c_ulonglong(0)))
        self._ok(hip.hipMemMap(self.base, ctypes.c_size_t(self.mapped), ctypes.c_size_t(0), self.handle,
                               ctypes.c_ulonglong(0)))
        access = _Access(location=_Location(type=1, id=dev), flags=3)                          # read/write
        self._ok(hip.hipMemSetAccess(self.base, ctypes.c_size_t(self.mapped), ctypes.byref(access), ctypes.c_size_t(1)))
        start = (self.base.value + self.mapped - size) // align * align
        self.ptr, self.after = start, self.base.value + self.mapped - (start + size)            # unguarded bytes after

    @staticmethod
    def _ok(err):
        if err != 0:
            raise RuntimeError(f"HIP VMM call failed ({err}); this device or runtime may not support guard pages, "
                               "use --mode sentinel")

    def close(self):
        self.hip.hipMemUnmap(self.base, ctypes.c_size_t(self.mapped))
        self.hip.hipMemRelease(self.handle)
        self.hip.hipMemAddressFree(self.base, ctypes.c_size_t(self.reserved))


def _memcpy(hip, dst: int, src: int, n: int) -> None:
    assert hip.hipMemcpy(ctypes.c_void_p(dst), ctypes.c_void_p(src), ctypes.c_size_t(n), 3) == 0   # device to device


def child(args) -> int:
    """One (type, m, K) over ``args.rows`` from ``args.start``: prints ``CASE`` before each launch, ``OK``/``MISMATCH``."""

    lib, hip = library(), _hip()
    name, m, k = args.child[0], int(args.child[1]), int(args.child[2])
    qtype = TYPES[name]
    w = weight(name, m, k, seed=m * 31 + k)
    gw = Guarded(hip, w.numel(), align=256)
    _memcpy(hip, gw.ptr, w.data_ptr(), w.numel())
    for rows in args.rows[args.start:]:
        print(f"CASE {name} rows={rows} m={m} k={k} size={args.size}", flush=True)
        x = torch.randn(rows, k, generator=torch.Generator().manual_seed(rows)).to(torch.bfloat16).cuda()
        ref = gguf.prefill_linear(x, w, qtype, m, pad=0)
        size = q8_size(lib, rows, k, args.size)
        assert size % 16 == 0 and lib.tf_gguf_q8_1_bytes(rows, k) == q8_size(lib, rows, k, "tiles:8"), "capi formula"
        gq, gy = Guarded(hip, size), Guarded(hip, rows * m * 4, align=4)
        torch.cuda.synchronize()
        tail = quantized_bytes(rows, k)
        if size > tail:                                        # NaN scales in the slack: a read that is used shows up
            assert hip.hipMemset(ctypes.c_void_p(gq.ptr + tail), 0xFF, ctypes.c_size_t(size - tail)) == 0
        run(lib, qtype, gw.ptr, x, gq.ptr, gy.ptr, rows, m, k)
        y = torch.empty(rows, m, dtype=torch.float32, device="cuda")
        _memcpy(hip, y.data_ptr(), gy.ptr, rows * m * 4)
        same = torch.equal(y.view(torch.int32), ref.view(torch.int32))
        print(f"{'OK' if same else 'MISMATCH'} {name} rows={rows} m={m} k={k}", flush=True)
        gq.close(), gy.close()
    gw.close()
    return 0


def guarded_sweep(name: str, m: int, k: int, rows: list[int], size: str) -> list[str]:
    """Runs one (type, shape) in children, restarting after each fault. Returns the faulting/mismatching cases."""

    bad, start = [], 0
    while start < len(rows):
        cmd = [sys.executable, __file__, "--child", name, str(m), str(k), "--size", size, "--start", str(start),
               "--rows", *map(str, rows)]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)   # a fault is the signal
        lines = proc.stdout.splitlines()
        cases = [ln for ln in lines if ln.startswith("CASE ")]
        bad += [ln for ln in lines if ln.startswith("MISMATCH")]
        if proc.returncode == 0:
            break
        last = cases[-1] if cases else f"{name} m={m} k={k} before the first case"
        err = (proc.stderr.strip().splitlines() or ["?"])[-1]
        bad.append(f"FAULT {last[5:]} (exit {proc.returncode}: {err[:160]})")
        start += max(len(cases), 1)
    return bad


def sentinel(args) -> int:
    lib = library()
    failures = 0
    for name in args.types:
        qtype = TYPES[name]
        for m, k in SHAPES.get(name, DEFAULT_SHAPES):
            w = weight(name, m, k, seed=m * 31 + k)
            for rows in args.rows:
                x = torch.randn(rows, k, generator=torch.Generator().manual_seed(rows)).to(torch.bfloat16).cuda()
                size = q8_size(lib, rows, k, args.size)
                buf = torch.empty(size + (1 << 20), dtype=torch.uint8, device="cuda")
                y = torch.empty(rows, m, dtype=torch.float32, device="cuda")
                outs, clobbered = [], False
                for pattern in (0x00, 0xFF, 0x7F):
                    buf[size:] = pattern
                    run(lib, qtype, w.data_ptr(), x, buf.data_ptr(), y.data_ptr(), rows, m, k)
                    clobbered |= not bool((buf[size:] == pattern).all())
                    outs.append(y.view(torch.int32).clone())
                same = all(torch.equal(outs[0], o) for o in outs[1:])
                if not same or clobbered:
                    failures += 1
                    print(f"FAIL {name} rows={rows} m={m} k={k}: "
                          f"{'output depends on the tail ' if not same else ''}{'tail written' if clobbered else ''}")
        print(f"{name}: done", flush=True)
    print("sentinel: PASS" if failures == 0 else f"sentinel: {failures} FAIL")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["guard", "sentinel"], default="guard")
    ap.add_argument("--size", default="slack", help="slack (tf_gguf_q8_1_bytes), exact (no slack) or tiles:N")
    ap.add_argument("--types", nargs="+", default=list(TYPES))
    ap.add_argument("--rows", nargs="+", type=int, default=ROWS)
    ap.add_argument("--child", nargs=3, help=argparse.SUPPRESS)
    ap.add_argument("--start", type=int, default=0, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.child:
        return child(args)
    if args.mode == "sentinel":
        return sentinel(args)

    # Controls: the guard must catch the over-reads the CPU model predicts, or a clean sweep means nothing.
    controls = [("exact", 96), ("tiles:5", 129)]
    for size, rows in controls:
        bad = guarded_sweep("Q8_0", 256, 5120, [rows], size)
        caught = any(b.startswith("FAULT") for b in bad)
        print(f"control Q8_0 m=256 k=5120 rows={rows} size={size}: {'faulted (guard works)' if caught else 'NO FAULT'}")
        if not caught:
            print("guard: INEFFECTIVE, the known over-read went undetected; the sweep below would prove nothing")
            return 2
    ok = guarded_sweep("Q8_0", 256, 5120, [129, 144], "tiles:6")
    print(f"control Q8_0 rows=129,144 size=tiles:6 (the model's least sufficient slack): {ok or 'clean'}")

    failures = []
    for name in args.types:
        for m, k in SHAPES.get(name, DEFAULT_SHAPES):
            bad = guarded_sweep(name, m, k, args.rows, args.size)
            failures += bad
            print(f"{name} m={m} k={k}: {'clean' if not bad else f'{len(bad)} bad'}", flush=True)
            for b in bad:
                print("  " + b)
    print("guard: PASS" if not failures else f"guard: {len(failures)} FAIL")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
