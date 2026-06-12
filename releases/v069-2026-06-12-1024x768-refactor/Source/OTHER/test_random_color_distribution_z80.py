#!/usr/bin/env python3
"""Regression: VDC_RandomColor must produce all 6 colors without strong skew."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


def main():
    sim = ZumaZ80Sim()
    s = sim.sym
    seed = s["Core.VDC_LfsrSeed"]
    sim.set_byte(seed, 0xE1)
    sim.set_byte(seed + 1, 0xAC)

    counts = [0] * 6
    for _ in range(600):
        sim.call(s.get("VDC_RandomColor", s.get("Core.VDC_RandomColor")))
        color = sim.cpu.a
        if color >= 6:
            print(f"FAIL: color out of range: {color}")
            sys.exit(1)
        counts[color] += 1

    print(f"counts={counts}")
    if not all(count > 0 for count in counts):
        print("FAIL: not all colors appeared")
        sys.exit(1)
    if min(counts) < 60 or max(counts) > 140:
        print("FAIL: distribution is too skewed for 600 deterministic calls")
        sys.exit(1)
    print("PASS: all 6 colors present and distribution is sane")


if __name__ == "__main__":
    main()
