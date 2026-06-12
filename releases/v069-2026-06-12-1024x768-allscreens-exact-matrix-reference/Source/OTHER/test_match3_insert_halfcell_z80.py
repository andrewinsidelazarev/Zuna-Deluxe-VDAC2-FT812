#!/usr/bin/env python3
"""Regression: a fresh half-cell insert must count as legal match-3.

VDC_InsertAt places the new ball at -CELL_SIZE/2 between neighbors.  The match
detector must therefore accept a +CELL_SIZE/2 offset delta on the head-side
neighbor; otherwise shooting after a same-color pair fails to trigger match-3.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


CELL_SIZE = 32
HALF = CELL_SIZE // 2


def clear_state(sim, slots, offsets, idx):
    s = sim.sym
    for base_name in (
        "Core.VDC_Slots",
        "Core.VDC_Offsets",
        "Core.VDC_Shot2",
        "Core.VDC_ExplodeFrame",
        "Core.VDC_ExplodeMarker",
    ):
        base = s[base_name]
        for i in range(240):
            sim.set_byte(base + i, 0)

    for i, value in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, value)
    for i, value in enumerate(offsets):
        sim.set_byte(s["Core.VDC_Offsets"] + i, value & 0xFF)

    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_TmpInsIdx"], idx)
    for name in ("Core.VDC_StatCombos", "Core.VDC_StatMaxCombo",
                 "Core.VDC_StatMaxChain", "Core.VDC_StatPrevMatchColor",
                 "Core.VDC_GaugeFull"):
        if name in s:
            sim.set_byte(s[name], 0)
    for name in ("Core.VDC_StatTimeFrames", "Core.VDC_GaugeScore",
                 "Core.VDC_PlayerScore"):
        if name in s:
            sim.set_byte(s[name], 0)
            sim.set_byte(s[name] + 1, 0)


def run_case(sim, name, slots, offsets, idx):
    s = sim.sym
    clear_state(sim, slots, offsets, idx)
    sim.call(s.get("VDC_CheckMatch3", s.get("Core.VDC_CheckMatch3")))
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(len(slots))]
    ok = all(frame == 1 for frame in frames)
    print(f"{name}: frames={frames} expected all 1")
    return ok


def main():
    sim = ZumaZ80Sim()
    cases = [
        ("insert before pair", [2, 2, 2], [-HALF, 0, 0], 0),
        ("insert after pair",  [2, 2, 2], [0, 0, -HALF], 2),
    ]
    failed = False
    for case in cases:
        if not run_case(sim, *case):
            failed = True
    if failed:
        print("FAIL: fresh insert half-cell match did not trigger")
        sys.exit(1)
    print("ALL PASS: fresh insert half-cell match triggers on both sides")


if __name__ == "__main__":
    main()
