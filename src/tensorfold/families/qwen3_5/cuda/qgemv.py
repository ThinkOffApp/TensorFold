"""Row-invariant affine 4-bit decode matmul for GPUs without the sm_90 tiles (ROCm): one program per (row, column block, K slice).

Each row runs the same program whatever the row count, so a drafted row's bits equal its serial bits. Weights stream in
``GI`` groups of 64 inputs per step (contiguous 32*GI-byte runs per output row); nibbles unpack in registers; a group
contributes ``scale * dot + bias * sum(x)`` (MLX's affine form) and K slices add in a fixed order."""

from __future__ import annotations

import torch
import triton
import triton.language as tl


@triton.jit
def _gemv(X, XS, W, S, B, OUT, PART, M, N: tl.constexpr, K: tl.constexpr, SK: tl.constexpr,
          BN: tl.constexpr, GI: tl.constexpr):
    KG: tl.constexpr = K // 64
    K8: tl.constexpr = K // 8
    PER: tl.constexpr = KG // SK                   # groups in this program's K slice
    m = tl.program_id(0)
    pid_n = tl.program_id(1)
    s_id = tl.program_id(2)
    rn = pid_n * BN + tl.arange(0, BN)
    n_ok = rn < N
    words = tl.arange(0, GI * 8)                   # this step's words of a row: GI groups x 8 words
    gi = tl.arange(0, GI)
    shifts = (tl.arange(0, 8) * 4)
    acc = tl.zeros((BN,), dtype=tl.float32)
    g0 = s_id * PER
    for step in range(PER // GI):
        g = g0 + step * GI
        w = tl.load(W + rn[:, None] * K8 + g * 8 + words[None, :], mask=n_ok[:, None], other=0)   # (BN, GI*8) int32
        q = (w[:, :, None] >> shifts[None, None, :]) & 0xF                                         # (BN, GI*8, 8)
        q = tl.reshape(q.to(tl.float32), (BN, GI, 64))
        x = tl.load(X + m * K + g * 64 + tl.arange(0, GI * 64)).to(tl.float32)
        x = tl.reshape(x, (GI, 64))
        dot = tl.sum(q * x[None, :, :], axis=2)                                                      # (BN, GI)
        s = tl.load(S + rn[:, None] * KG + g + gi[None, :], mask=n_ok[:, None], other=0.0).to(tl.float32)
        b = tl.load(B + rn[:, None] * KG + g + gi[None, :], mask=n_ok[:, None], other=0.0).to(tl.float32)
        xs = tl.load(XS + m * KG + g + gi)
        acc += tl.sum(s * dot + b * xs[None, :], axis=1)
    if SK == 1:
        tl.store(OUT + m * N + rn, acc.to(tl.bfloat16), mask=n_ok)
    else:
        tl.store(PART + (s_id * M + m) * N + rn, acc, mask=n_ok)


@triton.jit
def _reduce(PART, OUT, total, SK: tl.constexpr, BLOCK: tl.constexpr):
    i = tl.program_id(0) * BLOCK + tl.arange(0, BLOCK)
    ok = i < total
    acc = tl.zeros((BLOCK,), dtype=tl.float32)
    for s in range(SK):                            # slices add in order: fixed by the shape
        acc += tl.load(PART + s * total + i, mask=ok, other=0.0)
    tl.store(OUT + i, acc.to(tl.bfloat16), mask=ok)


@triton.jit
def _group_sums(X, XS, K: tl.constexpr, KG: tl.constexpr):
    m = tl.program_id(0)
    g = tl.program_id(1)
    x = tl.load(X + m * K + g * 64 + tl.arange(0, 64)).to(tl.float32)
    tl.store(XS + m * KG + g, tl.sum(x, axis=0))


def group_sums(x: torch.Tensor) -> torch.Tensor:
    m, k = x.shape
    xs = torch.empty((m, k // 64), dtype=torch.float32, device=x.device)
    _group_sums[(m, k // 64)](x, xs, K=k, KG=k // 64, num_warps=1)
    return xs


BN = 32
GI = 4


def split_k(n: int, k: int) -> int:
    """K slices from the shape alone (never the row count): enough programs to fill the GPU for narrow outputs."""

    kg = k // 64
    tiles = -(-n // BN)
    sk = 1
    while sk < 8 and tiles * sk < 512 and kg % (sk * 2 * GI) == 0:
        sk *= 2
    return sk


def gemv(x: torch.Tensor, weight: torch.Tensor, scales: torch.Tensor, biases: torch.Tensor,
         sk: int | None = None, xs: torch.Tensor | None = None) -> torch.Tensor:
    """x (M, K) bf16 times the MLX-packed 4-bit ``weight`` (N, K/8) transposed -> (M, N) bf16; any M, same row bits."""

    if x.dtype != torch.bfloat16 or x.dim() != 2:
        raise ValueError("gemv: x must be a 2-D bf16 tensor")
    m, k = x.shape
    n = weight.shape[0]
    if weight.shape[1] * 8 != k or k % (64 * GI):
        raise ValueError(f"gemv: weight {tuple(weight.shape)} does not match K={k}")
    x = x.contiguous()
    sk = int(sk) if sk else split_k(n, k)
    if (k // 64) % (sk * GI):
        raise ValueError(f"gemv: {sk} K slices do not divide {k // 64} groups in steps of {GI}")
    xs = group_sums(x) if xs is None else xs
    out = torch.empty((m, n), dtype=torch.bfloat16, device=x.device)
    part = out if sk == 1 else torch.empty((sk, m, n), dtype=torch.float32, device=x.device)
    _gemv[(m, triton.cdiv(n, BN), sk)](x, xs, weight, scales, biases, out, part, m, N=n, K=k, SK=sk,
                                       BN=BN, GI=GI, num_warps=4)
    if sk > 1:
        total = m * n
        _reduce[(triton.cdiv(total, 1024),)](part, out, total, SK=sk, BLOCK=1024, num_warps=4)
    return out


__all__ = ["gemv", "group_sums", "split_k"]
