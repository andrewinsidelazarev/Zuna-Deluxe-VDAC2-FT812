#!/usr/bin/env python3
"""Verify Track V4 baked spin phases against the former Z80 calculation."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import (  # noqa: E402
    TRACK_SPIN12_K,
    TRACK_SPIN12_PHASES,
    TRACK_V4_META_VISIBLE,
    TRACK_V4_META_VX_SIGN,
    TRACK_V4_META_VY_SIGN,
    encode_track_v2_pages,
    scale_track_samples,
)
ROOT = HERE.parent.parent
TRACK = ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l19_640.bin"
SAMPLES_PER_PAGE = 2048
RECORD_BYTES = 8


def legacy_spin12(sample: int) -> int:
    """Independent equivalent of the removed Z80 high/low-byte algorithm."""
    high = (sample >> 8) & 0xFF
    low_product_high = ((sample & 0xFF) * 61) >> 8
    phase = high + low_product_high
    while phase >= 12:
        phase -= 12
    return phase


def main() -> int:
    scaled = scale_track_samples(TRACK.read_bytes())
    assert scaled is not None
    count, pages = encode_track_v2_pages(scaled)

    for sample in range(count):
        page = pages[sample // SAMPLES_PER_PAGE]
        offset = (sample % SAMPLES_PER_PAGE) * RECORD_BYTES
        baked = page[offset + 6]
        meta = page[offset + 7]
        expected = ((sample * TRACK_SPIN12_K) >> 8) % TRACK_SPIN12_PHASES
        if baked != expected:
            raise AssertionError(f"sample {sample}: baked {baked} != {expected}")
        known_meta = TRACK_V4_META_VX_SIGN | TRACK_V4_META_VY_SIGN | TRACK_V4_META_VISIBLE
        if meta & ~known_meta:
            raise AssertionError(f"sample {sample}: unknown Track V4 meta bits {meta:#04x}")
        legacy = legacy_spin12(sample)
        if legacy != baked:
            raise AssertionError(
                f"sample {sample}: legacy phase {legacy} != baked {baked}"
            )

    print(f"PASS: {count} Track V4 samples contain exact legacy spin12 phases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
