#!/usr/bin/env python3
"""Контракт состояния поражения v099 с текущей безопасной парковкой у килл-зоны.

Эти проверки зафиксированы по выпуску v099, коммит 2696dfb:
- Летящая пуля Bullet_Active не блокирует VDC_LoseStartReady.
- При прямом входе в ABSORB процедура VDC_CheckKillzone гасит активный выстрел
  и стрельбу лягушки.
- При rem=65 готовая цепь остаётся в закрытом кадре PLAY; в v099 не было
  защёлки готовности.
- Занятость перед поражением задают ExplodeActive, GapJunction, GapPosLeft,
  маркеры разрыва и ExplodeFrame.
- ChainFreezeCnt и Shot2 сами по себе в v099 не блокировали вход в поражение.

Текущая реализация сохраняет историческую безопасную геометрию: занятая цепь
паркуется на rem=65 до окна килл-зоны. Для TNS=10, KzEndSub=31 это
HSA=8, HSub=30 и закрытая пасть KzFrame=1.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_lose_waits_chain_settle_z80 import make_sim, sb  # noqa: E402


def check_killzone(sim) -> None:
    s = sim.sym
    sim.call(s.get("Core.VDC_CheckKillzone", s["VDC_CheckKillzone"]), max_steps=5_000_000)


def gb(sim, name: str) -> int:
    return sim.get_byte(sim.sym[name])


def set_rem65(sim) -> None:
    sb(sim, "Core.VDC_HSA", 8)
    sb(sim, "Core.VDC_HSub", 30)


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


def run_rem65_ready_ignores_non_v099_armed_latch() -> bool:
    sim = make_sim()
    set_rem65(sim)
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
    ok = state == 0 and hsa == 8 and hsub == 30 and hold == 0 and kz == 1
    return expect(
        "v099 ready rem=65 stays closed PLAY, no armed-trigger path",
        ok,
        f"state={state} hsa={hsa} hsub={hsub} hold={hold} kz={kz} armed={armed}",
    )


def run_gap_and_explode_busy_cases() -> bool:
    cases = [
        ("ExplodeActive", lambda sim: sb(sim, "Core.VDC_ExplodeActive", 1)),
        ("GapJunction", lambda sim: sb(sim, "Core.VDC_GapJunction", 1)),
        ("GapPosLeft", lambda sim: sb(sim, "Core.VDC_GapPosLeft", 1)),
        ("gap marker", lambda sim: sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE)),
        ("ExplodeFrame", lambda sim: sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1)),
    ]
    all_ok = True
    for name, setup in cases:
        sim = make_sim()
        setup(sim)
        check_killzone(sim)
        state = gb(sim, "Core.VDC_GameState")
        hsa = gb(sim, "Core.VDC_HSA")
        hsub = gb(sim, "Core.VDC_HSub")
        hold = gb(sim, "Core.VDC_LoseHoldCnt")
        kz = gb(sim, "Core.VDC_KzFrame")
        ok = state == 0 and hsa == 8 and hsub == 30 and hold == 25 and kz == 1
        all_ok = expect(
            f"v099 busy case blocks lose and parks at rem=65: {name}",
            ok,
            f"state={state} hsa={hsa} hsub={hsub} hold={hold} kz={kz}",
        ) and all_ok
    return all_ok


def run_freeze_and_shot2_do_not_block_v099() -> bool:
    cases = [
        ("ChainFreezeCnt", lambda sim: sb(sim, "Core.VDC_ChainFreezeCnt", 7)),
        ("Shot2", lambda sim: sim.set_byte(sim.sym["Core.VDC_Shot2"] + 1, 1)),
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
        run_rem65_ready_ignores_non_v099_armed_latch(),
        run_gap_and_explode_busy_cases(),
        run_freeze_and_shot2_do_not_block_v099(),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
