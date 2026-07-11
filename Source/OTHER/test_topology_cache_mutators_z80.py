#!/usr/bin/env python3
"""Production-mutator and dual-chain regression for the topology cache."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_gap_scan_selection_z80 import call_with_hits, internal_gap, junction  # noqa: E402
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
STOP = 0xFE
DIRTY_MASK = 0xC0


def new_emu() -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    emu.call(s["Core.VDC_SelectChain1"])
    emu.set_byte(s["Core.VDC_SecondActive"], 0)
    emu.set_byte(s["Core.VDC_HasSecondChain"], 0)
    emu.set_byte(s["Core.VDC_GameState"], 0)
    emu.set_byte(s["Core.VDC_GaugeFull"], 0)
    emu.set_byte(s["Core.VDC_LevelColors"], 6)
    emu.set_word(s["Core.VDC_TrackNumSlots"], 200)
    return emu


def active_bases(emu: ZumaFullZ80Emulator) -> tuple[int, int, int, int, int]:
    s = emu.sym
    return tuple(
        emu.get_word(s[name])
        for name in (
            "Core.VDC_pSlots",
            "Core.VDC_pOffsets",
            "Core.VDC_pShot2",
            "Core.VDC_pExplodeFrame",
            "Core.VDC_pExplodeMarker",
        )
    )


def state_addr(emu: ZumaFullZ80Emulator) -> int:
    return emu.get_word(emu.sym["Core.VDC_pSlots"]) - 1


def set_layout(emu: ZumaFullZ80Emulator, values: list[int]) -> None:
    s = emu.sym
    slots, offsets, shot2, explode, markers = active_bases(emu)
    emu.set_byte(s["Core.VDC_SlotsLen"], len(values))
    for index in range(max(16, len(values) + 2)):
        emu.set_byte(slots + index, values[index] if index < len(values) else 0xA5)
        emu.set_byte(offsets + index, 0)
        emu.set_byte(shot2 + index, 0)
        emu.set_byte(explode + index, 0)
        emu.set_byte(markers + index, 0)
    emu.call(s["Core.VDC_MarkTopologyDirty"])


def current_layout(emu: ZumaFullZ80Emulator) -> list[int]:
    length = emu.get_byte(emu.sym["Core.VDC_SlotsLen"])
    slots = emu.get_word(emu.sym["Core.VDC_pSlots"])
    return list(emu.get_memory(slots, length))


def warm(emu: ZumaFullZ80Emulator) -> None:
    s = emu.sym
    emu.call(s["Core.VDC_InternalGapExistsCached"])
    emu.call(s["Core.VDC_EnsureGapJunction"])
    if emu.get_byte(state_addr(emu)) & DIRTY_MASK:
        raise AssertionError("topology cache did not become clean")


def verify(emu: ZumaFullZ80Emulator, *, expect_miss: bool) -> None:
    s = emu.sym
    values = current_layout(emu)
    expected_internal = internal_gap(values)
    expected_junction = junction(values)
    hits_i = call_with_hits(
        emu,
        s["Core.VDC_InternalGapExistsCached"],
        s["Core.VDC_InternalGapExists"],
        initial_carry=0 if expected_internal else 1,
    )
    got_internal = bool(emu.reg.F & 1)
    hits_j = call_with_hits(
        emu,
        s["Core.VDC_EnsureGapJunction"],
        s["Core.VDC_GapJunctionUpdate"],
    )
    got_junction = emu.get_byte(s["Core.VDC_GapJunction"])
    expected_hits = 1 if expect_miss else 0
    if (hits_i, hits_j) != (expected_hits, expected_hits):
        raise AssertionError(
            f"layout {values}: raw hits {(hits_i, hits_j)} != {(expected_hits, expected_hits)}"
        )
    if got_internal != expected_internal or got_junction != expected_junction:
        raise AssertionError(
            f"layout {values}: got {got_internal}/{got_junction}, "
            f"expected {expected_internal}/{expected_junction}"
        )


def check_spawn() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [0, STOP])
    warm(emu)
    emu.set_byte(s["Core.VDC_HSA"], 2)
    emu.set_byte(s["Core.VDC_SpawnClusterRem"], 1)
    emu.set_byte(s["Core.VDC_SpawnClusterColor"], 0)
    emu.call(s["Core.VDC_TrySpawn_NoHsubGate"])
    if current_layout(emu) != [0, STOP, 0]:
        raise AssertionError("successful spawn did not append the deterministic color")
    if emu.get_byte(state_addr(emu)) & DIRTY_MASK != DIRTY_MASK:
        raise AssertionError("successful spawn did not dirty both topology results")
    verify(emu, expect_miss=True)

    warm(emu)
    before_state = emu.get_byte(state_addr(emu))
    before_layout = current_layout(emu)
    emu.set_byte(s["Core.VDC_GaugeFull"], 1)
    emu.call(s["Core.VDC_TrySpawn_NoHsubGate"])
    if current_layout(emu) != before_layout or emu.get_byte(state_addr(emu)) != before_state:
        raise AssertionError("blocked spawn invalidated an unchanged topology")
    verify(emu, expect_miss=False)
    print("PASS spawn commit/no-op invalidation")


def run_explosion_prefix(emu: ZumaFullZ80Emulator) -> None:
    s = emu.sym
    emu.reg.PC = s["Core.VDC_AnimateChain"]
    emu.run_until_pc(s["Core.VDC_AnimateChain.ac_after_explode"], max_steps=100_000)


def check_explosion() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [0, 1, 0])
    warm(emu)
    _, _, _, explode, markers = active_bases(emu)
    emu.set_byte(explode + 1, 15)
    emu.set_byte(markers + 1, STOP)
    emu.set_byte(s["Core.VDC_ExplodeActive"], 1)
    run_explosion_prefix(emu)
    if current_layout(emu) != [0, STOP, 0]:
        raise AssertionError("terminal explosion did not commit its marker")
    if emu.get_byte(state_addr(emu)) & DIRTY_MASK != DIRTY_MASK:
        raise AssertionError("terminal explosion did not dirty topology")
    verify(emu, expect_miss=True)
    print("PASS terminal explosion invalidation")


def remove(emu: ZumaFullZ80Emulator, values: list[int], index: int) -> list[int]:
    s = emu.sym
    set_layout(emu, values)
    warm(emu)
    emu.set_byte(s["Core.VDC_TmpGapIdx"], index)
    emu.call(s["Core.VDC_RemoveSlotAt"])
    if emu.get_byte(state_addr(emu)) & DIRTY_MASK != DIRTY_MASK:
        raise AssertionError("slot removal did not dirty topology")
    verify(emu, expect_miss=True)
    return current_layout(emu)


def check_remove() -> None:
    emu = new_emu()
    if remove(emu, [0, STOP, 1], 1) != [0, 1]:
        raise AssertionError("middle removal shifted Slots incorrectly")
    if remove(emu, [0, STOP], 1) != [0]:
        raise AssertionError("tail removal changed the live prefix incorrectly")
    print("PASS middle/tail removal invalidation")


def insert(emu: ZumaFullZ80Emulator, values: list[int], index: int, color: int) -> list[int]:
    s = emu.sym
    set_layout(emu, values)
    warm(emu)
    emu.set_byte(s["Core.VDC_HSA"], 20)
    emu.call(s["Core.VDC_InsertAt"], a=index, b=color, max_steps=500_000)
    if emu.get_byte(state_addr(emu)) & DIRTY_MASK != DIRTY_MASK:
        raise AssertionError("successful insert did not dirty topology")
    verify(emu, expect_miss=True)
    return current_layout(emu)


def check_insert() -> None:
    emu = new_emu()
    if insert(emu, [0, STOP], 2, 1) != [0, STOP, 1]:
        raise AssertionError("append insert is wrong")
    if insert(emu, [0, STOP, 0], 1, 1) != [0, 1, STOP, 0]:
        raise AssertionError("shifted insert is wrong")
    print("PASS append/shift insert invalidation")


def check_dual_isolation() -> None:
    emu = new_emu()
    s = emu.sym
    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    set_layout(emu, [0, STOP, 0])
    warm(emu)
    state1 = state_addr(emu)

    emu.call(s["Core.VDC_SwapChains"])
    set_layout(emu, [0, STOP, 1])
    warm(emu)
    state2 = state_addr(emu)
    emu.set_byte(s["Core.VDC_TmpGapIdx"], 1)
    emu.call(s["Core.VDC_RemoveSlotAt"])
    if emu.get_byte(state2) & DIRTY_MASK != DIRTY_MASK:
        raise AssertionError("chain 2 mutation did not dirty chain 2")

    emu.call(s["Core.VDC_SwapChains"])
    if emu.get_byte(state1) & DIRTY_MASK:
        raise AssertionError("chain 2 mutation dirtied chain 1 cache")
    verify(emu, expect_miss=False)

    emu.call(s["Core.VDC_SwapChains"])
    verify(emu, expect_miss=True)
    if current_layout(emu) != [0, 1]:
        raise AssertionError("chain 2 topology changed incorrectly")
    emu.call(s["Core.VDC_SwapChains"])
    print("PASS dual-chain topology caches remain independent")


def main() -> int:
    check_spawn()
    check_explosion()
    check_remove()
    check_insert()
    check_dual_isolation()
    print("PASS: all production topology mutators preserve cache correctness")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
