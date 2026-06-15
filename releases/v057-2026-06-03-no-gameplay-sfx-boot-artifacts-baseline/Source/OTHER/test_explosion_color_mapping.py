#!/usr/bin/env python3
"""Static regression: destroy tint color must match the exploding ball color."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "Source" / "ASM" / "MainLoop.asm"

BALL_RGB = [
    (130, 200, 255),
    (60, 255, 80),
    (255, 70, 60),
    (255, 230, 30),
    (255, 90, 240),
    (255, 255, 255),
]

EXPLOSION_RGB = [
    (48, 120, 255),
    (64, 255, 80),
    (255, 72, 48),
    (255, 220, 0),
    (210, 80, 255),
    (255, 255, 255),
]


def extract_table(text: str, label: str) -> list[tuple[int, int, int]]:
    match = re.search(rf"{label}:(.*?)(?=\n\S|\Z)", text, re.S)
    if not match:
        raise AssertionError(f"{label}: not found")
    nums: list[int] = []
    for line in match.group(1).splitlines():
        if line.lstrip().startswith("DEFB"):
            data = line.split(";", 1)[0]
            nums.extend(int(x) for x in re.findall(r"\b\d+\b", data))
    if len(nums) != 18:
        raise AssertionError(f"{label}: expected 18 bytes, got {len(nums)}")
    return [tuple(nums[i : i + 3]) for i in range(0, len(nums), 3)]


def main() -> int:
    text = MAIN.read_text(encoding="utf-8")
    if "ARGB4 atlas: cell = color*16 + spin" not in text:
        raise AssertionError("ARGB4 explosion color extraction comment is missing")
    if "RRCA : RRCA : RRCA : RRCA" not in text:
        raise AssertionError("ARGB4 explosion color extraction must shift cell >> 4")

    ball_table = extract_table(text, "ZL_BallColorRGB")
    explosion_table = extract_table(text, "ZL_ExplosionRGBTable")
    if ball_table != BALL_RGB:
        raise AssertionError(f"unexpected ball RGB table: {ball_table}")
    if explosion_table != EXPLOSION_RGB:
        raise AssertionError(f"unexpected explosion RGB table: {explosion_table}")

    root = Path(__file__).resolve().parents[2]
    atlas = root / "Graphics" / "Converted" / "destroy_atlas.bin"
    data = atlas.read_bytes()
    expected = 13 * 48 * 48 * 2          # match-3 animBallDestroy: 13 кадров 48x48 ARGB4
    if len(data) != expected:
        print(f"FAIL: destroy_atlas.bin size {len(data)} != {expected} (13x48x48 ARGB4)")
        return 1

    print("PASS: explosion color mapping follows ball color order; destroy atlas is 13x48x48 ARGB4")
    return 0


if __name__ == "__main__":
    sys.exit(main())
