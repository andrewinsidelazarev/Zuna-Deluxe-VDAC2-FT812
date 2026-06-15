#!/usr/bin/env python3
"""Regression: cascade не должен матчить run, если gap был рядом, а не между шарами."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zuma_z80_simulator import ZumaZ80Sim

MAX_SLOTS = 128


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
        for i in range(MAX_SLOTS):
            sim.set_byte(base + i, 0)


def setup(sim, slots, shot2_idx, bridge_k):
    s = sim.sym
    clear_arrays(sim)
    for i, color in enumerate(slots):
        sim.set_byte(s["Core.VDC_Slots"] + i, color)
    sim.set_byte(s["Core.VDC_SlotsLen"], len(slots))
    sim.set_byte(s["Core.VDC_HSA"], len(slots) - 1)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    if "Core.VDC_GapAccum" in s:
        sim.set_byte(s["Core.VDC_GapAccum"], 0)
        sim.set_byte(s["Core.VDC_GapAccum"] + 1, 0)
    for name in ("Core.VDC_GapJunction", "Core.VDC_GapDecAcc", "Core.VDC_GapPosLeft"):
        if name in s:
            sim.set_byte(s[name], 0)
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

    # Дамп 111: старый дальний Shot2 не должен обогнать легальный bridge
    # текущего cascade-gap. Иначе одновременно появляются ложный match-3
    # в стороне и нормальный match-3 после вставки/схлопывания.
    slots = [0] * 24
    for i in range(4, 10):
        slots[i] = 1
    for i in range(18, 21):
        slots[i] = 2
    setup(sim, slots, shot2_idx=5, bridge_k=19)
    sim.set_byte(s["Core.VDC_Shot2"] + 18, 1)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 1)
    if "Core.VDC_BridgeScanActive" in s:
        sim.set_byte(s["Core.VDC_BridgeScanActive"], 1)
    sim.call(s["Core.VDC_ScanForNewMatch"])
    frames = explode_frames(sim, 24)
    print(f"far-stale-plus-legal frames[4:10]={frames[4:10]} frames[18:21]={frames[18:21]}")
    if any(frames[4:10]):
        print("FAIL: cascade matched a far stale Shot2 before the active gap bridge")
        sys.exit(1)
    if frames[18:21] != [1, 1, 1]:
        print("FAIL: cascade skipped the legal active gap bridge")
        sys.exit(1)

    # Если в цепи есть чужой GAP-marker, активную границу всё равно надо
    # проверять. Иначе легальный bridge может быть потерян до следующего scan.
    setup(sim, [0, 2, 2, 2, 1, 0xFD, 1], shot2_idx=1, bridge_k=2)
    sim.set_byte(s["Core.VDC_ExplodeMarker"] + 5, 0xFD)
    sim.set_byte(s["Core.VDC_ChainFreezeCnt"], 1)
    if "Core.VDC_BridgeScanActive" in s:
        sim.set_byte(s["Core.VDC_BridgeScanActive"], 1)
    sim.call(s["Core.VDC_ScanForNewMatch"])
    frames = explode_frames(sim, 7)
    print(f"legal-bridge-with-other-marker frames={frames}")
    if frames[1:4] != [1, 1, 1]:
        print("FAIL: active bridge was blocked by an unrelated gap marker")
        sys.exit(1)

    print("PASS: cascade match requires the gap to be between matched balls")


if __name__ == "__main__":
    main()
