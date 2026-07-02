#!/usr/bin/env python3
"""Regression: VDC_ExplodeActive tracks pending match-3 animations."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def sym(sim, name):
    return sim.sym.get(name, sim.sym.get(f"Core.{name}"))


def reset_vdc_state(sim, chain):
    s = sim.sym
    for addr in (
        s["Core.VDC_Slots"],
        s["Core.VDC_Offsets"],
        s["Core.VDC_Shot2"],
        s["Core.VDC_ExplodeFrame"],
        s["Core.VDC_ExplodeMarker"],
    ):
        for i in range(240):
            sim.set_byte(addr + i, 0)
    for i, c in enumerate(chain):
        sim.set_byte(s["Core.VDC_Slots"] + i, c)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(chain))
    sim.set_byte(s["Core.VDC_TmpInsIdx"], 2)
    sim.set_byte(s["Core.VDC_ExplodeActive"], 0)
    for k in (
        "Core.VDC_ChainFreezeCnt",
        "Core.VDC_GapJunction",
        "Core.VDC_GapAccum",
        "Core.VDC_GapAccum+1",
        "Core.VDC_GapDecAcc",
        "Core.VDC_GaugeFull",
    ):
        if k in s:
            sim.set_byte(s[k], 0)
    for w in ("Core.VDC_GaugeScore", "Core.VDC_PlayerScore"):
        if w in s:
            sim.set_byte(s[w], 0)
            sim.set_byte(s[w] + 1, 0)


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    reset_vdc_state(sim, [4, 1, 1, 1, 5])

    sim.call(sym(sim, "VDC_CheckMatch3"))
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(1, 4)]
    active = sim.get_byte(s["Core.VDC_ExplodeActive"])
    print(f"after match: active={active} frames={frames}")
    if active != 1 or frames != [1, 1, 1]:
        print("FAIL: VDC_ExplodeActive was not set with ExplodeFrame")
        return 1

    for _ in range(14):
        sim.call(sym(sim, "VDC_AnimateChain"))
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(1, 4)]
    active = sim.get_byte(s["Core.VDC_ExplodeActive"])
    print(f"before final clear: active={active} frames={frames}")
    if active != 1 or frames != [15, 15, 15]:
        print("FAIL: VDC_ExplodeActive cleared before the last visible frame")
        return 1

    sim.call(sym(sim, "VDC_AnimateChain"))
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(1, 4)]
    slots = [sim.get_byte(s["Core.VDC_Slots"] + i) for i in range(1, 4)]
    active = sim.get_byte(s["Core.VDC_ExplodeActive"])
    print(f"after final clear: active={active} frames={frames} slots={slots}")
    if active != 0 or frames != [0, 0, 0] or slots != [0xFE, 0xFE, 0xFE]:
        print("FAIL: VDC_ExplodeActive did not clear with finalized explosion")
        return 1

    print("PASS: VDC_ExplodeActive follows match-3 explosion lifetime")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
