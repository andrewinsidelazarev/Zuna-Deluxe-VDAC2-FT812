#!/usr/bin/env python3
"""Split a .zlib file into 16384-byte chunks for spgbld page-by-page loading.

Why: spgbld places at most one 16KB SPG page per Block declaration. A .zlib
asset larger than 16384 bytes gets truncated. The Z80 inflate driver, however,
auto-advances Page3 via SetPage3_A; INC A — so if the same compressed stream
is split into 16K raw byte chunks on CONSECUTIVE pages, the driver reads it
back as one contiguous zlib stream.

This script splits a single .zlib file into N raw byte chunks at exact 16384
byte boundaries (NOT zlib-aware — just bytes). Each chunk is written as
`<basename>_p00.zlib`, `_p01.zlib`, ... next to the source.

Usage:
    python Source/OTHER/split_zlib_pages.py FILE.zlib [FILE2.zlib ...]
"""
import sys
from pathlib import Path

PAGE_SIZE = 16384


def split_file(path: Path) -> list[Path]:
    data = path.read_bytes()
    n_chunks = (len(data) + PAGE_SIZE - 1) // PAGE_SIZE
    out: list[Path] = []
    for i in range(n_chunks):
        chunk = data[i * PAGE_SIZE:(i + 1) * PAGE_SIZE]
        stem = path.stem  # without .zlib
        ext = path.suffix  # .zlib
        out_path = path.with_name(f"{stem}_p{i:02d}{ext}")
        out_path.write_bytes(chunk)
        out.append(out_path)
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"FAIL: {p} not found")
            return 1
        chunks = split_file(p)
        print(f"{p.name} ({p.stat().st_size} bytes) -> {len(chunks)} chunks:")
        for c in chunks:
            print(f"  {c.name}  ({c.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
