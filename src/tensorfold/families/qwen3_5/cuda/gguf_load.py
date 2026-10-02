"""A GGUF file of a Qwen3.5 dense model into the MLX path's ``Weights``: quantized projections on the exact GGUF kernels.

The model directory holds the checkpoint's config.json, generation_config.json and tokenizer beside one ``*.gguf``.
llama.cpp's converter changed three things, and each is undone here without touching a packed block:
  * GDN value heads went from grouped-by-key-head to tiled order. Row permutations (qkv's V rows, z, a, b, conv,
    A, dt_bias) move whole packed rows back; out_proj's reordered input columns are met by permuting its input.
  * A_log was stored as A = -exp(A_log); A_log comes back as log(-A) in float64.
  * norm weights carry the +1 the MLX checkpoints also carry, so they load as stored (bf16 when that is exact).
"""

from __future__ import annotations

from pathlib import Path

import torch

from .gguf_detect import gguf_file  # noqa: F401  (re-exported: callers import it from here)
from .weights import GDN, Attention, Config, Gguf, Layer, Plain, Weights, bf16_prefill, dense_prompt


def _reader(path: Path):
    from tensorfold.cuda.gguf import reader

    return reader(path)


def _grouped(tiled_heads: int, k_heads: int) -> torch.Tensor:
    """For each grouped head h (k-head h // r, member h % r), its index in the file's tiled order (member * kh + k-head)."""

    r = tiled_heads // k_heads
    h = torch.arange(tiled_heads)
    return (h % r) * k_heads + h // r


def _expand(heads: torch.Tensor, width: int) -> torch.Tensor:
    return (heads[:, None] * width + torch.arange(width)[None, :]).reshape(-1)


def _bf16_if_exact(t: torch.Tensor) -> torch.Tensor:
    b = t.to(torch.bfloat16)
    return b if torch.equal(b.float(), t.float()) else t.float()


def load_gguf(model_dir: str | Path, device: str = "cuda") -> Weights:
    from tensorfold.cuda import gguf as kernels

    model_dir = Path(model_dir)
    cfg = Config.read(model_dir)
    if cfg.experts:
        raise ValueError("GGUF loading covers the dense Qwen3.5 models; routed experts are not read yet")
    reader = _reader(gguf_file(model_dir))
    tensors = {t.name: t for t in reader.tensors}
    used: set[str] = set()

    def raw(name: str) -> tuple[object, torch.Tensor]:
        t = tensors[name]
        used.add(name)
        return t, torch.from_numpy(t.data.copy())

    def dense(name: str) -> torch.Tensor:
        t, data = raw(name)
        if int(t.tensor_type) not in (kernels.F32, kernels.F16, kernels.BF16):
            raise ValueError(f"{name}: expected a float tensor, found {t.tensor_type.name}")
        return data.float() if int(t.tensor_type) != kernels.BF16 else data.view(torch.bfloat16)

    def proj(name: str, rows: torch.Tensor | None = None, in_perm: torch.Tensor | None = None):
        t, data = raw(name)
        q, k, n = int(t.tensor_type), int(t.shape[0]), int(t.shape[1])
        if q in (kernels.F32, kernels.F16, kernels.BF16):
            w = data.float().reshape(n, k) if q != kernels.BF16 else data.view(torch.bfloat16).reshape(n, k)
            if rows is not None:
                w = w.index_select(0, rows)
            if in_perm is not None:
                w = w.index_select(1, in_perm.argsort())
            return Plain(w.to(torch.bfloat16).contiguous().to(device))
        if q not in kernels.QUANT:
            raise ValueError(f"{name}: {t.tensor_type.name} has no exact GGUF kernel here")
        packed = data.view(torch.uint8).reshape(n, -1)
        if rows is not None:
            packed = packed.index_select(0, rows)
        return Gguf(packed.contiguous().to(device), q, k,
                    None if in_perm is None else in_perm.to(device))

    kh, vh, dk, dv = cfg.k_heads, cfg.v_heads, cfg.dk, cfg.dv
    heads = _grouped(vh, kh)                                   # grouped head -> its tiled position
    v_rows = _expand(heads, dv)
    qk = 2 * kh * dk
    qkv_rows = torch.cat([torch.arange(qk), qk + v_rows])
    layers = []
    for i in range(cfg.layers):
        p = f"blk.{i}."
        gdn = attn = None
        if cfg.is_linear(i):
            conv = dense(p + "ssm_conv1d.weight").reshape(-1, cfg.conv_kernel)
            A = dense(p + "ssm_a").double()
            gdn = GDN(qkv=proj(p + "attn_qkv.weight", qkv_rows), z=proj(p + "attn_gate.weight", v_rows),
                      b=proj(p + "ssm_beta.weight", heads), a=proj(p + "ssm_alpha.weight", heads),
                      out=proj(p + "ssm_out.weight", in_perm=v_rows.argsort()),
                      conv=_bf16_if_exact(conv.index_select(0, qkv_rows)).contiguous().to(device),
                      A_log=torch.log(-A).float().index_select(0, heads).contiguous().to(device),
                      dt_bias=dense(p + "ssm_dt.bias").index_select(0, heads).contiguous().to(device),
                      norm=_bf16_if_exact(dense(p + "ssm_norm.weight")).contiguous().to(device))
        else:
            attn = Attention(q=proj(p + "attn_q.weight"), k=proj(p + "attn_k.weight"), v=proj(p + "attn_v.weight"),
                             o=proj(p + "attn_output.weight"),
                             q_norm=_bf16_if_exact(dense(p + "attn_q_norm.weight")).contiguous().to(device),
                             k_norm=_bf16_if_exact(dense(p + "attn_k_norm.weight")).contiguous().to(device))
        layers.append(Layer(linear=cfg.is_linear(i),
                            input_norm=_bf16_if_exact(dense(p + "attn_norm.weight")).contiguous().to(device),
                            post_norm=_bf16_if_exact(dense(p + "post_attention_norm.weight")).contiguous().to(device),
                            gdn=gdn, attn=attn, gate=proj(p + "ffn_gate.weight"), up=proj(p + "ffn_up.weight"),
                            down=proj(p + "ffn_down.weight")))
    head_name = "output.weight" if "output.weight" in tensors else "token_embd.weight"
    w = Weights(config=cfg, embed=proj("token_embd.weight"), layers=layers,
                norm=_bf16_if_exact(dense("output_norm.weight")).contiguous().to(device),
                head=proj(head_name), quant="gguf")
    half = cfg.rope_dims // 2
    inv = cfg.rope_theta ** (-torch.arange(0, half, dtype=torch.float64) / half)
    w.inv_freq = inv.to(torch.float32).to(device)
    left = [n for n in tensors if n not in used and not n.startswith(f"blk.{cfg.layers}.")]   # the MTP block is not read
    if left:
        raise ValueError(f"unused GGUF tensors: {left[:5]} ...")
    if bf16_prefill():
        _attach_dense(w)
    return w


