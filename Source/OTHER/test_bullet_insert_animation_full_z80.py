#!/usr/bin/env python3
"""Полный ZBT1 hit не должен телепортировать цепь при внутренней дырке."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Source" / "OTHER"))

from make_level_pack import encode_track_v4_record  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa: E402


CELL = 32
GAP_STOP = 0xFE


def signed(value: int) -> int:
    return value - 256 if value >= 128 else value


def main() -> int:
    emulator = ZumaFullZ80Emulator(ROOT)
    symbols = emulator.sym

    def set_byte(name: str, value: int) -> None:
        emulator.set_byte(symbols[name], value)

    def set_word(name: str, value: int) -> None:
        emulator.set_word(symbols[name], value)

    emulator.call(symbols["Core.VDC_SelectChain1"], max_steps=10_000)
    set_byte("Core.VDC_HasSecondChain", 0)
    set_byte("Core.VDC_SecondActive", 0)
    set_byte("Core.Bullet_EventTrackState", 0)
    set_byte("Core.VDC_TrackPageCount1", 1)
    emulator.set_byte(symbols["Core.VDC_TrackPages1"], 0x06)
    set_word("Core.VDC_TrackSamples1", 512)

    slots = [0, 1, GAP_STOP, 2, 3]
    for index in range(8):
        emulator.set_byte(symbols["Core.VDC_Slots"] + index, GAP_STOP)
        for array in (
            "Core.VDC_Offsets",
            "Core.VDC_Shot2",
            "Core.VDC_ExplodeFrame",
            "Core.VDC_ExplodeMarker",
        ):
            emulator.set_byte(symbols[array] + index, 0)
    for index, slot in enumerate(slots):
        emulator.set_byte(symbols["Core.VDC_Slots"] + index, slot)

    set_byte("Core.VDC_SlotsLen", len(slots))
    set_byte("Core.VDC_HSA", 5)
    set_byte("Core.VDC_HSub", 0)
    set_word("Core.VDC_TrackNumSlots", 100)
    set_byte("Core.VDC_GameState", 0)
    set_byte("Core.VDC_GapJunction", 0)
    set_byte("Core.VDC_GapPosLeft", 0)
    set_byte("Core.VDC_BridgeScanActive", 0)
    emulator.call(symbols["Core.VDC_MarkTopologyDirty"], max_steps=10_000)

    # Геометрия даёт hit старого slot 3 и вставку перед ним. В старом коде
    # именно этот production-путь телепортировал весь suffix на -32 sample.
    centers = {
        0: (100, 200),
        1: (180, 200),
        3: (196, 200),
        4: (240, 200),
    }
    for index, (x, y) in centers.items():
        track_t = (5 - index) * CELL
        record = encode_track_v4_record(
            (x - 26) * 16,
            (y - 26) * 16,
            0,
            0,
            ((track_t * 61) >> 8) % 12,
        )
        physical = 0x06 * PAGE_SIZE + track_t * 8
        emulator.mem.physical[physical : physical + 8] = record
    emulator.call(symbols["Core.SetCurrentTrackPage"], max_steps=10_000)

    def old_positions() -> dict[int, int]:
        result: dict[int, int] = {}
        hsa = emulator.get_byte(symbols["Core.VDC_HSA"])
        hsub = emulator.get_byte(symbols["Core.VDC_HSub"])
        length = emulator.get_byte(symbols["Core.VDC_SlotsLen"])
        for index in range(length):
            color = emulator.get_byte(symbols["Core.VDC_Slots"] + index)
            if color >= 4:
                continue
            offset = signed(emulator.get_byte(symbols["Core.VDC_Offsets"] + index))
            result[color] = (hsa - index) * CELL + hsub + offset
        return result

    before = old_positions()
    event_page = 0x13 * PAGE_SIZE
    emulator.mem.physical[event_page : event_page + 4] = bytes((1, 0x02, 2, 0))
    set_byte("Core.BulletTrajValid", 1)
    set_byte("Core.Bullet_Frame", 1)
    set_byte("Core.Bullet_EventCount", 1)
    set_word("Core.Bullet_EventPtr", 0x8000)
    set_byte("Core.Bullet_Active", 1)
    set_word("Core.Bullet_X", 196)
    set_word("Core.Bullet_Y", 200)
    set_byte("Core.Bullet_Color", 5)
    set_byte("Core.Bullet_NoHitMask", 0)
    set_byte("Core.Bullet_TunnelSeen", 0)

    emulator.call(symbols["Core.Bullet_CheckCollisionEvents"], max_steps=2_000_000)
    after = old_positions()
    actual_slots = [
        emulator.get_byte(symbols["Core.VDC_Slots"] + index)
        for index in range(6)
    ]
    if emulator.get_byte(symbols["Core.Bullet_Active"]) != 0:
        raise AssertionError("production event не погасил попавшую пулю")
    if emulator.get_byte(symbols["Core.VDC_TmpInsIdx"]) != 3:
        raise AssertionError("production event выбрал неожиданную сторону вставки")
    if actual_slots != [0, 1, GAP_STOP, 5, 2, 3]:
        raise AssertionError(f"production event испортил порядок slots: {actual_slots}")
    if after != before:
        deltas = {color: after[color] - before[color] for color in before}
        raise AssertionError(
            f"production event резко сдвинул старые шары: delta={deltas}"
        )
    new_offset = signed(emulator.get_byte(symbols["Core.VDC_Offsets"] + 3))
    new_position = (5 - 3) * CELL + new_offset
    if new_position != 80:
        raise AssertionError(f"production event не начал half-cell-анимацию: t={new_position}")

    print("PASS: полный BulletTraj GAP-hit сохраняет координаты старой цепи")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
