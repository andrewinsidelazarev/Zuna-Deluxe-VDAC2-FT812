#!/usr/bin/env python3
"""Regression: match должен брать весь непрерывный run одного цвета, а не 3 шара."""
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


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    clear_arrays(sim)

    # Четыре одинаковых шара подряд. Крайний справа ещё на rollback-offset,
    # но по правилу это всё равно один run цвета 2 и взрываться должны все 4.
    slots = [0, 2, 2, 2, 2, 1]
    offsets = [0, 0, 0, 0, 24, 0]
    for i, color in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    for i, off in enumerate(offsets):
        sim.set_byte(s["Core.VDC_Offsets"] + i, off & 0xFF)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_HSA"], len(slots) - 1)
    sim.set_byte(s["Core.VDC_TmpInsIdx"], 2)

    sim.call(s["Core.VDC_CheckMatch3"])
    frames = [sim.get_byte(s["Core.VDC_ExplodeFrame"] + i) for i in range(len(slots))]
    print(f"ExplodeFrame={frames}")
    if frames[1:5] != [1, 1, 1, 1]:
        print("FAIL: match did not include the full same-color run")
        sys.exit(1)
    print("PASS: full same-color run matched")


if __name__ == "__main__":
    main()
