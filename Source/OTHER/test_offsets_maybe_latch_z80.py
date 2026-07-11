#!/usr/bin/env python3
"""Проверка per-chain защёлки возможных ненулевых offsets."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

GAP_STOP = 0xFE
ROOT = HERE.parent.parent


def set_word(sim: ZumaZ80Sim, address: int, value: int) -> None:
    sim.set_byte(address, value & 0xFF)
    sim.set_byte(address + 1, (value >> 8) & 0xFF)


def signed(value: int) -> int:
    return value - 256 if value >= 128 else value


class Rig:
    def __init__(self) -> None:
        self.sim = ZumaZ80Sim()
        self.sym = self.sim.sym
        self.sim.call(self.sym["Core.VDC_Init"])
        self.offset_bit = self.sym["Core.VDC_TOPO_OFFSETS_MAYBE"]

    def setup(self, slots: list[int], offsets: list[int] | None = None) -> None:
        if offsets is None:
            offsets = [0] * len(slots)
        if len(offsets) != len(slots):
            raise AssertionError("число offsets не совпадает с числом slots")
        s = self.sym
        z = self.sim
        z.set_byte(s["Core.VDC_GameState"], 0)
        z.set_byte(s["Core.VDC_SlotsLen"], len(slots))
        z.set_byte(s["Core.VDC_HSA"], 20)
        z.set_byte(s["Core.VDC_HSub"], 0)
        set_word(z, s["Core.VDC_TrackNumSlots"], 100)
        z.set_byte(s["Core.VDC_GaugeFull"], 1)
        z.set_byte(s["Core.VDC_LevelSpeed"], 75)
        z.set_byte(s["Core.VDC_GapJunction"], 0)
        z.set_byte(s["Core.VDC_GapPosLeft"], 0)
        z.set_byte(s["Core.VDC_GapDecAcc"], 0)
        z.set_byte(s["Core.VDC_GapTempo"], 10)
        z.set_byte(s["Core.VDC_GapPullVp"], 10)
        z.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
        set_word(z, s["Core.VDC_GapAccum"], 0)
        for index, (slot, offset) in enumerate(zip(slots, offsets, strict=True)):
            z.set_byte(s["Core.VDC_Slots"] + index, slot)
            z.set_byte(s["Core.VDC_Offsets"] + index, offset & 0xFF)
            z.set_byte(s["Core.VDC_Shot2"] + index, 0)
            z.set_byte(s["Core.VDC_ExplodeFrame"] + index, 0)
            z.set_byte(s["Core.VDC_ExplodeMarker"] + index, 0)
        z.call(s["Core.VDC_MarkTopologyDirty"])

    def topology(self, second: bool = False) -> int:
        name = "Core.VDC_TopologyState2" if second else "Core.VDC_TopologyState1"
        return self.sim.get_byte(self.sym[name])

    def offsets(self) -> list[int]:
        count = self.sim.get_byte(self.sym["Core.VDC_SlotsLen"])
        return [
            signed(self.sim.get_byte(self.sym["Core.VDC_Offsets"] + index))
            for index in range(count)
        ]


def check_decay_clear() -> None:
    rig = Rig()
    rig.setup([0, 1, 2], [0, -6, 0])
    rig.sim.call(rig.sym["Core.VDC_MarkOffsetsMaybe"])
    seen: list[tuple[int, bool]] = []
    for _ in range(3):
        rig.sim.call(rig.sym["Core.VDC_AnimateChain"])
        seen.append((rig.offsets()[1], bool(rig.topology() & rig.offset_bit)))
    if seen != [(-4, True), (-2, True), (0, False)]:
        raise AssertionError(f"decay/latch: {seen}")
    print("PASS: latch снимается только в кадре фактического обнуления")


def check_production_writers() -> None:
    insert = Rig()
    insert.setup([0, 1, 2])
    insert.sim.call(insert.sym["Core.VDC_InsertAt"], a=1, b=3)
    if not (insert.topology() & insert.offset_bit):
        raise AssertionError("InsertAt не взвёл latch")

    gap = Rig()
    gap.setup([0, GAP_STOP, 1, 2])
    gap.sim.set_byte(gap.sym["Core.VDC_GapJunction"], 2)
    gap.sim.call(gap.sym["Core.VDC_DoGapStep"])
    if not (gap.topology() & gap.offset_bit):
        raise AssertionError("DoGapStep не взвёл latch")
    if not any(value != 0 for value in gap.offsets()):
        raise AssertionError("CATCH-UP fixture не создал отрицательные offsets")

    gap.sim.set_byte(gap.sym["Core.VDC_GapJunction"], 0)
    gap.sim.set_byte(gap.sym["Core.VDC_GapPosLeft"], 0)
    gap.sim.set_byte(gap.sym["Core.VDC_ChainFreezeCnt"], 0)
    gap.sim.call(gap.sym["Core.VDC_ClearShot2Maybe"])
    gap.sim.call(gap.sym["Core.VDC_AnimateChain"])
    if not any(value != 0 for value in gap.offsets()):
        raise AssertionError("контрпример CATCH-UP слишком быстро обнулился")
    if not (gap.topology() & gap.offset_bit):
        raise AssertionError("latch потерян при нулевых старых скалярах")
    print("PASS: InsertAt и DoGapStep взводят latch; CATCH-UP его сохраняет")


def check_dual_independence() -> None:
    rig = Rig()
    rig.sim.set_byte(rig.sym["Core.VDC_HasSecondChain"], 1)
    rig.sim.call(rig.sym["Core.VDC_SelectChain1"])
    rig.sim.call(rig.sym["Core.VDC_MarkOffsetsMaybe"])
    if not (rig.topology() & rig.offset_bit) or (rig.topology(True) & rig.offset_bit):
        raise AssertionError("latch цепочки 1 затронул цепочку 2")
    rig.sim.call(rig.sym["Core.VDC_SelectChain2"])
    rig.sim.call(rig.sym["Core.VDC_MarkOffsetsMaybe"])
    if not (rig.topology() & rig.offset_bit) or not (rig.topology(True) & rig.offset_bit):
        raise AssertionError("latch цепочки 2 не независим")
    print("PASS: защёлки двух цепочек независимы")


def check_clean_gate_cost() -> None:
    rig = Rig()
    rig.setup([0, 1, 2, 3])
    steps = rig.sim.call(rig.sym["Core.VDC_AnimateChain"])
    if rig.topology() & rig.offset_bit:
        raise AssertionError("чистый кадр самопроизвольно взвёл latch")
    print(f"PASS: чистый offsets-loop пропущен, эмуляторных блоков={steps}")


def main() -> int:
    check_decay_clear()
    check_production_writers()
    check_dual_independence()
    check_clean_gate_cost()
    print("PASS: OFFSETS_MAYBE сохраняет production-инвариант")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
