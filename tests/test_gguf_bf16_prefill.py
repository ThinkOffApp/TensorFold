"""TENSORFOLD_GGUF_BF16_PREFILL's switch and padding: off unless asked, and the row counts a bf16 prompt call is padded to."""

import pytest

from tensorfold.families.qwen3_5.cuda import weights


def test_off_by_default(monkeypatch):
    monkeypatch.delenv("TENSORFOLD_GGUF_BF16_PREFILL", raising=False)
    assert weights.bf16_prefill() is False


@pytest.mark.parametrize("rows,gran,want", [(1, 128, 128), (128, 128, 128), (129, 128, 256), (1000, 512, 1024),
                                            (1024, 128, 1024), (1025, 128, 4096), (4096, 1024, 4096)])
def test_padding(rows, gran, want):
    assert weights.bf16_rows(rows, gran) == want
