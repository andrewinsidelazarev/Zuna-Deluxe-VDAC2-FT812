#!/usr/bin/env python3
"""Regression: новый match не должен стирать pending Shot2 от закрытого gap."""
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


def clear_arrays(sim):
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


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    clear_arrays(sim)

    # [0..2] = готовая тройка, но она ещё физически съезжается после gap:
    # Shot2 должен пережить независимый match [5..7].
    slots = [1, 1, 1, 0, 2, 3, 3, 3, 2, 0]
    offsets = [32, 32, 0, 0, 0, 0, 0, 0, 0, 0]
    for i, color in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    for i, off in enumerate(offsets):
        sim.set_byte(s["Core.VDC_Offsets"] + i, off & 0xFF)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_HSA"], len(slots) - 1)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    reset_gap_state(sim)
    sim.set_byte(s["Core.VDC_Shot2"] + 1, 1)
    sim.call(s["Core.VDC_MarkShot2Maybe"])
    sim.set_byte(s["Core.VDC_TmpInsIdx"], 6)

    sim.call(s["Core.VDC_CheckMatch3"])
    kept = sim.get_byte(s["Core.VDC_Shot2"] + 1)
    print(f"Shot2[1] after independent match: {kept}")
    if kept != 1:
        print("FAIL: pending Shot2 was cleared by a new match")
        sys.exit(1)

    matched_at = None
    for frame in range(1, 140):
        sim.call(s["Core.VDC_AnimateChain"])
        frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(3)]
        if all(v == 1 for v in frames):
            matched_at = frame
            break

    print(f"pending match fired at frame: {matched_at}")
    if matched_at is None:
        print("FAIL: preserved pending Shot2 did not fire legal match")
        sys.exit(1)

    print("PASS: pending Shot2 survives new match and fires later")


if __name__ == "__main__":
    main()
