"""ROCm (HIP) builds of PyTorch run the CUDA backend on AMD GPUs; these switches keep them on portable kernels."""

from __future__ import annotations

import torch

HIP = bool(getattr(torch.version, "hip", None))     # a ROCm build: torch.cuda is the HIP device


def offload_arch() -> str:
    """The present AMD GPU's target, e.g. ``gfx1151`` (feature suffixes such as ``:xnack-`` dropped)."""

    return torch.cuda.get_device_properties(0).gcnArchName.split(":")[0]


__all__ = ["HIP", "offload_arch"]
