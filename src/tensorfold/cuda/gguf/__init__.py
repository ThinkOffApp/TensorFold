"""GGUF K-quant and IQ projections on Gufo's exact HIP GEMM (``vendor/``, MIT): a row's bits never depend on the row count.

The vendored kernels build with hipcc into ``libtfgguf.so``; a small torch binding calls it on the current stream.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from functools import lru_cache
from pathlib import Path

import torch

HERE = Path(__file__).parent
VENDOR = HERE / "vendor"
KERNELS = ["capi.hip"] + [str(VENDOR / "src/models/qwen/hip/kernels" / name) for name in
                          ("prefill_quant_gemm.hip", "prefill_gemm.hip", "small_batch_wave64.hip",
                           "small_batch_quant16_wave64.hip")]

# ggml type ids, as GGUF stores them
F32, F16, Q8_0, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ3_S, IQ4_XS, BF16 = 0, 1, 8, 11, 12, 13, 14, 20, 21, 23, 30
QUANT = {Q8_0, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ3_S, IQ4_XS}


def _library() -> Path:
    """Compile the vendored kernels once per source hash; the build directory holds the result."""

    from tensorfold.cuda.rocm import offload_arch

    sources = [HERE / KERNELS[0]] + [Path(s) for s in KERNELS[1:]]
    digest = hashlib.sha256()
    for path in sorted(VENDOR.rglob("*")) + sources:
        if path.is_file():
            digest.update(path.read_bytes())
    arch = offload_arch()
    out = Path(os.environ.get("TF_GGUF_BUILD", Path.home() / ".cache/tensorfold/gguf")) / f"{arch}-{digest.hexdigest()[:16]}"
    lib = out / "libtfgguf.so"
    if not lib.exists():
        out.mkdir(parents=True, exist_ok=True)
        print(f"building GGUF kernels ({arch}) into {out}", flush=True)
        tmp = out / "libtfgguf.so.tmp"
        subprocess.run(["hipcc", "-O3", "-std=c++20", "-fPIC", "-shared", f"--offload-arch={arch}",
                        "-DENGINE_ENABLE_HIP", f"-I{VENDOR}", "-o", str(tmp), *map(str, sources)], check=True)
        tmp.rename(lib)
    return lib


@lru_cache(maxsize=1)
def _ext():
    from torch.utils import cpp_extension

    lib = _library()
    return cpp_extension.load(name="tensorfold_gguf_v1", sources=[str(HERE / "binding.cpp")],
                              extra_ldflags=[f"-L{lib.parent}", "-ltfgguf", f"-Wl,-rpath,{lib.parent}"], verbose=False)


def linear(x: torch.Tensor, w: torch.Tensor, qtype: int, n: int) -> torch.Tensor:
    """x (rows, K) times the GGUF-packed ``w`` (N rows of K/block blocks) transposed -> (rows, N) fp32, any row count."""

    return _ext().linear(x.float().contiguous(), w, qtype, n)


def dequant(w: torch.Tensor, qtype: int, n: int) -> torch.Tensor:
    """The first ``n`` weights of packed ``w`` as bf16 (embedding rows)."""

    return _ext().dequant_bf16(w.contiguous(), qtype, n)
