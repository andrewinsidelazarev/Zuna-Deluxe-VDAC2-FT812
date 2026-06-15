#!/usr/bin/env python3
"""Lose trigger must wait until chain-settle work is complete.

The test drives Core.VDC_CheckKillzone directly with the head already at the
kill-zone boundary. ABSORB may start only when the active chain and, on dual
levels, the inactive chain have no gap markers, destroy frames, pending Shot2,
or unsettled offsets. While blocked, the head is held two samples before KZ.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

MAX_SLOTS = 128


def sb(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value)


def sw(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value & 0xFF)
    sim.set_byte(sim.sym[name] + 1, (value >> 8) & 0xFF)


def clear_array(sim: ZumaZ80Sim, name: str) -> None:
    base = sim.sym[name]
    for i in range(MAX_SLOTS):
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
    sb(sim, "Core.VDC_WarnPlayed", 0)
    sb(sim, "Core.VDC_GameOverTick", 0)
    sb(sim, "Core.VDC_AbsorbPopNote", 0)
    sb(sim, "Core.VDC_KzFrame", 1)
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
) -> bool:
    sim = make_sim()
    setup(sim)
    state = check_killzone(sim)
    hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
    hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
    ok = (
        state == expected_state
        and (expected_hsub is None or hsub == expected_hsub)
        and (expected_hsa is None or hsa == expected_hsa)
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: {name}: "
        f"state={state}, expected={expected_state}; "
        f"hsa={hsa}, expected_hsa={expected_hsa if expected_hsa is not None else '*'}; "
        f"hsub={hsub}, expected_hsub={expected_hsub if expected_hsub is not None else '*'}"
    )
    return ok


def main() -> int:
    cases = [
        ("single ready starts absorb", lambda sim: None, 1),
        (
            "active destroy frame blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            0,
            29,
        ),
        (
            "active gap marker blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE),
            0,
            29,
        ),
        (
            "active unsettled offset blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_Offsets"] + 1, 1),
            0,
            29,
        ),
        (
            "active pending Shot2 blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_Shot2"] + 1, 1),
            0,
            29,
        ),
        (
            "active destroy frame repositions from one to two samples before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_HSub", 30),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            29,
        ),
        (
            "active destroy frame wraps two-sample hold at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSub", 1),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            31,
            9,
        ),
        (
            "active destroy frame wraps two-sample hold at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 0),
                sb(sim, "Core.VDC_HSub", 0),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            9,
        ),
        (
            "dual inactive destroy frame blocks absorb",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            29,
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
