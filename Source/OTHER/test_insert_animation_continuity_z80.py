#!/usr/bin/env python3
"""Покадровая проверка непрерывности всех веток вставки шара-пули."""

from __future__ import annotations

import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_gap_boundary_no_kz_drift_z80 import GAP_STOP, Rig  # noqa: E402


CELL = 32
MAX_FRAME_STEP = 2


def signed(value: int) -> int:
    return value - 256 if value >= 128 else value


def active_base(rig: Rig, pointer_name: str) -> int:
    return rig.sim.get_word(rig.s[pointer_name])


def active_slots(rig: Rig) -> list[int]:
    length = rig.gb("Core.VDC_SlotsLen")
    base = active_base(rig, "Core.VDC_pSlots")
    return [rig.sim.get_byte(base + index) for index in range(length)]


def active_offsets(rig: Rig) -> list[int]:
    length = rig.gb("Core.VDC_SlotsLen")
    base = active_base(rig, "Core.VDC_pOffsets")
    return [signed(rig.sim.get_byte(base + index)) for index in range(length)]


def active_positions(rig: Rig) -> list[int]:
    hsa = rig.gb("Core.VDC_HSA")
    hsub = rig.gb("Core.VDC_HSub")
    return [
        (hsa - index) * CELL + hsub + offset
        for index, offset in enumerate(active_offsets(rig))
    ]


def set_active_offsets(rig: Rig, offsets: list[int]) -> None:
    base = active_base(rig, "Core.VDC_pOffsets")
    for index, offset in enumerate(offsets):
        rig.sim.set_byte(base + index, offset & 0xFF)
    if any(offset != 0 for offset in offsets):
        rig.sim.call(rig.s["Core.VDC_MarkOffsetsMaybe"])


def expected_insert_position(before: list[int], target: int) -> int:
    if target == 0:
        return before[0] + CELL // 2
    if target == len(before):
        return before[-1] - CELL // 2
    return (before[target - 1] + before[target]) // 2


def check_insert(
    name: str,
    rig: Rig,
    target: int,
    color: int,
    *,
    check_frame: bool = True,
) -> None:
    slots_before = active_slots(rig)
    positions_before = active_positions(rig)
    if not 0 <= target <= len(slots_before):
        raise AssertionError(f"{name}: неверная позиция вставки {target}")

    rig.sim.call(rig.s["Core.VDC_InsertAt"], a=target, b=color)
    slots_after = active_slots(rig)
    positions_after = active_positions(rig)
    if len(slots_after) != len(slots_before) + 1:
        raise AssertionError(f"{name}: длина не выросла на один: {slots_after}")
    if slots_after[target] != color:
        raise AssertionError(f"{name}: новый цвет не записан в target: {slots_after}")

    mapped = [
        positions_after[index if index < target else index + 1]
        for index in range(len(slots_before))
    ]
    if mapped != positions_before:
        deltas = [
            after - before
            for before, after in zip(positions_before, mapped, strict=True)
        ]
        raise AssertionError(
            f"{name}: старые шары прыгнули при commit: delta={deltas}, "
            f"offsets={active_offsets(rig)}"
        )

    expected = expected_insert_position(positions_before, target)
    if positions_after[target] != expected:
        raise AssertionError(
            f"{name}: новый шар не в середине: {positions_after[target]} != {expected}, "
            f"offsets={active_offsets(rig)}"
        )
    if not check_frame:
        return

    frame_before = positions_after
    rig.sim.call(rig.s["Core.VDC_AnimateChain"])
    frame_after = active_positions(rig)
    if len(frame_after) != len(frame_before):
        raise AssertionError(f"{name}: первый кадр неожиданно изменил длину цепи")
    frame_deltas = [
        after - before
        for before, after in zip(frame_before, frame_after, strict=True)
    ]
    if any(abs(delta) > MAX_FRAME_STEP for delta in frame_deltas):
        raise AssertionError(
            f"{name}: однокадровый скачок после commit: delta={frame_deltas}, "
            f"offsets={active_offsets(rig)}"
        )
    if frame_deltas[target] == 0:
        raise AssertionError(f"{name}: новый шар не начал анимационное движение")


