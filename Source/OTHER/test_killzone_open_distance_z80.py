#!/usr/bin/env python3
"""Check the kill-zone skull opening window.

VDC_CheckKillzone should keep the skull closed while rem >= 65, start opening
at rem == 64, keep opening through rem == 1, and trigger absorb at rem <= 0.
The scan covers all legal KzEndSub values so cell/sub-cell wrapping is tested.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402


CELL_SIZE = 32
TRACK_NUM_SLOTS = 20


def max_slots(sim: ZumaZ80Sim) -> int:
    return sim.sym["Core.VDC_Offsets"] - sim.sym["Core.VDC_Slots"]


def sb(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value)


def sw(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value & 0xFF)
    sim.set_byte(sim.sym[name] + 1, (value >> 8) & 0xFF)


def clear_array(sim: ZumaZ80Sim, name: str) -> None:
    base = sim.sym[name]
    for i in range(max_slots(sim)):
        sim.set_byte(base + i, 0)


def expected(rem: int) -> tuple[int, int]:
    if rem <= 0:
        return 1, 11
    if rem <= 64:
        return 0, 2 + ((64 - rem) >> 3)
    return 0, 1


def set_position_for_rem(sim: ZumaZ80Sim, kz_end_sub: int, rem: int) -> None:
    head_sample = TRACK_NUM_SLOTS * CELL_SIZE + kz_end_sub - rem
    hsa = head_sample // CELL_SIZE
    hsub = head_sample % CELL_SIZE
    sb(sim, "Core.VDC_HSA", hsa)
    sb(sim, "Core.VDC_HSub", hsub)


def reset_case(sim: ZumaZ80Sim, kz_end_sub: int, rem: int) -> None:
    sb(sim, "Core.VDC_GameState", 0)
    sb(sim, "Core.VDC_DialogState", 0)
    sb(sim, "Core.VDC_HasSecondChain", 0)
    sb(sim, "Core.VDC_SecondActive", 0)
    sb(sim, "Core.VDC_KzFrame", 99)
    if "Core.VDC_WarnPlayed" in sim.sym:
        sb(sim, "Core.VDC_WarnPlayed", 1)
    if "Core.VDC_LoseShotState" in sim.sym:
        sb(sim, "Core.VDC_LoseShotState", 0)
    if "Core.Bullet_Active" in sim.sym:
        sb(sim, "Core.Bullet_Active", 0)
    sb(sim, "Core.VDC_ChainFreezeCnt", 0)
    sb(sim, "Core.VDC_GapJunction", 0)
    sb(sim, "Core.VDC_GapPosLeft", 0)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)
    sw(sim, "Core.VDC_TrackNumSlots", TRACK_NUM_SLOTS)
    sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
    sb(sim, "Core.VDC_SlotsLen", 3)
    for i, color in enumerate((0, 1, 2)):
        sim.set_byte(sim.sym["Core.VDC_Slots"] + i, color)
        sim.set_byte(sim.sym["Core.VDC_Offsets"] + i, 0)
        sim.set_byte(sim.sym["Core.VDC_Shot2"] + i, 0)
        sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + i, 0)
    set_position_for_rem(sim, kz_end_sub, rem)


def main() -> int:
    sim = ZumaZ80Sim()
    if "Core.VDC_SelectChain1" in sim.sym:
        sim.call(sim.sym["Core.VDC_SelectChain1"])
    for name in (
        "Core.VDC_Slots",
        "Core.VDC_Offsets",
        "Core.VDC_Shot2",
        "Core.VDC_ExplodeFrame",
        "Core.VDC_ExplodeMarker",
    ):
        clear_array(sim, name)

    check_addr = sim.sym.get("Core.VDC_CheckKillzone", sim.sym["VDC_CheckKillzone"])
    failures: list[str] = []
    interesting: list[str] = []

    for kz_end_sub in range(CELL_SIZE):
        for rem in range(-2, 97):
            reset_case(sim, kz_end_sub, rem)
            sim.call(check_addr, max_steps=5_000_000)
            state = sim.get_byte(sim.sym["Core.VDC_GameState"])
            frame = sim.get_byte(sim.sym["Core.VDC_KzFrame"])
            exp_state, exp_frame = expected(rem)
            if (state, frame) != (exp_state, exp_frame):
                hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
                hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
                failures.append(
                    f"kz_end_sub={kz_end_sub:02d} rem={rem:3d} "
                    f"hsa={hsa:02d} hsub={hsub:02d}: "
                    f"state/frame=({state},{frame}) expected=({exp_state},{exp_frame})"
                )
            if kz_end_sub in (0, 1, 31) and rem in (65, 64, 63, 11, 10, 9, 8, 2, 1, 0):
                interesting.append(
                    f"kz_end_sub={kz_end_sub:02d} rem={rem:2d} -> "
                    f"state={state} frame={frame}"
                )

    for line in interesting:
        print(line)

    if failures:
        print("\nFAILURES:")
        for item in failures[:40]:
            print(item)
        if len(failures) > 40:
            print(f"... {len(failures) - 40} more")
        return 1

    print(
        "\nPASS: kill-zone skull opens exactly at rem<=64, "
        "stays closed at rem>=65, and triggers at rem<=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
