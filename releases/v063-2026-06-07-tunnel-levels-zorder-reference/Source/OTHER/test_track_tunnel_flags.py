#!/usr/bin/env python3
"""Verify 6-byte track samples and Loopy tunnel flags."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "pack"
REC = 6
TRACKF_TUNNEL = 0x01
TRACKF_DRAW_ABOVE = 0x02


def read_track(path: Path) -> tuple[int, bytes]:
    data = path.read_bytes()
    if len(data) < 2:
        raise AssertionError(f"{path.name}: too small")
    count = int.from_bytes(data[:2], "little")
    payload = data[2:]
    if len(payload) != count * REC:
        raise AssertionError(f"{path.name}: len={len(data)} count={count} is not 6-byte records")
    return count, payload


def main() -> int:
    failures: list[str] = []
    for path in sorted(ASSETS.glob("track_l*_640.bin")):
        try:
            count, payload = read_track(path)
        except AssertionError as exc:
            failures.append(str(exc))
            continue
        print(f"{path.name}: samples={count} bytes={len(payload) + 2}")

    try:
        count, payload = read_track(ASSETS / "track_l11_640.bin")
        flags = payload[5::REC]
        tunnel_count = sum(1 for f in flags if f & TRACKF_TUNNEL)
        above_count = sum(1 for f in flags if f & TRACKF_DRAW_ABOVE)
        if tunnel_count < 100:
            failures.append(f"L11: tunnel flag count too small: {tunnel_count}")
        if above_count < 100:
            failures.append(f"L11: draw-above flag count too small: {above_count}")
        print(f"L11 flags: tunnel={tunnel_count}/{count} drawAbove={above_count}/{count}")
    except AssertionError as exc:
        failures.append(str(exc))

    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print("PASS: tracks use 6-byte records and L11 tunnel flags survived conversion")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
