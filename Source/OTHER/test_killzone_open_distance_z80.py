#!/usr/bin/env python3
"""Проверка окна раскрытия черепа по базовой координате цепочки.

VDC_CheckKillzone должна держать череп закрытым при rem >= 65, начинать
раскрытие при rem == 64, продолжать его до rem == 1 включительно и запускать
всасывание при rem <= 0. Граница Lose определяется только HSA/HSub; знаковый
Offsets[0] остаётся визуальной анимацией и не сдвигает границу состояния.
Проверяются все допустимые KzEndSub и полный диапазон смещений головы.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402


CELL_SIZE = 32
TRACK_NUM_SLOTS = 20
HEAD_OFFSETS = (-128, -64, -32, -1, 0, 1, 31, 32, 64, 127)
EFFECTIVE_REMS = (65, 64, 3, 2, 1, 0, -1)
EDGE_KZ_END_SUBS = (0, 1, 31)


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


def set_position_for_effective_rem(
    sim: ZumaZ80Sim,
    kz_end_sub: int,
    rem: int,
    head_offset: int,
) -> None:
    """Задать HSA/HSub так, чтобы голова со знаковым Offsets[0] имела данный rem."""
    effective_head = TRACK_NUM_SLOTS * CELL_SIZE + kz_end_sub - rem
    raw_head = effective_head - head_offset
    hsa, hsub = divmod(raw_head, CELL_SIZE)
    sb(sim, "Core.VDC_HSA", hsa)
    sb(sim, "Core.VDC_HSub", hsub)


def signed_byte(value: int) -> int:
    return value - 256 if value & 0x80 else value


def effective_rem(sim: ZumaZ80Sim, kz_end_sub: int) -> int:
    hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
    hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
    offset0 = signed_byte(sim.get_byte(sim.sym["Core.VDC_Offsets"]))
    effective_head = hsa * CELL_SIZE + hsub + offset0
    return TRACK_NUM_SLOTS * CELL_SIZE + kz_end_sub - effective_head


def raw_head(sim: ZumaZ80Sim) -> int:
    hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
    hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
    return hsa * CELL_SIZE + hsub


def set_offsets_topology_busy(sim: ZumaZ80Sim) -> None:
    sim.call(sim.sym["Core.VDC_MarkTopologyDirty"])
    sim.call(sim.sym["Core.VDC_MarkOffsetsMaybe"])


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
    topology = sim.sym["Core.VDC_Slots"] - 1
    offsets_mask = sim.sym["Core.VDC_TOPO_OFFSETS_MAYBE"]
    sim.set_byte(topology, sim.get_byte(topology) & ~offsets_mask)
    set_position_for_rem(sim, kz_end_sub, rem)


def run_effective_head_cases(
    sim: ZumaZ80Sim,
    check_addr: int,
    failures: list[str],
) -> None:
    """Знаковое смещение головы не должно менять логическую границу Lose."""
    for kz_end_sub in EDGE_KZ_END_SUBS:
        for head_offset in HEAD_OFFSETS:
            for rem in EFFECTIVE_REMS:
                reset_case(sim, kz_end_sub, rem)
                sim.set_byte(sim.sym["Core.VDC_Offsets"], head_offset & 0xFF)
                before_head = raw_head(sim)

                sim.call(check_addr, max_steps=5_000_000)
                state = sim.get_byte(sim.sym["Core.VDC_GameState"])
                frame = sim.get_byte(sim.sym["Core.VDC_KzFrame"])
                hold = sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"])
                exp_state, exp_frame = expected(rem)
                actual = (state, frame, raw_head(sim), hold)
                expected_actual = (exp_state, exp_frame, before_head, 0)
                if actual != expected_actual:
                    failures.append(
                        f"смещение_не_двигает_границу kz={kz_end_sub:02d} "
                        f"off={head_offset:+3d} rem={rem:3d}: "
                        f"фактически={actual}, ожидалось={expected_actual}"
                    )


def run_unrelated_offsets_do_not_block(
    sim: ZumaZ80Sim,
    check_addr: int,
    failures: list[str],
) -> None:
    """Обычные offsets не должны превращаться в глобальный барьер Lose."""
    offsets_mask = sim.sym["Core.VDC_TOPO_OFFSETS_MAYBE"]
    topology_addr = sim.sym["Core.VDC_Slots"] - 1

    for kz_end_sub in EDGE_KZ_END_SUBS:
        for head_offset in HEAD_OFFSETS:
            for rem in EFFECTIVE_REMS:
                reset_case(sim, kz_end_sub, rem)
                sim.set_byte(sim.sym["Core.VDC_Offsets"], head_offset & 0xFF)
                set_offsets_topology_busy(sim)

                sim.call(check_addr, max_steps=5_000_000)
                actual = (
                    raw_head(sim),
                    sim.get_byte(sim.sym["Core.VDC_GameState"]),
                    sim.get_byte(sim.sym["Core.VDC_KzFrame"]),
                    sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"]),
                    sim.get_byte(sim.sym["Core.VDC_Offsets"]),
                    sim.get_byte(topology_addr) & offsets_mask,
                )
                exp_state, exp_frame = expected(rem)
                exp_raw_head = TRACK_NUM_SLOTS * CELL_SIZE + kz_end_sub - rem
                expected_actual = (
                    exp_raw_head,
                    exp_state,
                    exp_frame,
                    0,
                    head_offset & 0xFF,
                    offsets_mask,
                )
                if actual != expected_actual:
                    failures.append(
                        f"постороннее_смещение kz={kz_end_sub:02d} "
                        f"off={head_offset:+3d} исходный_rem={rem:3d}: "
                        f"фактически={actual}, ожидалось={expected_actual}"
                    )


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
                    f"состояние/кадр=({state},{frame}) "
                    f"ожидалось=({exp_state},{exp_frame})"
                )
            if kz_end_sub in (0, 1, 31) and rem in (65, 64, 63, 11, 10, 9, 8, 2, 1, 0):
                interesting.append(
                    f"kz_end_sub={kz_end_sub:02d} rem={rem:2d} -> "
                    f"state={state} frame={frame}"
                )

    for line in interesting:
        print(line)

    run_effective_head_cases(sim, check_addr, failures)
    run_unrelated_offsets_do_not_block(sim, check_addr, failures)

    if failures:
        print("\nОШИБКИ:")
        for item in failures[:40]:
            print(item)
        if len(failures) > 40:
            print(f"... ещё {len(failures) - 40}")
        return 1

    print(
        "\nУСПЕХ: килл-зона использует базовые HSA/HSub, раскрывается при "
        "rem<=64, а обычные offsets не двигают границу и не блокируют Lose"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
