#!/usr/bin/env python3
"""Differential oracle for gap target selection and internal-gap carry."""
from __future__ import annotations

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import RETURN_MARKER, ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
STOP = 0xFE
CASCADE = 0xFD
NUM_COLORS = 6


def call_with_hits(
    emu: ZumaFullZ80Emulator,
    addr: int,
    hit_addr: int,
    *,
    initial_carry: int = 0,
    max_steps: int = 100_000,
) -> int:
    for reg in ("A", "B", "C", "D", "E", "H", "L"):
        setattr(emu.reg, reg, 0)
    emu.reg.F = (emu.reg.F & ~1) | (initial_carry & 1)
    sp = (emu.reg.SP - 2) & 0xFFFF
    emu.set_word(sp, RETURN_MARKER)
    emu.reg.SP = sp
    emu.reg.PC = addr
    hits = 0
    steps = 0
    while emu.reg.PC != RETURN_MARKER:
        if emu.reg.PC == hit_addr:
            hits += 1
        emu.step()
        steps += 1
        if steps > max_steps:
            raise TimeoutError(f"timeout at PC={emu.reg.PC:#06x}")
    return hits


def internal_gap(values: list[int]) -> bool:
    seen_live = False
    seen_marker = False
    for value in values:
        if value < NUM_COLORS:
            if seen_marker:
                return True
            seen_live = True
        elif seen_live:
            seen_marker = True
    return False


def junction(values: list[int]) -> int:
    target = next((i for i in range(len(values) - 1, -1, -1) if values[i] == STOP), None)
    if target is None:
        target = next((i for i, value in enumerate(values) if value == CASCADE), None)
    if target is None:
        return 0

    left = target - 1
    while left >= 0 and values[left] >= NUM_COLORS:
        left -= 1
    if left < 0:
        return 2

    right = target + 1
    while right < len(values) and values[right] >= NUM_COLORS:
        right += 1
    if right >= len(values):
        return 2
    if values[right] != values[left]:
        return 2
    if any(value >= NUM_COLORS for value in values[:left]):
        return 2
    return 1


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    emu.call(s["Core.VDC_SelectChain1"], max_steps=20_000)
    slots = s["Core.VDC_Slots"]

    fixed = [
        [],
        [0],
        [STOP, 0],
        [0, STOP],
        [0, STOP, 0],
        [1, CASCADE, 1, STOP, 2, STOP, 2],
        [2, CASCADE, 1, CASCADE, 2],
        [0, CASCADE, CASCADE, 0],
        [STOP, CASCADE, 0, CASCADE, 0],
    ]
    rng = random.Random(0x19CACE)
    cases = fixed + [
        [rng.choice((0, 1, 2, STOP, CASCADE)) for _ in range(rng.randrange(1, 13))]
        for _ in range(300)
    ]

    for index, values in enumerate(cases):
        emu.set_byte(s["Core.VDC_SlotsLen"], len(values))
        for offset, value in enumerate(values):
            emu.set_byte(slots + offset, value)

        emu.call(s["Core.VDC_GapJunctionUpdate"], max_steps=100_000)
        got_junction = emu.get_byte(s["Core.VDC_GapJunction"])
        expected_junction = junction(values)
        if got_junction != expected_junction:
            raise AssertionError(
                f"case {index} {values}: junction {got_junction} != {expected_junction}"
            )

        emu.call(s["Core.VDC_MarkTopologyDirty"], max_steps=10_000)
        emu.set_byte(s["Core.VDC_GapJunction"], 0xA5)
        hits = call_with_hits(
            emu,
            s["Core.VDC_EnsureGapJunction"],
            s["Core.VDC_GapJunctionUpdate"],
        )
        if hits != 1 or emu.get_byte(s["Core.VDC_GapJunction"]) != expected_junction:
            raise AssertionError(f"case {index} {values}: junction cache miss is wrong")
        hits = call_with_hits(
            emu,
            s["Core.VDC_EnsureGapJunction"],
            s["Core.VDC_GapJunctionUpdate"],
        )
        if hits != 0 or emu.get_byte(s["Core.VDC_GapJunction"]) != expected_junction:
            raise AssertionError(f"case {index} {values}: junction cache did not hit")

        emu.call(s["Core.VDC_InternalGapExists"], max_steps=100_000)
        got_internal = bool(emu.reg.F & 1)
        expected_internal = internal_gap(values)
        if got_internal != expected_internal:
            raise AssertionError(
                f"case {index} {values}: internal {got_internal} != {expected_internal}"
            )

        emu.call(s["Core.VDC_MarkTopologyDirty"], max_steps=10_000)
        emu.set_byte(s["Core.VDC_GapJunction"], 0xA5)
        opposite_carry = 0 if expected_internal else 1
        hits = call_with_hits(
            emu,
            s["Core.VDC_InternalGapExistsCached"],
            s["Core.VDC_InternalGapExists"],
            initial_carry=opposite_carry,
        )
        if hits != 1 or bool(emu.reg.F & 1) != expected_internal:
            raise AssertionError(f"case {index} {values}: internal cache miss is wrong")
        if emu.get_byte(s["Core.VDC_GapJunction"]) != 0xA5:
            raise AssertionError("internal-gap refresh changed junction too early")
        hits = call_with_hits(
            emu,
            s["Core.VDC_InternalGapExistsCached"],
            s["Core.VDC_InternalGapExists"],
            initial_carry=opposite_carry,
        )
        if hits != 0 or bool(emu.reg.F & 1) != expected_internal:
            raise AssertionError(f"case {index} {values}: internal cache did not hit")

    # MoveChain queries InternalGap before Animate updates GapJunction. A cache
    # miss in the first query must not advance the junction by one frame.
    values = [0, STOP, 1]
    emu.set_byte(s["Core.VDC_SlotsLen"], len(values))
    for offset, value in enumerate(values):
        emu.set_byte(slots + offset, value)
    emu.set_byte(s["Core.VDC_GapJunction"], 1)
    emu.call(s["Core.VDC_MarkTopologyDirty"], max_steps=10_000)
    emu.call(s["Core.VDC_InternalGapExistsCached"], max_steps=100_000)
    if emu.get_byte(s["Core.VDC_GapJunction"]) != 1:
        raise AssertionError("InternalGap updated GapJunction before the Animate phase")
    emu.call(s["Core.VDC_EnsureGapJunction"], max_steps=100_000)
    if emu.get_byte(s["Core.VDC_GapJunction"]) != 2:
        raise AssertionError("GapJunction was not refreshed in its own phase")

    print(
        f"PASS: {len(cases)} gap layouts match raw/cached selection, carry, and phase semantics"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
