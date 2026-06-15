#!/usr/bin/env python3
"""Regression: CheckMatch3 must not arm neighbour Shot2 before gap closure."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def clear_state(sim, chain, idx):
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
    for i, color in enumerate(chain):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(chain))
    sim.set_byte(s["Core.VDC_TmpInsIdx"], idx)


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    chain = [2, 2, 2, 2, 3, 1, 1, 1, 4, 2, 2, 2, 2]
    clear_state(sim, chain, 6)
    sim.call(s.get("VDC_CheckMatch3", s.get("Core.VDC_CheckMatch3")))
    shot2 = [sim.get_byte(s["Core.VDC_Shot2"] + i) for i in range(len(chain))]
    print(f"Shot2 after CheckMatch3: {shot2}")
    if shot2[4] != 0 or shot2[8] != 0:
        print("FAIL: neighbour Shot2 armed before gap closure")
        sys.exit(1)
    print("PASS: neighbour Shot2 remains clear until DoGapStep")


if __name__ == "__main__":
    main()
