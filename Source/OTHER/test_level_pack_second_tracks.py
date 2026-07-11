#!/usr/bin/env python3
"""Verify that original two-curve boards keep both Track V4 paths in ZUMALVL.PAK."""
from __future__ import annotations

import struct
from pathlib import Path

from make_level_pack import (
    PAGE,
    SECTOR,
    TRACK_V2_MAGIC,
    TRACK_V2_REC,
    TRACK_V2_SAMPLES_PER_PAGE,
    TRACK_SPIN12_K,
    TRACK_SPIN12_PHASES,
    TRACK_V4_META_VISIBLE,
    TRACK_V4_META_VX_SIGN,
    TRACK_V4_META_VY_SIGN,
    encode_track_v2_pages,
    read_track_blob,
    scale_track_samples,
)

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Build" / "ZUMALVL.PAK"
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "pack"
SECOND_TRACK_LEVELS = (5, 12, 19)


def toc_entry(pack: bytes, level: int) -> tuple[int, int]:
    base = SECTOR + (level - 1) * 20
    vals = struct.unpack_from("<HHHHHHHHHH", pack, base)
    return vals[4], vals[5]


def main() -> int:
    pack = PACK.read_bytes()
    failures: list[str] = []
    for level in SECOND_TRACK_LEVELS:
        first = scale_track_samples((ASSETS / f"track_l{level:02d}_640.bin").read_bytes())
        second = scale_track_samples((ASSETS / f"track_l{level:02d}_2_640.bin").read_bytes())
        count1, pages1 = encode_track_v2_pages(first)
        count2, pages2 = encode_track_v2_pages(second)
        expected = read_track_blob(level - 1)
        assert first is not None and second is not None and expected is not None
        off, size = toc_entry(pack, level)
        blob = pack[off * SECTOR : (off + size) * SECTOR]
        meta = blob[:SECTOR]
        if meta[:4] != TRACK_V2_MAGIC:
            failures.append(f"L{level:02d}: Track V4 magic mismatch")
        if struct.unpack_from("<H", meta, 4)[0] != count1 or meta[6] != len(pages1):
            failures.append(f"L{level:02d}: first track metadata mismatch")
        if struct.unpack_from("<H", meta, 7)[0] != count2 or meta[9] != len(pages2):
            failures.append(f"L{level:02d}: second track metadata mismatch")
        if meta[10] != TRACK_V2_REC or struct.unpack_from("<H", meta, 11)[0] != TRACK_V2_SAMPLES_PER_PAGE:
            failures.append(f"L{level:02d}: Track V4 stride/page metadata mismatch")
        first_off = SECTOR
        second_off = first_off + len(pages1) * PAGE
        if blob[first_off:second_off] != b"".join(pages1):
            failures.append(f"L{level:02d}: first Track V4 pages mismatch")
        if blob[second_off : second_off + len(pages2) * PAGE] != b"".join(pages2):
            failures.append(f"L{level:02d}: second Track V4 pages mismatch")
        for chain_name, count, pages in (
            ("first", count1, pages1),
            ("second", count2, pages2),
        ):
            joined = b"".join(pages)
            known_meta = TRACK_V4_META_VX_SIGN | TRACK_V4_META_VY_SIGN | TRACK_V4_META_VISIBLE
            for sample in range(count):
                rec = sample * TRACK_V2_REC
                expected_phase = ((sample * TRACK_SPIN12_K) >> 8) % TRACK_SPIN12_PHASES
                if joined[rec + 6] != expected_phase or joined[rec + 7] & ~known_meta:
                    failures.append(
                        f"L{level:02d} {chain_name} sample {sample}: "
                        f"spin/meta={joined[rec + 6:rec + 8].hex()}"
                    )
                    break
        if blob[: len(expected)] != expected:
            failures.append(f"L{level:02d}: full track blob mismatch")
        if any(blob[len(expected) :]):
            failures.append(f"L{level:02d}: track section padding is not zero")
        print(
            f"L{level:02d}: track section {size}s, "
            f"first={count1}/{len(pages1)}p, second={count2}/{len(pages2)}p"
        )

    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print("PASS: two-track level sections contain both tracks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
