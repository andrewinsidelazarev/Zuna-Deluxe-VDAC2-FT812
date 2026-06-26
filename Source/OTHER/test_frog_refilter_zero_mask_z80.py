#!/usr/bin/env python3
"""Regression for Frog_FilteredRandomColor with marker-only chains.

When VDC_SlotsLen is non-zero but all slots are gap/cascade markers
(slot >= VDC_NUM_COLORS), the live color mask is zero. Refilter must treat that
like an empty chain: keep an already-valid frog color, and only generate once
when the input color is invalid (0xFF).
"""

from __future__ import annotations

import os
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


def require_symbols(emu: ZumaFullZ80Emulator, names: tuple[str, ...]) -> bool:
    missing = [name for name in names if name not in emu.sym]
    if missing:
        print("FAIL: missing symbols: " + ", ".join(missing))
        return False
    return True


def set_slots(emu: ZumaFullZ80Emulator, slots: list[int]) -> None:
    s = emu.sym
    slots_addr = s["Core.VDC_Slots"]
    emu.set_word(s["Core.VDC_pSlots"], slots_addr)
    emu.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    for i, value in enumerate(slots):
        emu.set_byte(slots_addr + i, value)


def colors(emu: ZumaFullZ80Emulator) -> tuple[int, int]:
    s = emu.sym
    return (
        emu.get_byte(s["Core.Frog_BallColor"]),
        emu.get_byte(s["Core.Frog_NextBallColor"]),
    )


def set_colors(emu: ZumaFullZ80Emulator, ball: int, next_ball: int) -> None:
    s = emu.sym
    emu.set_byte(s["Core.Frog_BallColor"], ball)
    emu.set_byte(s["Core.Frog_NextBallColor"], next_ball)


def call_refilter(emu: ZumaFullZ80Emulator, count: int = 1) -> None:
    for _ in range(count):
        emu.call(emu.sym["Frog_RefilterCurrent"], max_steps=200_000)


def main() -> int:
    emu = ZumaFullZ80Emulator()
    needed = (
        "Frog_RefilterCurrent",
        "Core.VDC_NUM_COLORS",
        "Core.VDC_Slots",
        "Core.VDC_pSlots",
        "Core.VDC_SlotsLen",
        "Core.Frog_BallColor",
        "Core.Frog_NextBallColor",
    )
    if not require_symbols(emu, needed):
        return 1

    ncolors = emu.sym["Core.VDC_NUM_COLORS"]
    marker_only = [0xFD, 0xFE, 0xFD, 0xFE]
    set_slots(emu, marker_only)

    set_colors(emu, 2, 5)
    call_refilter(emu, 16)
    if colors(emu) != (2, 5):
        print(f"FAIL: valid colors changed on zero live-color mask: {colors(emu)}")
        return 1

    set_colors(emu, 0xFF, 0xFF)
    call_refilter(emu, 1)
    first = colors(emu)
    if first[0] >= ncolors or first[1] >= ncolors:
        print(f"FAIL: invalid colors did not become valid: {first}")
        return 1
    call_refilter(emu, 16)
    if colors(emu) != first:
        print(f"FAIL: generated colors were not stable on zero live-color mask: {first} -> {colors(emu)}")
        return 1

    set_slots(emu, [1, 0xFD, 3, 0xFE])
    set_colors(emu, 2, 3)
    call_refilter(emu, 1)
    ball, next_ball = colors(emu)
    if ball not in (1, 3) or next_ball != 3:
        print(f"FAIL: nonzero mask filtering broke: got {ball}/{next_ball}")
        return 1

    print("PASS: Frog_RefilterCurrent keeps colors stable for marker-only zero masks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
