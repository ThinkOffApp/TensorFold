"""GGUF projections take Gufo's fast routes by default on ROCm; TENSORFOLD_GGUF_FAST=0 is the off switch, and NVIDIA never does."""

import pytest

pytest.importorskip("torch")


@pytest.mark.parametrize("hip, value, fast", [
    (True, None, True), (True, "1", True), (True, "0", False),
    (False, None, False), (False, "1", False),
])
def test_gguf_fast_switch(monkeypatch, hip, value, fast):
    from tensorfold.cuda import rocm
    from tensorfold.families.qwen3_5.cuda import weights

    monkeypatch.setattr(rocm, "HIP", hip)
    if value is None:
        monkeypatch.delenv("TENSORFOLD_GGUF_FAST", raising=False)
    else:
        monkeypatch.setenv("TENSORFOLD_GGUF_FAST", value)
    assert weights._fast() is fast
