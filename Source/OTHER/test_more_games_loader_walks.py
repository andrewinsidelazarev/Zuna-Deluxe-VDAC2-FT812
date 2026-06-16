#!/usr/bin/env python3
"""Z80-side smoke test for the More Games room loader."""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
STUB = bytes([0xB7, 0xC9])  # OR A; RET
STUB_CARRY = bytes([0x37, 0xC9])  # SCF; RET
STUB_RELEASED = bytes([0xAF, 0xC9])  # XOR A; RET (Z)
STUB_PRESSED = bytes([0x3E, 0x01, 0xB7, 0xC9])  # LD A,1; OR A; RET (NZ)


def stub_routine(emu, sym_name: str, code: bytes = STUB) -> int:
    addr = emu.sym[sym_name]
    for index, byte in enumerate(code):
        emu.set_byte(addr + index, byte)
    return addr


def symbol(emu, *names: str) -> int | None:
    for name in names:
        addr = emu.sym.get(name)
        if addr is not None:
            return addr
    return None


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    if emu.errors:
        print(f"[load] {len(emu.errors)} warning(s) (non-fatal)")

    needed = (
        "Core.Init_Core",
        "FT.Coprocessor.WaitFlush",
        "FT.Coprocessor.Write",
        "FT.Coprocessor.Write32",
        "FT.Coprocessor.IsFault",
        "FT.Coprocessor.Wait",
    )
    for name in needed:
        if name not in emu.sym:
            print(f"FAIL: missing symbol {name}")
            return 1
    load_more_addr = symbol(emu, "Core.LoadMoreGamesAssets", "LoadMoreGamesAssets")
    if load_more_addr is None:
        print("FAIL: missing symbol Core.LoadMoreGamesAssets")
        return 1

    emu.call(emu.sym["Core.Init_Core"])
    for name in needed[1:]:
        addr = stub_routine(emu, name)
        print(f"[stub] {name} @ #{addr:04X} = OR A; RET")

    addr = load_more_addr
    print(f"[call] LoadMoreGamesAssets @ #{addr:04X}")
    total_steps = 0
    before = emu.tstates
    for run in (1, 2):
        try:
            steps = emu.call(addr, max_steps=10_000_000)
        except TimeoutError as error:
            print(f"FAIL: run {run}: {error}")
            return 1
        total_steps += steps
        print(
            f"  run {run}: steps={steps:,} "
            f"slot2=#{emu.mem.pages[2]:02X} slot3=#{emu.mem.pages[3]:02X}"
        )
        if emu.mem.pages[2] != 0x06 or emu.mem.pages[3] != 0x41:
            print("FAIL: loader did not restore UI paging")
            return 1

    print("PASS: two consecutive loads returned cleanly")
    print(f"  steps   = {total_steps:,}")
    print(f"  t-states= {emu.tstates - before:,}")

    addr_write32 = stub_routine(emu, "FT.Coprocessor.Write32", STUB_CARRY)
    print(f"[stub] FT.Coprocessor.Write32 @ #{addr_write32:04X} = SCF; RET")
    try:
        emu.call(addr, max_steps=10_000_000)
    except TimeoutError as error:
        print(f"FAIL: Write32 carry path corrupted control flow: {error}")
        return 1
    if emu.mem.pages[2] != 0x06 or emu.mem.pages[3] != 0x41:
        print("FAIL: Write32 carry path did not restore UI paging")
        return 1
    print("PASS: Write32 carry path returned without stack damage")

    exit_addr = symbol(emu, "Core.MoreGamesExitPressed", "MoreGamesExitPressed")
    lmb_prev = symbol(emu, "Core.MoreGamesLmbPrev", "MoreGamesLmbPrev")
    fire_prev = symbol(emu, "Core.MoreGamesFirePrev", "MoreGamesFirePrev")
    esc_prev = symbol(emu, "Core.MoreGamesEscPrev", "MoreGamesEscPrev")
    if None in (exit_addr, lmb_prev, fire_prev, esc_prev):
        print("FAIL: missing More Games input symbols")
        return 1

    stub_routine(emu, "Core.Input_FireKey", STUB_RELEASED)
    stub_routine(emu, "Core.Input_Esc", STUB_RELEASED)

    def call_exit_with_mouse(code: bytes, prev_lmb: int) -> int:
        emu.set_byte(fire_prev, 0)
        emu.set_byte(esc_prev, 0)
        emu.set_byte(lmb_prev, prev_lmb)
        stub_routine(emu, "Core.Input_MouseLMB", code)
        emu.call(exit_addr, max_steps=1_000_000)
        return emu.reg.A

    if call_exit_with_mouse(STUB_PRESSED, 0) != 1:
        print("FAIL: LMB press edge did not exit")
        return 1
    if call_exit_with_mouse(STUB_RELEASED, 1) != 1:
        print("FAIL: LMB release edge did not exit")
        return 1
    if call_exit_with_mouse(STUB_RELEASED, 0) != 0:
        print("FAIL: released LMB without prior down triggered exit")
        return 1
    print("PASS: LMB exits on first press edge or matching release edge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
