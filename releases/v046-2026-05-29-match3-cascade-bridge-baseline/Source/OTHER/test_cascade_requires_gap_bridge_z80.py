#!/usr/bin/env python3
"""Regression: cascade не должен матчить run, если gap был рядом, а не между шарами."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


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
        for i in range(240):
            sim.set_byte(base + i, 0)


def setup(sim, slots, shot2_idx, bridge_k):
    s = sim.sym
    clear_arrays(sim)
    for i, color in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_HSA"], len(slots) - 1)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    sim.set_byte(s["Core.VDC_GapStepCnt"], 0)
    sim.set_byte(s["Core.VDC_MatchScanIdx"], bridge_k)
    sim.set_byte(s["Core.VDC_Shot2"] + shot2_idx, 1)


def explode_frames(sim, count):
    s = sim.sym
    return [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(count)]


def main():
    sim = ZumaZ80Sim()
    s = sim.sym

    # Нелегально: K=3, gap закрылся между index 2 и 3, а run 0..2 целиком слева.
    setup(sim, [2, 2, 2, 1, 1], shot2_idx=2, bridge_k=3)
    sim.call(s["Core.VDC_ScanForNewMatch"])
    frames = explode_frames(sim, 5)
    print(f"illegal-near frames={frames}")
    if any(frames):
        print("FAIL: cascade matched a run next to the gap, not across it")
        sys.exit(1)

    # Легально: K=2, run 1..3 пересекает закрытую границу 1/2.
    setup(sim, [0, 2, 2, 2, 1], shot2_idx=1, bridge_k=2)
    sim.call(s["Core.VDC_ScanForNewMatch"])
    frames = explode_frames(sim, 5)
    print(f"legal-bridge frames={frames}")
    if frames[1:4] != [1, 1, 1]:
        print("FAIL: cascade did not match a run across the gap")
        sys.exit(1)

    print("PASS: cascade match requires the gap to be between matched balls")


if __name__ == "__main__":
    main()
