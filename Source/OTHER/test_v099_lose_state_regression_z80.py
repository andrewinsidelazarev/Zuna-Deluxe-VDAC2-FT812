#!/usr/bin/env python3
"""Контракт состояния поражения v099 с текущей безопасной парковкой у килл-зоны.

Эти проверки зафиксированы по выпуску v099, коммит 2696dfb:
- Летящая пуля Bullet_Active не блокирует VDC_LoseStartReady.
- При прямом входе в ABSORB процедура VDC_CheckKillzone гасит активный выстрел
  и стрельбу лягушки.
- При rem=129 готовая цепь остаётся в закрытом кадре PLAY; открытие черепа
  начинается с rem=128.
- Занятость перед поражением задают маркеры разрыва, ExplodeFrame и реальная
  signed-ступень offsets: off[i] > off[i+1].
- Производные ExplodeActive, GapJunction и GapPosLeft, а также ChainFreezeCnt,
  Shot2 и неубывающий overlap-профиль offsets сами по себе не блокируют вход.

Текущая реализация возвращает занятую цепь к base-rem=48 плавно: ровно на
один базовый sample за вызов, без мгновенного скачка HSA/HSub. Поэтому
rem=49 становится 48, rem=32 становится 33 и т. д. Для TNS=10,
KzEndSub=31 точка rem=48 — HSA=9, HSub=15, KzFrame=7.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_lose_waits_chain_settle_z80 import (  # noqa: E402
    make_sim,
    sb,
)


def check_killzone(sim) -> None:
    s = sim.sym
    sim.call(s.get("Core.VDC_CheckKillzone", s["VDC_CheckKillzone"]), max_steps=5_000_000)


def gb(sim, name: str) -> int:
    return sim.get_byte(sim.sym[name])


def set_live_offsets(sim, values: tuple[int, ...]) -> None:
    """Задать signed-профиль живых offsets и отметить наличие анимации."""
    if len(values) != gb(sim, "Core.VDC_SlotsLen"):
        raise AssertionError("число offsets не совпадает с числом живых slots")
    for index, value in enumerate(values):
        sim.set_byte(sim.sym["Core.VDC_Offsets"] + index, value & 0xFF)
    sim.call(sim.sym["Core.VDC_MarkTopologyDirty"])
    sim.call(sim.sym["Core.VDC_MarkOffsetsMaybe"])


def set_rem(sim, rem: int) -> tuple[int, int]:
    endpoint = 10 * 32 + 31
    hsa, hsub = divmod(endpoint - rem, 32)
    sb(sim, "Core.VDC_HSA", hsa)
    sb(sim, "Core.VDC_HSub", hsub)
    return hsa, hsub


def set_rem129(sim) -> None:
    set_rem(sim, 129)


def expect(name: str, ok: bool, details: str) -> bool:
    print(f"{'PASS' if ok else 'FAIL'}: {name}: {details}")
    return ok


def run_direct_absorb_clears_active_shot() -> bool:
    sim = make_sim()
    sb(sim, "Core.Bullet_Active", 1)
    sb(sim, "Core.Frog_IsFire", 1)
    sb(sim, "Core.Frog_RecoilTick", 55)
    sb(sim, "Core.Frog_BallExpand", 0)
    sb(sim, "Core.Frog_TongueExpand", 0)

    check_killzone(sim)

    state = gb(sim, "Core.VDC_GameState")
    bullet = gb(sim, "Core.Bullet_Active")
    fire = gb(sim, "Core.Frog_IsFire")
    recoil = gb(sim, "Core.Frog_RecoilTick")
    ball = gb(sim, "Core.Frog_BallExpand")
    tongue = gb(sim, "Core.Frog_TongueExpand")
    hold = gb(sim, "Core.VDC_LoseHoldCnt")
    kz = gb(sim, "Core.VDC_KzFrame")
    ok = (
        state == 1
        and bullet == 0
        and fire == 0
        and recoil == 0
        and ball == 38
        and tongue == 24
        and hold == 0
        and kz == 11
    )
    return expect(
        "v099 direct ABSORB clears active shot and leaves hold counter untouched",
        ok,
        f"state={state} bullet={bullet} fire={fire} recoil={recoil} "
        f"ball={ball} tongue={tongue} hold={hold} kz={kz}",
    )


def run_rem129_ready_ignores_non_v099_armed_latch() -> bool:
    sim = make_sim()
    set_rem129(sim)
    sb(sim, "Core.VDC_LoseHoldCnt", 5)
    if "Core.VDC_LoseHoldArmed" in sim.sym:
        sb(sim, "Core.VDC_LoseHoldArmed", 1)

    check_killzone(sim)

    state = gb(sim, "Core.VDC_GameState")
    hsa = gb(sim, "Core.VDC_HSA")
    hsub = gb(sim, "Core.VDC_HSub")
    hold = gb(sim, "Core.VDC_LoseHoldCnt")
    kz = gb(sim, "Core.VDC_KzFrame")
    armed = gb(sim, "Core.VDC_LoseHoldArmed") if "Core.VDC_LoseHoldArmed" in sim.sym else 0
    ok = state == 0 and hsa == 6 and hsub == 30 and hold == 0 and kz == 1
    return expect(
        "ready rem=129 stays closed PLAY, no armed-trigger path",
        ok,
        f"state={state} hsa={hsa} hsub={hsub} hold={hold} kz={kz} armed={armed}",
    )


def run_gap_and_explode_busy_cases() -> bool:
    cases = [
        ("gap marker", lambda sim: sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE)),
        ("ExplodeFrame", lambda sim: sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1)),
        ("signed offset GAP step", lambda sim: set_live_offsets(sim, (0, -16, 0))),
    ]
    all_ok = True
    for name, setup in cases:
        sim = make_sim()
        set_rem(sim, 49)
        setup(sim)
        check_killzone(sim)
        state = gb(sim, "Core.VDC_GameState")
        hsa = gb(sim, "Core.VDC_HSA")
        hsub = gb(sim, "Core.VDC_HSub")
        hold = gb(sim, "Core.VDC_LoseHoldCnt")
        kz = gb(sim, "Core.VDC_KzFrame")
        ok = state == 0 and hsa == 9 and hsub == 15 and hold == 255 and kz == 7
        all_ok = expect(
            f"busy case blocks lose and advances rem=49 only to rem=48: {name}",
            ok,
            f"state={state} hsa={hsa} hsub={hsub} hold={hold} kz={kz}",
        ) and all_ok
    return all_ok


def run_busy_hold_returns_smoothly() -> bool:
    all_ok = True
    for rem in (47, 32, 1, 0):
        sim = make_sim()
        set_rem(sim, rem)
        sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE)

        check_killzone(sim)

        state = gb(sim, "Core.VDC_GameState")
        hsa = gb(sim, "Core.VDC_HSA")
        hsub = gb(sim, "Core.VDC_HSub")
        hold = gb(sim, "Core.VDC_LoseHoldCnt")
        kz = gb(sim, "Core.VDC_KzFrame")
        expected_rem = min(rem + 1, 48)
        endpoint = 10 * 32 + 31
        expected_hsa, expected_hsub = divmod(endpoint - expected_rem, 32)
        expected_kz = 11 if expected_rem <= 0 else 2 + ((128 - expected_rem) >> 4)
        ok = (
            state == 0
            and (hsa, hsub) == (expected_hsa, expected_hsub)
            and hold == 255
            and kz == expected_kz
        )
        all_ok = expect(
            f"busy hold at rem={rem} returns one sample toward rem=48",
            ok,
            f"state={state} hsa={hsa}/{expected_hsa} "
            f"hsub={hsub}/{expected_hsub} hold={hold} kz={kz}/{expected_kz}",
        ) and all_ok
    return all_ok


def run_unrelated_events_do_not_block_v099() -> bool:
    cases = [
        ("derived ExplodeActive", lambda sim: sb(sim, "Core.VDC_ExplodeActive", 1)),
        ("derived GapJunction", lambda sim: sb(sim, "Core.VDC_GapJunction", 1)),
        ("derived GapPosLeft", lambda sim: sb(sim, "Core.VDC_GapPosLeft", 1)),
        ("ChainFreezeCnt", lambda sim: sb(sim, "Core.VDC_ChainFreezeCnt", 7)),
        ("Shot2", lambda sim: sim.set_byte(sim.sym["Core.VDC_Shot2"] + 1, 1)),
        ("ordinary overlap offsets", lambda sim: set_live_offsets(sim, (-16, 0, 16))),
    ]
    all_ok = True
    for name, setup in cases:
        sim = make_sim()
        setup(sim)
        check_killzone(sim)
        state = gb(sim, "Core.VDC_GameState")
        hold = gb(sim, "Core.VDC_LoseHoldCnt")
        kz = gb(sim, "Core.VDC_KzFrame")
        ok = state == 1 and hold == 0 and kz == 11
        all_ok = expect(
            f"v099 non-busy case enters lose: {name}",
            ok,
            f"state={state} hold={hold} kz={kz}",
        ) and all_ok
    return all_ok


def main() -> int:
    checks = [
        run_direct_absorb_clears_active_shot(),
        run_rem129_ready_ignores_non_v099_armed_latch(),
        run_gap_and_explode_busy_cases(),
        run_busy_hold_returns_smoothly(),
        run_unrelated_events_do_not_block_v099(),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
