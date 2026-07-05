#!/usr/bin/env python3
"""Exhaustive regression for the frog aim ratio divider.

Frog_ComputeAngle needs t = floor(min(|dx|, |dy|) * 128 / max(|dx|, |dy|)).
The ASM helper is intentionally specialized to that domain: 1 <= max <= 255
and 0 <= min <= max. This test covers the full input space used by the frog.
"""

from __future__ import annotations

import os
import sys
import math


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


def angle_brad(dx: int, dy: int) -> int:
    deg = math.degrees(math.atan2(dy, dx))
    brad = int(round((deg % 360.0) * 256.0 / 360.0)) & 0xFF
    return brad


def angle_diff(a: int, b: int) -> int:
    d = abs((a - b) & 0xFF)
    return min(d, 256 - d)


def main() -> int:
    emu = ZumaFullZ80Emulator()
    sym = emu.sym["Core.Frog_Div16by8"]

    checked = 0
    worst_tstates = 0
    worst_case = None

    for divisor in range(1, 256):
        for numerator in range(divisor + 1):
            before = emu.tstates
            emu.call(sym, c=divisor, e=numerator, max_steps=1000)
            delta = emu.tstates - before
            got = emu.reg.A
            expected = (numerator * 128) // divisor
            checked += 1
            if got != expected:
                print(
                    "FAIL: "
                    f"min={numerator} max={divisor} got={got} expected={expected}"
                )
                return 1
            if delta > worst_tstates:
                worst_tstates = delta
                worst_case = (numerator, divisor, got)

    print(
        "PASS: Frog_Div16by8 exact for "
        f"{checked} frog ratio inputs; worst={worst_tstates} tstates "
        f"at min={worst_case[0]} max={worst_case[1]} q={worst_case[2]}"
    )

    S = emu.sym
    frog_x = 327
    frog_y = 231
    far_cases = [
        (frog_x + 600, frog_y + 300),
        (frog_x + 600, frog_y - 180),
        (frog_x - 300, frog_y + 500),
        (frog_x - 320, frog_y - 220),
        (frog_x + 696, frog_y + 536),
        (frog_x - 326, frog_y + 536),
    ]
    for target_x, target_y in far_cases:
        dx = target_x - frog_x
        dy = target_y - frog_y
        expected = angle_brad(dx, dy)
        emu.set_word(S["Core.Frog_PosStartX"], frog_x)
        emu.set_word(S["Core.Frog_PosStartY"], frog_y)
        emu.set_word(S["Core.ZL_SmoothX"], target_x & 0xFFFF)
        emu.set_word(S["Core.ZL_SmoothY"], target_y & 0xFFFF)
        emu.set_byte(S["Core.Frog_Angle"], (expected + 16) & 0xFF)
        emu.call(S["Core.Frog_ComputeAngle"], max_steps=5000)
        got = emu.get_byte(S["Core.Frog_Angle"])
        if angle_diff(got, expected) > 2:
            print(
                "FAIL: Frog_ComputeAngle far target "
                f"dx={dx} dy={dy} got={got} expected≈{expected}"
            )
            return 1

    print(f"PASS: Frog_ComputeAngle preserves far-target ratios ({len(far_cases)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
