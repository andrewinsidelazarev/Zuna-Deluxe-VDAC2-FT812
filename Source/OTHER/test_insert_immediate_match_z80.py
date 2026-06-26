#!/usr/bin/env python3
"""Regression: VDC_InsertAt must trigger match immediately, before offset decay."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def max_slots(sim):
    s = sim.sym
    return s["Core.VDC_Offsets"] - s["Core.VDC_Slots"]


def reset_gap_state(sim):
    s = sim.sym
    if "Core.VDC_GapAccum" in s:
        sim.set_byte(s["Core.VDC_GapAccum"], 0)
        sim.set_byte(s["Core.VDC_GapAccum"] + 1, 0)
    for name in (
        "Core.VDC_GapJunction",
        "Core.VDC_GapDecAcc",
        "Core.VDC_GapPosLeft",
    ):
        if name in s:
            sim.set_byte(s[name], 0)
    for name in ("Core.VDC_GapPullVp", "Core.VDC_GapTempo"):
        if name in s:
            sim.set_byte(s[name], 1)


def clear_state(sim):
    s = sim.sym
    for base_name in (
        "Core.VDC_Slots",
        "Core.VDC_Offsets",
        "Core.VDC_Shot2",
        "Core.VDC_ExplodeFrame",
        "Core.VDC_ExplodeMarker",
    ):
        base = s[base_name]
        for i in range(max_slots(sim)):
            sim.set_byte(base + i, 0)


def setup_pair(sim):
    s = sim.sym
    clear_state(sim)
    slots = [1, 2, 2, 3]
    offsets = [0, 0, 0, 0]
    for i, value in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, value)
    for i, value in enumerate(offsets):
        sim.set_byte(s["Core.VDC_Offsets"] + i, value & 0xFF)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_HSA"], 12)
    sim.set_byte(s["Core.VDC_HSA"] + 1, 0)
    sim.set_byte(s["Core.VDC_HSub"], 0)
    sim.set_byte(s["Core.VDC_TrackNumSlots"], 85)
    sim.set_byte(s["Core.VDC_TrackNumSlots"] + 1, 0)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    reset_gap_state(sim)
    sim.set_byte(s["Core.VDC_MatchScanIdx"], 0)
    for name in ("Core.VDC_StatCombos", "Core.VDC_StatMaxCombo",
                 "Core.VDC_StatMaxChain", "Core.VDC_StatChainCount",
                 "Core.VDC_GaugeFull"):
        if name in s:
            sim.set_byte(s[name], 0)
    if "Core.VDC_StatPrevMatchColor" in s:
        sim.set_byte(s["Core.VDC_StatPrevMatchColor"], 0xFF)


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    setup_pair(sim)

    sim.call(s["Core.VDC_InsertAt"], a=1, b=2)

    ln = sim.get_byte(s["Core.VDC_SlotsLen"])
    slots = [sim.get_byte(s["Core.VDC_Slots"] + i) for i in range(ln)]
    offsets = [sim.get_byte(s["Core.VDC_Offsets"] + i) for i in range(ln)]
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(ln)]

    print(f"after insert: len={ln} slots={slots} offsets={offsets} frames={frames}")
    if ln != 5 or slots[1:4] != [2, 2, 2] or frames[1:4] != [1, 1, 1]:
        print("FAIL: insert-created match did not explode immediately")
        sys.exit(1)
    print("PASS: insert-created match explodes immediately before decay")


if __name__ == "__main__":
    main()