def _dense(g: Gguf) -> torch.Tensor:
    """g's weights as an (N, K) bf16 matrix: Gufo's dequantizer where it has one (Q8_0, Q5_K, Q6_K), otherwise the exact
    linear route on one-hot rows (each output is one weight times 1.0 plus zeros, so the fp32 value is that weight)."""

    from tensorfold.cuda import gguf

    n, k = g.n, g.k
    if g.qtype in (gguf.Q8_0, gguf.Q5_K, gguf.Q6_K):
        return gguf.dequant(g.weight, g.qtype, n * k).view(n, k)
    out = torch.empty((n, k), dtype=torch.bfloat16, device=g.weight.device)
    for j0 in range(0, k, 512):
        j1 = min(k, j0 + 512)
        eye = torch.zeros((j1 - j0, k), dtype=torch.float32, device=g.weight.device)
        eye[:, j0:j1] = torch.eye(j1 - j0, device=g.weight.device)
        out[:, j0:j1] = gguf.linear(eye, g.weight, g.qtype, n).t().to(torch.bfloat16)
    return out


# Row counts and offsets the per-shape check compares with one 4096-row call: the padding edges at every step, both
# sides of 1024, and slices away from row 0 (a row's bits must not depend on where it sits in the call).
_CHECK = [(1, 0), (2, 5), (7, 100), (37, 3), (95, 1), (127, 0), (128, 256), (129, 7), (300, 9), (513, 7), (1000, 1000),
          (1023, 1), (1024, 0), (1025, 3), (2048, 0), (2048, 2048), (3000, 50), (4095, 1), (4096, 0)]


def _gran(d: torch.Tensor, gen: torch.Generator) -> int | None:
    """The smallest padding step (128..1024) at which every checked slice of a prompt on ``d`` has the same bits as the
    same rows of one 4096-row call, or None if no step does (the shape stays on the int8 route)."""

    x = torch.randn((4096, d.shape[1]), generator=gen, device=d.device).to(torch.bfloat16)
    full = (x @ d.t()).view(torch.int16)
    for gran in (128, 256, 512, 1024):
        if all(torch.equal(dense_prompt(x[o:o + r], d, gran).view(torch.int16), full[o:o + r]) for r, o in _CHECK):
            return gran
    return None


def _attach_dense(w: Weights) -> None:
    """TENSORFOLD_GGUF_BF16_PREFILL: bf16 copies of every layer projection, each shape with its checked padding step
    (``_gran``); a shape no step keeps bit-stable drops its copies and stays on the int8 route."""

    projs = []
    for layer in w.layers:
        parts = [layer.gate, layer.up, layer.down]
        if layer.gdn is not None:
            parts += [layer.gdn.qkv, layer.gdn.z, layer.gdn.b, layer.gdn.a, layer.gdn.out]
        if layer.attn is not None:
            parts += [layer.attn.q, layer.attn.k, layer.attn.v, layer.attn.o]
        projs += [p for p in parts if isinstance(p, Gguf)]
    gen = torch.Generator(device=projs[0].weight.device).manual_seed(0)
    grans, kept = {}, []
    for p in projs:
        shape = (p.n, p.k)
        if shape not in grans:
            d = _dense(p)
            grans[shape] = _gran(d, gen)
            if grans[shape] is None:
                del d
                continue
            p.dense = d
        elif grans[shape] is not None:
            p.dense = _dense(p)
        if p.dense is not None:
            p.gran = grans[shape]
            kept.append(p)
    mib = sum(p.dense.numel() * 2 for p in kept) / 2**20
    steps = ", ".join(f"{n}x{k}:{g or 'int8'}" for (n, k), g in sorted(grans.items()))
    print(f"[tensorfold] bf16 prompt weights: {len(kept)} of {len(projs)} projections, {mib:.0f} MiB; padding step per "
          f"shape {steps}", flush=True)


def weight_bytes(layers: int):
    """The startup estimate's transform: packed bytes as stored, the head once more (in part) for the drafter's rows."""

    def transform(name: str, info: dict) -> tuple[int, int]:
        if name.startswith(f"model.layers.{layers}."):          # the MTP block is not read
            return 0, 0
        size = int(info["data_offsets"][1])
        if bf16_prefill() and name.startswith("model.layers.") and info.get("gguf_type", 0) not in (0, 1, 30):
            size += 2 * int(info.get("elements", 0))            # the bf16 prompt copy (F32/F16/BF16 load as Plain)
        return (size * 7 // 5 if name == "output.weight" else size), 0

    return transform
