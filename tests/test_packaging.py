"""Every CUDA source and data file under src ships in the wheel: pyproject's package-data names it (#66)."""

import fnmatch
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHIPPED = {".cu", ".cuh", ".cpp", ".hip", ".hpp", ".json", ".txt"}   # what the engines read or build at run time


def unlisted(pyproject: str, src: Path) -> list[str]:
    table = tomllib.loads(pyproject)["tool"]["setuptools"]["package-data"]
    missing = []
    for path in sorted((src / "tensorfold").rglob("*")):     # not a build's egg-info
        if path.suffix not in SHIPPED:
            continue
        rel = path.relative_to(src)
        # a package's patterns name its own files, or (like setuptools) paths into non-package folders below it
        listed = any(fnmatch.fnmatch("/".join(rel.parts[i:]), p)
                     for i in range(1, len(rel.parts))
                     for p in table.get(".".join(rel.parts[:i]), []))
        if not listed:
            missing.append(str(rel))
    return missing


def test_package_data_covers_every_runtime_file():
    assert unlisted((ROOT / "pyproject.toml").read_text(), ROOT / "src") == []
