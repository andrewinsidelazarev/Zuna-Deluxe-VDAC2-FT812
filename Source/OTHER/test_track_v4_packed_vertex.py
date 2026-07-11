#!/usr/bin/env python3
"""Prove Track V4 packed VERTEX2F and meta are lossless for every track."""
from __future__ import annotations

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import (  # noqa: E402
    LEVEL_COUNT,
    TRACK_SRC_HDR,
    TRACK_SRC_REC,
    TRACK_SPIN12_K,
    TRACK_SPIN12_PHASES,
    TRACK_V2_BALL_HALF,
    TRACK_V2_REC,
    TRACK_V4_META_VISIBLE,
    TRACK_V4_META_VX_SIGN,
    TRACK_V4_META_VY_SIGN,
    decode_track_v4_vertex,
    encode_track_v2_pages,
    encode_track_v4_record,
    scale_track_samples,
    track_files_for_level,
    track_v4_visible,
)

ROOT = HERE.parent.parent
SAMPLES_PER_PAGE = 2048


def signed16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def check_record(vx: int, vy: int, tangent: int, flags: int, spin12: int, record: bytes) -> None:
    got_vx, got_vy = decode_track_v4_vertex(record)
    if (got_vx, got_vy) != (vx, vy):
        raise AssertionError(f"decode ({got_vx},{got_vy}) != ({vx},{vy})")

    word = struct.unpack_from("<I", record, 0)[0]
    expected_word = 0x40000000 | ((vx & 0x7FFF) << 15) | (vy & 0x7FFF)
    if word != expected_word:
        raise AssertionError(f"VERTEX2F {word:#010x} != {expected_word:#010x}")
    if word & 0xC0000000 != 0x40000000:
        raise AssertionError(f"bad VERTEX2F opcode: {word:#010x}")
    if record[4:7] != bytes((tangent, flags, spin12)):
        raise AssertionError(
            f"tangent/flags/spin={record[4:7].hex()} expected="
            f"{bytes((tangent, flags, spin12)).hex()}"
        )

    meta = record[7]
    expected_meta = 0
    if vx < 0:
        expected_meta |= TRACK_V4_META_VX_SIGN
    if vy < 0:
        expected_meta |= TRACK_V4_META_VY_SIGN
    if track_v4_visible(vx, vy):
        expected_meta |= TRACK_V4_META_VISIBLE
    if meta != expected_meta:
        raise AssertionError(f"meta={meta:#04x} expected={expected_meta:#04x}")


def check_synthetic_boundaries() -> None:
    values = (-0x8000, -16385, -16384, -833, -832, -1, 0, 1, 12287, 12288, 16383, 16384, 17424, 0x7FFF)
    for vx in values:
        for vy in values:
            record = encode_track_v4_record(vx, vy, 0xA5, 0x83, 11)
            check_record(vx, vy, 0xA5, 0x83, 11, record)


def main() -> int:
    check_synthetic_boundaries()
    total = 0
    positive_x_overflow = 0
    page_crossings = 0

    for level_idx0 in range(LEVEL_COUNT):
        for track_path in track_files_for_level(level_idx0):
            scaled = scale_track_samples(track_path.read_bytes())
            assert scaled is not None
            count, pages = encode_track_v2_pages(scaled)
            source_count = struct.unpack_from("<H", scaled, 0)[0]
            if count != source_count:
                raise AssertionError(f"{track_path.name}: count {count} != {source_count}")

            for sample in range(count):
                source_off = TRACK_SRC_HDR + sample * TRACK_SRC_REC
                x, y, tangent, flags = struct.unpack_from("<hhBB", scaled, source_off)
                vx = (x - TRACK_V2_BALL_HALF) * 16
                vy = (y - TRACK_V2_BALL_HALF) * 16
                spin12 = ((sample * TRACK_SPIN12_K) >> 8) % TRACK_SPIN12_PHASES
                page_index, local = divmod(sample, SAMPLES_PER_PAGE)
                record_off = local * TRACK_V2_REC
                record = pages[page_index][record_off : record_off + TRACK_V2_REC]
                check_record(vx, vy, tangent, flags, spin12, record)
                total += 1
                positive_x_overflow += int(vx > 0x3FFF)
                page_crossings += int(local == 0 and sample != 0)

            tail = count % SAMPLES_PER_PAGE
            if tail and any(pages[-1][tail * TRACK_V2_REC :]):
                raise AssertionError(f"{track_path.name}: non-zero final page padding")

    if positive_x_overflow == 0:
        raise AssertionError("fixtures did not cover positive Vx beyond signed15")
    if page_crossings == 0:
        raise AssertionError("fixtures did not cover sample 2047/2048 page boundary")
    print(
        f"PASS: Track V4 packed VERTEX2F round-trips {total} samples; "
        f"positive_x_overflow={positive_x_overflow} page_crossings={page_crossings}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
