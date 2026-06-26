#!/usr/bin/env python3
"""Exhaustive regression for the frog aim ratio divider.

Frog_ComputeAngle needs t = floor(min(|dx|, |dy|) * 128 / max(|dx|, |dy|)).
The ASM helper is intentionally specialized to that domain: 1 <= max <= 255
and 0 <= min <= max. This test covers the full input space used by the frog.
"""

from __future__ import annotations

import os
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