def run_primary_cases() -> None:
    cases = (
        ("обычная вставка в голову", [0, 1, 2, 3], [0, 0, 0, 0], 0, 40),
        ("обычная вставка в середину", [0, 1, 2, 3], [0, 0, 0, 0], 2, 40),
        ("обычная вставка в хвост", [0, 1, 2, 3], [0, 0, 0, 0], 4, 40),
        ("вставка поверх положительной отдачи", [0, 1, 2, 3], [10, 10, 0, 0], 2, 40),
        ("вставка перед marker-gap", [0, 1, GAP_STOP, 2, 3], [0] * 5, 1, 40),
        ("вставка на marker-gap", [0, 1, GAP_STOP, 2, 3], [0] * 5, 2, 40),
        ("вставка после marker-gap", [0, 1, GAP_STOP, 2, 3], [0] * 5, 4, 40),
        ("хвостовая вставка при marker-gap", [0, 1, GAP_STOP, 2, 3], [0] * 5, 5, 40),
        ("вставка при двух marker-gap", [0, GAP_STOP, 1, GAP_STOP, 2, 3], [0] * 6, 4, 40),
        ("вставка на пределе трека", [0, 1, 2, 3], [0, 0, 0, 0], 2, 200),
    )
    for name, slots, offsets, target, hsa in cases:
        rig = Rig()
        rig.setup_chain(slots, hsa=hsa, freeze=0, speed=50)
        set_active_offsets(rig, offsets)
        check_insert(name, rig, target, 5)
        print(f"PASS: {name}")

    match = Rig()
    match.setup_chain([1, 2, 2, 3], hsa=40, freeze=0, speed=50)
    check_insert("немедленный match", match, 1, 2)
    frames = [
        match.sim.get_byte(match.s["Core.VDC_ExplodeFrame"] + index)
        for index in range(match.gb("Core.VDC_SlotsLen"))
    ]
    if frames[1:4] != [2, 2, 2]:
        raise AssertionError(f"немедленный match потерял анимацию взрыва: {frames}")
    print("PASS: немедленный match сохраняет insert/explosion-анимацию")


def run_repeated_cap_case() -> None:
    rig = Rig()
    rig.setup_chain([0, 1, 2, 3], hsa=200, freeze=0, speed=50)
    check_insert("первая вставка на пределе", rig, 2, 5, check_frame=False)
    check_insert("повторная вставка до decay", rig, 2, 4)
    print("PASS: повторная вставка до decay не срезает накопленную компенсацию")


def set_backing_byte(rig: Rig, symbol: str, value: int) -> None:
    local_start = rig.s["Core.VDC_ChainLocalStart"]
    backing = rig.s["Core.VDC2_ChainLocal"]
    rig.sim.set_byte(backing + rig.s[symbol] - local_start, value & 0xFF)


def set_backing_word(rig: Rig, symbol: str, value: int) -> None:
    local_start = rig.s["Core.VDC_ChainLocalStart"]
    backing = rig.s["Core.VDC2_ChainLocal"]
    address = backing + rig.s[symbol] - local_start
    rig.sim.set_byte(address, value & 0xFF)
    rig.sim.set_byte(address + 1, (value >> 8) & 0xFF)


def run_second_chain_case() -> None:
    rig = Rig()
    rig.setup_chain([0, 1, 2], hsa=30, freeze=0, speed=50)
    primary_before = (
        rig.gb("Core.VDC_HSA"),
        rig.gb("Core.VDC_SlotsLen"),
        bytes(rig.sim.get_byte(rig.s["Core.VDC_Slots"] + index) for index in range(4)),
        bytes(rig.sim.get_byte(rig.s["Core.VDC_Offsets"] + index) for index in range(4)),
    )
    rig.sb("Core.VDC_HasSecondChain", 1)
    second = [3, 4, GAP_STOP, 0, 1]
    rig.sb("Core.VDC2_SlotsLen", len(second))
    rig.sb("Core.VDC2_HSub", 0)
    for index, slot in enumerate(second):
        rig.sim.set_byte(rig.s["Core.VDC2_Slots"] + index, slot)
        for array in (
            "Core.VDC2_Offsets",
            "Core.VDC2_Shot2",
            "Core.VDC2_ExplodeFrame",
            "Core.VDC2_ExplodeMarker",
        ):
            rig.sim.set_byte(rig.s[array] + index, 0)
    set_backing_byte(rig, "Core.VDC_HSA", 50)
    set_backing_byte(rig, "Core.VDC_ChainFreezeCnt", 0)
    set_backing_byte(rig, "Core.VDC_GapPullVp", 10)
    set_backing_byte(rig, "Core.VDC_GapJunction", 0)
    set_backing_byte(rig, "Core.VDC_GapTempo", 10)
    set_backing_byte(rig, "Core.VDC_GapDecAcc", 0)
    set_backing_byte(rig, "Core.VDC_GapPosLeft", 0)
    set_backing_word(rig, "Core.VDC_GapAccum", 0)
    set_backing_word(rig, "Core.VDC_TrackNumSlots", 200)

    rig.sim.call(rig.s["Core.VDC_SwapChains"])
    rig.sim.call(rig.s["Core.VDC_MarkTopologyDirty"])
    check_insert("вставка во вторую цепь с marker-gap", rig, 4, 5)
    rig.sim.call(rig.s["Core.VDC_SwapChains"])

    primary_after = (
        rig.gb("Core.VDC_HSA"),
        rig.gb("Core.VDC_SlotsLen"),
        bytes(rig.sim.get_byte(rig.s["Core.VDC_Slots"] + index) for index in range(4)),
        bytes(rig.sim.get_byte(rig.s["Core.VDC_Offsets"] + index) for index in range(4)),
    )
    if primary_after != primary_before:
        raise AssertionError(
            f"вставка во вторую цепь изменила первую: {primary_before} -> {primary_after}"
        )
    print("PASS: анимация второй цепи независима от первой")


def main() -> int:
    run_primary_cases()
    run_repeated_cap_case()
    run_second_chain_case()
    print("PASS: все ветки VDC_InsertAt сохраняют непрерывную анимацию")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
