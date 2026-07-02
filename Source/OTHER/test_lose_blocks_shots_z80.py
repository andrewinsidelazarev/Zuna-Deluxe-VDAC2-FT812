#!/usr/bin/env python3
"""Lose/KZ state запрещает выстрелы лягушки."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_lose_waits_chain_settle_z80 import make_sim, sb  # noqa: E402


def arm_frog_for_spawn(sim) -> None:
    s = sim.sym
    sb(sim, "Core.VDC_GameState", 0)
    sb(sim, "Core.VDC_DialogState", 0)
    sb(sim, "Core.Bullet_Active", 0)
    sb(sim, "Core.BulletTrajValid", 0)
    sb(sim, "Core.Frog_BallColor", 2)
    sb(sim, "Core.Frog_Angle", 0)
    sim.set_byte(s["Core.Frog_PosStartX"], 0)
    sim.set_byte(s["Core.Frog_PosStartX"] + 1, 2)
    sim.set_byte(s["Core.Frog_PosStartY"], 0)
    sim.set_byte(s["Core.Frog_PosStartY"] + 1, 2)


def bullet_active(sim) -> int:
    return sim.get_byte(sim.sym["Core.Bullet_Active"])


def run_spawn_case(name: str, kz1: int, kz2: int, expected_active: int) -> bool:
    sim = make_sim()
    arm_frog_for_spawn(sim)
    sb(sim, "Core.VDC_KzFrame", kz1)
    sb(sim, "Core.VDC2_KzFrame", kz2)

    sim.call(sim.sym["Core.Bullet_Spawn"], max_steps=5_000_000)

    active = bullet_active(sim)
    ok = active == expected_active
    print(
        f"{'PASS' if ok else 'FAIL'}: {name}: "
        f"kz1={kz1} kz2={kz2} bullet={active}, ожидалось={expected_active}"
    )
    return ok


def run_absorb_clears_active_shot() -> bool:
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.Bullet_Active", 1)
    sb(sim, "Core.Frog_IsFire", 1)
    sb(sim, "Core.Frog_RecoilTick", 55)
    sb(sim, "Core.Frog_BallExpand", 0)
    sb(sim, "Core.Frog_TongueExpand", 0)

    check_kz = s.get("Core.VDC_CheckKillzone", s["VDC_CheckKillzone"])
    sim.call(check_kz, max_steps=5_000_000)

    state = sim.get_byte(s["Core.VDC_GameState"])
    bullet = sim.get_byte(s["Core.Bullet_Active"])
    is_fire = sim.get_byte(s["Core.Frog_IsFire"])
    recoil = sim.get_byte(s["Core.Frog_RecoilTick"])
    ball_expand = sim.get_byte(s["Core.Frog_BallExpand"])
    tongue = sim.get_byte(s["Core.Frog_TongueExpand"])
    ok = (
        state == 1
        and bullet == 0
        and is_fire == 0
        and recoil == 0
        and ball_expand == 38
        and tongue == 24
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: вход в absorb гасит активный выстрел/recoil: "
        f"state={state} bullet={bullet} fire={is_fire} recoil={recoil} "
        f"ball={ball_expand} tongue={tongue}"
    )
    return ok


def main() -> int:
    checks = [
        run_spawn_case("закрытый череп разрешает обычный выстрел", 1, 0, 1),
        run_spawn_case("раннее открытие KZ цепи 1 ещё разрешает выстрел", 2, 0, 1),
        run_spawn_case("раннее открытие KZ цепи 2 ещё разрешает выстрел", 1, 2, 1),
        run_spawn_case("последняя фаза KZ цепи 1 блокирует выстрел", 9, 0, 0),
        run_spawn_case("последняя фаза KZ цепи 2 блокирует выстрел", 1, 9, 0),
        run_absorb_clears_active_shot(),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
