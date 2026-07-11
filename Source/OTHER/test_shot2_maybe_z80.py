#!/usr/bin/env python3
"""Regression for the conservative per-chain Shot2-maybe latch."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from test_gap_scan_selection_z80 import call_with_hits  # noqa: E402
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
SHOT2_MAYBE = 0x20


def new_emu() -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    emu.call(s["Core.VDC_SelectChain1"])
    emu.set_byte(s["Core.VDC_SecondActive"], 0)
    emu.set_byte(s["Core.VDC_HasSecondChain"], 0)
    emu.set_byte(s["Core.VDC_GameState"], 0)
    emu.set_byte(s["Core.VDC_LevelColors"], 6)
    emu.set_word(s["Core.VDC_TrackNumSlots"], 200)
    return emu


def bases(emu: ZumaFullZ80Emulator) -> tuple[int, int, int, int, int]:
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
    slots, offsets, shot2, explode, markers = bases(emu)
    emu.set_byte(s["Core.VDC_SlotsLen"], len(values))
    for index in range(max(70, len(values) + 2)):
        emu.set_byte(slots + index, values[index] if index < len(values) else 0)
        emu.set_byte(offsets + index, 0)
        emu.set_byte(shot2 + index, 0)
        emu.set_byte(explode + index, 0)
        emu.set_byte(markers + index, 0)
    emu.call(s["Core.VDC_MarkTopologyDirty"])
    emu.call(s["Core.VDC_ClearShot2Maybe"])


def timed_call(emu: ZumaFullZ80Emulator, symbol: str) -> int:
    start = emu.tstates
    emu.call(emu.sym[symbol], max_steps=500_000)
    return emu.tstates - start


def check_idle_and_false_positive() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [index % 6 for index in range(70)])
    emu.set_byte(s["Core.VDC_ScanGapBusy"], 0xA5)
    ticks = timed_call(emu, "Core.VDC_ScanForNewMatch")
    if ticks != 103:
        raise AssertionError(f"idle Shot2 fast path costs {ticks} T, expected 103")
    if emu.get_byte(s["Core.VDC_ScanGapBusy"]) != 0:
        raise AssertionError("idle fast path lost the ScanGapBusy=0 side effect")
    if emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("idle fast path raised Shot2-maybe")

    emu.call(s["Core.VDC_MarkShot2Maybe"])
    first = timed_call(emu, "Core.VDC_ScanForNewMatch")
    if emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("full all-zero proof did not clear a false positive")
    second = timed_call(emu, "Core.VDC_ScanForNewMatch")
    if first != 2756 or second != 103:
        raise AssertionError(f"false-positive timing is {first}->{second}, expected 2756->103")
    print(f"PASS idle/false-positive timing: {first}->{second} T")


def check_set_neighbors_and_clear() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [2, 2])
    _, _, shot2, _, _ = bases(emu)
    emu.set_byte(s["Core.VDC_TmpGapIdx"], 1)
    emu.call(s["Core.VDC_SetShot2OnNeighbors"])
    if list(emu.get_memory(shot2, 2)) != [1, 1]:
        raise AssertionError("same-color closure did not arm both Shot2 neighbors")
    if not emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("SetShot2OnNeighbors did not raise Shot2-maybe")
    if emu.get_byte(s["Core.VDC_BridgeScanActive"]) != 1:
        raise AssertionError("same-color closure did not arm bridge scanning")

    emu.set_byte(s["Core.VDC_BridgeScanActive"], 0)
    emu.set_byte(s["Core.VDC_ChainFreezeCnt"], 0)
    emu.call(s["Core.VDC_ClearStaleShot2"])
    if any(emu.get_memory(shot2, 2)) or emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("proven stale Shot2 did not clear data and latch")
    print("PASS SetShot2OnNeighbors and proven full clear")


def check_pending_and_remove() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [1, 2, 3])
    _, offsets, shot2, _, _ = bases(emu)
    emu.set_byte(shot2 + 1, 1)
    emu.set_byte(offsets + 1, 0xE0)  # -32: delayed insert is still moving
    emu.call(s["Core.VDC_MarkShot2Maybe"])
    emu.call(s["Core.VDC_ScanForNewMatch"])
    if emu.get_byte(shot2 + 1) != 1 or not emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("pending moving Shot2 or its latch was cleared early")

    emu.set_byte(s["Core.VDC_TmpGapIdx"], 0)
    emu.call(s["Core.VDC_RemoveSlotAt"])
    if emu.get_byte(shot2) != 1 or not emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("RemoveSlotAt lost a shifted Shot2/latch")
    print("PASS pending and shifted Shot2 preserve the latch")


def check_insert_writer() -> None:
    emu = new_emu()
    s = emu.sym
    set_layout(emu, [0, 1])
    emu.set_byte(s["Core.VDC_HSA"], 20)
    emu.call(s["Core.VDC_InsertAt"], a=1, b=2, max_steps=500_000)
    _, _, shot2, _, _ = bases(emu)
    if emu.get_byte(shot2 + 1) != 1 or not emu.get_byte(state_addr(emu)) & SHOT2_MAYBE:
        raise AssertionError("VDC_InsertAt did not arm Shot2-maybe")
    print("PASS insert writer raises Shot2-maybe")


def check_dual_isolation() -> None:
    emu = new_emu()
    s = emu.sym
    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    set_layout(emu, [0, 1, 2])
    state1 = state_addr(emu)

    emu.call(s["Core.VDC_SwapChains"])
    set_layout(emu, [1, 2, 3])
    state2 = state_addr(emu)
    _, offsets2, shot22, _, _ = bases(emu)
    emu.set_byte(shot22 + 1, 1)
    emu.set_byte(offsets2 + 1, 0xE0)
    emu.call(s["Core.VDC_MarkShot2Maybe"])
    for _ in range(10):
        emu.call(s["Core.VDC_SwapChains"])
        emu.call(s["Core.VDC_SwapChains"])
    emu.call(s["Core.VDC_SwapChains"])

    if emu.get_byte(state1) & SHOT2_MAYBE:
        raise AssertionError("chain 2 Shot2-maybe leaked into chain 1")
    hits = call_with_hits(
        emu,
        s["Core.VDC_ScanForNewMatch"],
        s["Core.VDC_ScanForNewMatch.snm_any_shot2"],
    )
    if hits != 0 or emu.get_byte(state2) & SHOT2_MAYBE == 0:
        raise AssertionError("chain 1 fast scan changed chain 2 latch")

    emu.call(s["Core.VDC_SwapChains"])
    hits = call_with_hits(
        emu,
        s["Core.VDC_ScanForNewMatch"],
        s["Core.VDC_ScanForNewMatch.snm_any_shot2"],
    )
    if hits == 0 or emu.get_byte(shot22 + 1) != 1:
        raise AssertionError(
            "chain 2 scan did not see its pending Shot2: "
            f"hits={hits} shot={emu.get_byte(shot22 + 1)} "
            f"second={emu.get_byte(s['Core.VDC_SecondActive'])} "
            f"pShot2={emu.get_word(s['Core.VDC_pShot2']):#06x} "
            f"state1={emu.get_byte(state1):#04x} state2={emu.get_byte(state2):#04x}"
        )
    emu.call(s["Core.VDC_SwapChains"])
    print("PASS dual-chain Shot2-maybe latches remain independent")


def main() -> int:
    check_idle_and_false_positive()
    check_set_neighbors_and_clear()
    check_pending_and_remove()
    check_insert_writer()
    check_dual_isolation()
    print("PASS: Shot2-maybe latch is conservative and exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
