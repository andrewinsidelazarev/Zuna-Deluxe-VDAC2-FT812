#!/usr/bin/env python3
"""Lose trigger waits until gap/explode work is complete.

Тест напрямую вызывает Core.VDC_CheckKillzone. ABSORB можно запускать только
когда в active chain и, на dual-уровнях, в inactive chain уже нет gap-маркеров
и active destroy frames. Пока запуск заблокирован, голова удерживается на
rem=65, то есть до окна открытия kill-zone.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402


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


def make_sim() -> ZumaZ80Sim:
    sim = ZumaZ80Sim()
    for name in (
        "Core.VDC_Slots",
        "Core.VDC_Offsets",
        "Core.VDC_Shot2",
        "Core.VDC_ExplodeFrame",
        "Core.VDC_ExplodeMarker",
        "Core.VDC2_Slots",
        "Core.VDC2_Offsets",
        "Core.VDC2_Shot2",
        "Core.VDC2_ExplodeFrame",
        "Core.VDC2_ExplodeMarker",
    ):
        clear_array(sim, name)

    if "Core.VDC_SelectChain1" in sim.sym:
        sim.call(sim.sym["Core.VDC_SelectChain1"])
    sb(sim, "Core.VDC_SecondActive", 0)
    sb(sim, "Core.VDC_HasSecondChain", 0)
    sb(sim, "Core.VDC_GameState", 0)
    sb(sim, "Core.VDC_DialogState", 0)
    sb(sim, "Core.VDC_ChainFreezeCnt", 0)
    sb(sim, "Core.VDC_GapJunction", 0)
    sb(sim, "Core.VDC_GapPosLeft", 0)
    if "Core.VDC_WarnPlayed" in sim.sym:
        sb(sim, "Core.VDC_WarnPlayed", 0)
    sb(sim, "Core.VDC_GameOverTick", 0)
    sb(sim, "Core.VDC_AbsorbPopNote", 0)
    sb(sim, "Core.VDC_KzFrame", 1)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)
    sb(sim, "Core.VDC_HeadAbsorbAlpha", 255)

    sw(sim, "Core.VDC_TrackNumSlots", 10)
    sb(sim, "Core.VDC_KzEndSub", 31)
    sb(sim, "Core.VDC_HSA", 10)
    sb(sim, "Core.VDC_HSub", 31)
    sb(sim, "Core.VDC_SlotsLen", 3)
    for i, color in enumerate((0, 1, 2)):
        sim.set_byte(sim.sym["Core.VDC_Slots"] + i, color)
        sim.set_byte(sim.sym["Core.VDC2_Slots"] + i, color)
    sb(sim, "Core.VDC2_SlotsLen", 3)
    return sim


def check_killzone(sim: ZumaZ80Sim) -> int:
    check_addr = sim.sym.get("Core.VDC_CheckKillzone", sim.sym["VDC_CheckKillzone"])
    sim.call(check_addr, max_steps=5_000_000)
    return sim.get_byte(sim.sym["Core.VDC_GameState"])


def run_case(
    name: str,
    setup,
    expected_state: int,
    expected_hsub: int | None = None,
    expected_hsa: int | None = None,
    move_after_check: bool = False,
    expected_freeze: int | None = None,
    expected_hold: int | None = None,
    expected_kz: int | None = None,
) -> bool:
    sim = make_sim()
    setup(sim)
    state = check_killzone(sim)
    if move_after_check:
        sim.call(sim.sym["Core.VDC_MoveChain"], max_steps=5_000_000)
    hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
    hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
    freeze = sim.get_byte(sim.sym["Core.VDC_ChainFreezeCnt"])
    hold = sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"])
    kz = sim.get_byte(sim.sym["Core.VDC_KzFrame"])
    ok = (
        state == expected_state
        and (expected_hsub is None or hsub == expected_hsub)
        and (expected_hsa is None or hsa == expected_hsa)
        and (expected_freeze is None or freeze == expected_freeze)
        and (expected_hold is None or hold == expected_hold)
        and (expected_kz is None or kz == expected_kz)
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: {name}: "
        f"state={state}, expected={expected_state}; "
        f"hsa={hsa}, expected_hsa={expected_hsa if expected_hsa is not None else '*'}; "
        f"hsub={hsub}, expected_hsub={expected_hsub if expected_hsub is not None else '*'}"
        f"; freeze={freeze}, expected_freeze={expected_freeze if expected_freeze is not None else '*'}"
        f"; hold={hold}, expected_hold={expected_hold if expected_hold is not None else '*'}"
        f"; kz={kz}, expected_kz={expected_kz if expected_kz is not None else '*'}"
        f"{'; after MoveChain' if move_after_check else ''}"
    )
    return ok


def main() -> int:
    cases = [
        ("single ready starts absorb", lambda sim: None, 1),
        (
            "ready chain opens KZ frame at rem=64",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 31),
            ),
            0,
            31,
            8,
            False,
            None,
            0,
            2,
        ),
        (
            "ready chain clears stale hold at rem=65",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 30),
                sb(sim, "Core.VDC_LoseHoldCnt", 5),
            ),
            0,
            30,
            8,
            False,
            None,
            0,
            1,
        ),
        (
            "active destroy frame blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            0,
            30,
            8,
            False,
            None,
            24,
        ),
        (
            "active gap marker blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE),
            0,
            30,
            8,
            False,
            None,
            24,
        ),
        (
            "active destroy frame holds at rem=66 before KZ opening",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            24,
        ),
        (
            "active destroy frame at rem=67 is not held yet",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 28),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            28,
            8,
            False,
            None,
            0,
        ),
        (
            "active destroy frame blocks next move before KZ opening",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            True,
            0,
            23,
        ),
        (
            "active destroy frame wraps pre-KZ hold at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSub", 1),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            0,
            8,
            False,
            None,
            24,
        ),
        (
            "active destroy frame blocks next wrapped move before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSA", 9),
                sb(sim, "Core.VDC_HSub", 31),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            0,
            8,
            True,
            None,
            23,
        ),
        (
            "active destroy frame wraps pre-KZ hold at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 0),
                sb(sim, "Core.VDC_HSub", 0),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            31,
            7,
            False,
            None,
            24,
        ),
        (
            "dual inactive destroy frame blocks absorb",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            24,
        ),
        (
            "dual inactive gap marker blocks absorb",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            30,
            8,
            False,
            None,
            24,
        ),
        (
            "dual inactive destroy frame blocks next move before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            True,
            None,
            23,
        ),
        (
            "dual inactive gap marker blocks next move before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            30,
            8,
            True,
            None,
            23,
        ),
        (
            "dual both ready starts absorb",
            lambda sim: sb(sim, "Core.VDC_HasSecondChain", 1),
            1,
        ),
    ]

    failures = 0
    for case in cases:
        if not run_case(*case):
            failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
