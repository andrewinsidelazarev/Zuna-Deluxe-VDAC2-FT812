#!/usr/bin/env python3
"""Verify that original two-curve boards keep both tracks in ZUMALVL.PAK."""
from __future__ import annotations

import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Build" / "ZUMALVL.PAK"
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "pack"
SECTOR = 512
PAGE = 16384
SECOND_TRACK_LEVELS = (5, 12, 19)


def toc_entry(pack: bytes, level: int) -> tuple[int, int]:
    base = SECTOR + (level - 1) * 20
    vals = struct.unpack_from("<HHHHHHHHHH", pack, base)
    return vals[4], vals[5]


def main() -> int:
    pack = PACK.read_bytes()
    failures: list[str] = []
    for level in SECOND_TRACK_LEVELS:
        first = (ASSETS / f"track_l{level:02d}_640.bin").read_bytes()
        second = (ASSETS / f"track_l{level:02d}_2_640.bin").read_bytes()
        off, size = toc_entry(pack, level)
        blob = pack[off * SECTOR : (off + size) * SECTOR]
        if blob[: len(first)] != first:
            failures.append(f"L{level:02d}: first track mismatch")
        if any(blob[len(first) : PAGE]):
            failures.append(f"L{level:02d}: first track page padding is not zero")
        if blob[PAGE : PAGE + len(second)] != second:
            failures.append(f"L{level:02d}: second track mismatch")
        print(f"L{level:02d}: track section {size}s, first={len(first)}, second={len(second)}")

    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print("PASS: two-track level sections contain both tracks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
