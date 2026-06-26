#!/usr/bin/env python3
"""Regression: Shot2 cleanup must keep pending inserts and clear stale markers."""
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


def setup_chain(sim, slots, offsets, shot2_idx):
    s = sim.sym
    clear_arrays(sim)
    for i, color in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    for i, off in enumerate(offsets):
        sim.set_byte(s["Core.VDC_Offsets"] + i, off & 0xFF)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    reset_gap_state(sim)
    sim.set_byte(s["Core.VDC_MatchScanIdx"], shot2_idx)
    sim.set_byte(s["Core.VDC_Shot2"] + shot2_idx, 1)


def pending_shot2_survives_until_match(sim):
    s = sim.sym
    setup_chain(sim, [1, 2, 2, 2, 3], [0, 0, -32, 0, 0], 2)

    first_shot2 = sim.get_byte(s["Core.VDC_Shot2"] + 2)
    matched_at = None
    for frame in range(1, 12):
        sim.call(s["Core.VDC_AnimateChain"])
        frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(1, 4)]
        if all(v == 1 for v in frames):
            matched_at = frame
            break

    print(f"pending: first_shot2={first_shot2} matched_at={matched_at}")
    return first_shot2 == 1 and matched_at is not None


def stale_shot2_clears_when_settled(sim):
    s = sim.sym
    setup_chain(sim, [1, 2, 3, 4], [0, 0, 0, 0], 1)

    sim.call(s["Core.VDC_AnimateChain"])
    shot2 = [sim.get_byte(s["Core.VDC_Shot2"] + i) for i in range(4)]

    print(f"stale: shot2={shot2}")
    return shot2 == [0, 0, 0, 0]


def main():
    sim = ZumaZ80Sim()
    failed = False
    if not pending_shot2_survives_until_match(sim):
        print("FAIL: pending Shot2 was cleared before legal match")
        failed = True
    if not stale_shot2_clears_when_settled(sim):
        print("FAIL: stale Shot2 was not cleared")
        failed = True
    if failed:
        sys.exit(1)
    print("ALL PASS: Shot2 cleanup keeps pending markers and clears stale markers")


if __name__ == "__main__":
    main()
