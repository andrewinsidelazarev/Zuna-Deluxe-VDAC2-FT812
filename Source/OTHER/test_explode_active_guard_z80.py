#!/usr/bin/env python3
"""Focused Z80 regression for the VDC_ExplodeActive idle-scan guard."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def setup_prefix(
    length: int,
    active: int,
    frames: list[int] | None = None,
    markers: list[int] | None = None,
) -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    arrays = (
        ("Core.VDC_pSlots", "Core.VDC_Slots"),
        ("Core.VDC_pOffsets", "Core.VDC_Offsets"),
        ("Core.VDC_pShot2", "Core.VDC_Shot2"),
        ("Core.VDC_pExplodeFrame", "Core.VDC_ExplodeFrame"),
        ("Core.VDC_pExplodeMarker", "Core.VDC_ExplodeMarker"),
    )
    for pointer, base in arrays:
        emu.set_word(s[pointer], s[base])
    emu.set_byte(s["Core.VDC_SlotsLen"], length)
    emu.set_byte(s["Core.VDC_ExplodeActive"], active)
    frames = frames or [0] * length
    markers = markers or [0xFE] * length
    for index in range(length):
        emu.set_byte(s["Core.VDC_Slots"] + index, index % 6)
        emu.set_byte(s["Core.VDC_Offsets"] + index, (index + 3) & 0xFF)
        emu.set_byte(s["Core.VDC_Shot2"] + index, 0)
        emu.set_byte(s["Core.VDC_ExplodeFrame"] + index, frames[index])
        emu.set_byte(s["Core.VDC_ExplodeMarker"] + index, markers[index])
    return emu


def run_prefix(emu: ZumaFullZ80Emulator) -> int:
    s = emu.sym
    emu.reg.PC = s["Core.VDC_AnimateChain"]
    before = emu.tstates
    emu.run_until_pc(s["Core.VDC_AnimateChain.ac_after_explode"], max_steps=100_000)
    return emu.tstates - before


def snapshot(emu: ZumaFullZ80Emulator, length: int) -> tuple[bytes, ...]:
    s = emu.sym
    return (
        bytes((emu.get_byte(s["Core.VDC_ExplodeActive"]),)),
        bytes(emu.get_memory(s["Core.VDC_Slots"], length)),
        bytes(emu.get_memory(s["Core.VDC_Offsets"], length)),
        bytes(emu.get_memory(s["Core.VDC_ExplodeFrame"], length)),
        bytes(emu.get_memory(s["Core.VDC_ExplodeMarker"], length)),
    )


def check_idle_cost() -> None:
    fast = setup_prefix(70, 0)
    forced_scan = setup_prefix(70, 1)
    fast_t = run_prefix(fast)
    scan_t = run_prefix(forced_scan)
    if snapshot(fast, 70) != snapshot(forced_scan, 70):
        raise AssertionError("idle guard changed explosion-prefix state")
    expected_delta = 42 * 70 + 51
    if scan_t - fast_t != expected_delta:
        raise AssertionError(
            f"unexpected guard timing: fast={fast_t}, scan={scan_t}, "
            f"delta={scan_t - fast_t}, expected={expected_delta}"
        )
    print(f"PASS idle: {scan_t}->{fast_t} T, guard delta={scan_t - fast_t}")


def check_last_frame_relatch() -> None:
    emu = setup_prefix(
        4,
        1,
        frames=[0, 14, 15, 0],
        markers=[0xFE, 0xFE, 0xFD, 0xFE],
    )
    s = emu.sym
    run_prefix(emu)
    frames = list(emu.get_memory(s["Core.VDC_ExplodeFrame"], 4))
    if frames != [0, 15, 0, 0]:
        raise AssertionError(f"mixed active frames advanced incorrectly: {frames}")
    if emu.get_byte(s["Core.VDC_Slots"] + 2) != 0xFD:
        raise AssertionError("final frame did not restore its baked marker")
    if emu.get_byte(s["Core.VDC_Offsets"] + 2) != 0:
        raise AssertionError("final frame did not clear its slot offset")
    if emu.get_byte(s["Core.VDC_ExplodeActive"]) != 1:
        raise AssertionError("surviving frame did not re-latch ExplodeActive")

    run_prefix(emu)
    if emu.get_byte(s["Core.VDC_ExplodeActive"]) != 0:
        raise AssertionError("last explosion frame did not clear ExplodeActive")
    if emu.get_byte(s["Core.VDC_Slots"] + 1) != 0xFE:
        raise AssertionError("last survivor did not finalize")
    print("PASS mixed last-frame finalization and re-latch")


def check_empty_normalizes() -> None:
    emu = setup_prefix(0, 1)
    run_prefix(emu)
    if emu.get_byte(emu.sym["Core.VDC_ExplodeActive"]) != 0:
        raise AssertionError("Active=1/SlotsLen=0 did not normalize to zero")
    print("PASS empty active chain normalizes")


def check_dual_chain_latch() -> None:
    emu = setup_prefix(4, 0)
    s = emu.sym
    local_len = s["Core.VDC_ChainLocalEnd"] - s["Core.VDC_ChainLocalStart"]
    for index in range(local_len):
        emu.set_byte(s["Core.VDC2_ChainLocal"] + index, 0)
    c2_active = s["Core.VDC2_ChainLocal"] + (
        s["Core.VDC_ExplodeActive"] - s["Core.VDC_ChainLocalStart"]
    )
    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(s["Core.VDC2_SlotsLen"], 4)
    emu.set_byte(c2_active, 1)
    for index in range(4):
        emu.set_byte(s["Core.VDC2_Slots"] + index, index)
        emu.set_byte(s["Core.VDC2_Offsets"] + index, 7)
        emu.set_byte(s["Core.VDC2_ExplodeFrame"] + index, 14 if index == 1 else 0)
        emu.set_byte(s["Core.VDC2_ExplodeMarker"] + index, 0xFE)
    emu.call(s["Core.VDC_SelectChain1"])

    emu.call(s["Core.VDC_SwapChains"])
    run_prefix(emu)
    emu.call(s["Core.VDC_SwapChains"])
    if emu.get_byte(s["Core.VDC2_ExplodeFrame"] + 1) != 15 or emu.get_byte(c2_active) != 1:
        raise AssertionError("chain-2 survivor/latch was not stored independently")
    if emu.get_byte(s["Core.VDC_ExplodeActive"]) != 0:
        raise AssertionError("chain-2 animation leaked into chain 1 latch")

    emu.call(s["Core.VDC_SwapChains"])
    run_prefix(emu)
    emu.call(s["Core.VDC_SwapChains"])
    if emu.get_byte(s["Core.VDC2_ExplodeFrame"] + 1) != 0 or emu.get_byte(c2_active) != 0:
        raise AssertionError("chain-2 last frame did not clear its own latch")
    print("PASS dual-chain latches remain independent")


def main() -> int:
    check_idle_cost()
    check_last_frame_relatch()
    check_empty_normalizes()
    check_dual_chain_latch()
    print("PASS: VDC_ExplodeActive guard is exact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
