#!/usr/bin/env python3
"""Проверка окна раскрытия черепа килл-зоны и эффективной позиции головы.

VDC_CheckKillzone должна держать череп закрытым при rem >= 65, начинать
раскрытие при rem == 64, продолжать его до rem == 1 включительно и запускать
всасывание при rem <= 0. Расстояние измеряется от отображаемой головы с учётом
знакового Offsets[0]. Проверяются все допустимые значения KzEndSub, включая
переходы между ячейками и подячейками. При незавершённой анимации смещений
голова паркуется до окна kill-zone: положительные смещения компенсируются до
эффективного rem == 65, а отрицательные остаются ещё дальше от границы, чтобы
их последующее затухание безопасно довело голову к rem == 65.
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
EFFECTIVE_REMS = (67, 66, 65, 64, 3, 2, 1, 0, -1)
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
    """Расстояние до килл-зоны должно учитывать знаковое смещение головы."""
    for kz_end_sub in EDGE_KZ_END_SUBS:
        for head_offset in HEAD_OFFSETS:
            for rem in EFFECTIVE_REMS:
                reset_case(sim, kz_end_sub, rem)
                sim.set_byte(sim.sym["Core.VDC_Offsets"], head_offset & 0xFF)
                set_position_for_effective_rem(sim, kz_end_sub, rem, head_offset)

                # Оставляем флаг топологии сброшенным, чтобы отдельно проверить
                # арифметику расстояния и барьер завершения анимаций ниже.
                fixture_rem = effective_rem(sim, kz_end_sub)
                if fixture_rem != rem:
                    raise AssertionError(
                        f"ошибка подготовки: kz={kz_end_sub} off={head_offset:+d} "
                        f"rem={fixture_rem}, ожидалось {rem}"
                    )

                sim.call(check_addr, max_steps=5_000_000)
                state = sim.get_byte(sim.sym["Core.VDC_GameState"])
                frame = sim.get_byte(sim.sym["Core.VDC_KzFrame"])
                exp_state, exp_frame = expected(rem)
                if (state, frame) != (exp_state, exp_frame):
                    failures.append(
                        f"эффективная_голова kz={kz_end_sub:02d} "
                        f"off={head_offset:+3d} rem={rem:3d}: "
                        f"состояние/кадр=({state},{frame}) "
                        f"ожидалось=({exp_state},{exp_frame})"
                    )


def run_busy_offsets_park_cases(
    sim: ZumaZ80Sim,
    check_addr: int,
    failures: list[str],
) -> None:
    """Незавершённая анимация смещений безопасно паркуется и остаётся там."""
    offsets_mask = sim.sym["Core.VDC_TOPO_OFFSETS_MAYBE"]
    topology_addr = sim.sym["Core.VDC_Slots"] - 1

    for kz_end_sub in EDGE_KZ_END_SUBS:
        for head_offset in HEAD_OFFSETS:
            for rem in EFFECTIVE_REMS:
                reset_case(sim, kz_end_sub, rem)
                sim.set_byte(sim.sym["Core.VDC_Offsets"], head_offset & 0xFF)
                set_position_for_effective_rem(sim, kz_end_sub, rem, head_offset)
                set_offsets_topology_busy(sim)

                sim.call(check_addr, max_steps=5_000_000)
                if rem <= 66:
                    # Нельзя компенсировать отрицательное смещение продвижением
                    # исходных HSA/HSub: при затухании смещения к нулю отображаемая
                    # голова иначе приблизится к окну KZ раньше settle. Положительные
                    # смещения компенсируются назад до видимого rem=65.
                    parked_rem = 65 - min(head_offset, 0)
                    exp_raw_head = (
                        TRACK_NUM_SLOTS * CELL_SIZE
                        + kz_end_sub
                        - 65
                        - max(head_offset, 0)
                    )
                else:
                    parked_rem = rem
                    exp_raw_head = (
                        TRACK_NUM_SLOTS * CELL_SIZE
                        + kz_end_sub
                        - rem
                        - head_offset
                    )
                first = (
                    raw_head(sim),
                    effective_rem(sim, kz_end_sub),
                    sim.get_byte(sim.sym["Core.VDC_GameState"]),
                    sim.get_byte(sim.sym["Core.VDC_KzFrame"]),
                    sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"]),
                    sim.get_byte(sim.sym["Core.VDC_Offsets"]),
                    sim.get_byte(topology_addr) & offsets_mask,
                )
                exp_frame = 1 if rem <= 66 else expected(rem)[1]
                hold_ok = first[4] != 0 if rem <= 66 else first[4] == 0
                if not (
                    first[0] == exp_raw_head
                    and first[1] == parked_rem
                    and first[2] == 0
                    and first[3] == exp_frame
                    and hold_ok
                    and first[5] == (head_offset & 0xFF)
                    and first[6] == offsets_mask
                ):
                    failures.append(
                        f"смещения_заняты kz={kz_end_sub:02d} "
                        f"off={head_offset:+3d} исходный_rem={rem:3d}: "
                        f"исходная/эффективная/состояние/кадр/удержание/off/"
                        f"топология={first}, ожидалось исходная={exp_raw_head} "
                        f"эффективная={parked_rem} состояние=0 кадр={exp_frame}"
                    )
                    continue

                # Для отрицательного смещения безопасный эффективный rem может
                # быть больше 65 (здесь до 193). Флаг удержания всё равно должен
                # сохранять последующие проверки побайтно стабильными, не
                # возвращаясь к логике вычисления расстояния.
                stable = True
                for _ in range(3):
                    sim.call(check_addr, max_steps=5_000_000)
                    again = (
                        raw_head(sim),
                        effective_rem(sim, kz_end_sub),
                        sim.get_byte(sim.sym["Core.VDC_GameState"]),
                        sim.get_byte(sim.sym["Core.VDC_KzFrame"]),
                        sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"]),
                        sim.get_byte(sim.sym["Core.VDC_Offsets"]),
                        sim.get_byte(topology_addr) & offsets_mask,
                    )
                    if again != first:
                        stable = False
                        failures.append(
                            f"дрейф при занятости kz={kz_end_sub:02d} "
                            f"off={head_offset:+3d} исходный_rem={rem:3d}: "
                            f"сначала={first}, повторно={again}"
                        )
                        break
                if not stable:
                    continue


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
    run_busy_offsets_park_cases(sim, check_addr, failures)

    if failures:
        print("\nОШИБКИ:")
        for item in failures[:40]:
            print(item)
        if len(failures) > 40:
            print(f"... ещё {len(failures) - 40}")
        return 1

    print(
        "\nУСПЕХ: килл-зона использует эффективную позицию головы "
        "(HSA/HSub + знаковый Offsets[0]), раскрывается при rem<=64, а при "
        "незавершённых смещениях голова стоит на rem=65 без дрейфа"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
