#!/usr/bin/env python3
"""Проверка глобального шага движения цепочки в ASM.

После рефактора скоростей (v067): VDC_MoveChain двигает HSub на 1 sample за
вызов (плавный шаг); глобальный ×2 достигается ДВУМЯ тиками VDC_SpeedAdvance
за кадр (VDC_GLOBAL_SPEED_FACTOR), а перуровневый темп — speed_x100-аккумом.
- 0 -> 1 без изменения HSA;
- 31 -> 0 с HSA+1.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim


CELL_SIZE = 32


def main() -> int:
    sim = ZumaZ80Sim()
    s = sim.sym

    sim.call(s["Core.VDC_Init"])
    sim.set_byte(s["Core.VDC_TrackNumSlots"], 85)
    sim.set_byte(s["Core.VDC_TrackNumSlots"] + 1, 0)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    sim.set_byte(s["Core.VDC_HSA"], 10)
    sim.set_byte(s["Core.VDC_HSub"], 0)

    sim.call(s["Core.VDC_MoveChain"])
    got = (sim.get_byte(s["Core.VDC_HSA"]), sim.get_byte(s["Core.VDC_HSub"]))
    exp = (10, 1)
    print(f"move normal: got HSA={got[0]} HSub={got[1]}, expected HSA={exp[0]} HSub={exp[1]}")
    if got != exp:
        return 1

    sim.set_byte(s["Core.VDC_HSA"], 10)
    sim.set_byte(s["Core.VDC_HSub"], CELL_SIZE - 1)
    sim.call(s["Core.VDC_MoveChain"])
    got = (sim.get_byte(s["Core.VDC_HSA"]), sim.get_byte(s["Core.VDC_HSub"]))
    exp = (11, 0)
    print(f"move wrap:   got HSA={got[0]} HSub={got[1]}, expected HSA={exp[0]} HSub={exp[1]}")
    if got != exp:
        return 1

    print("PASS: VDC_MoveChain global step is 1 sample (×2 — это два тика SpeedAdvance)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
