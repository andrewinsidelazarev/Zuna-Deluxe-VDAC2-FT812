#!/usr/bin/env python3
"""Z80-side smoke test for the More Games room loader."""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
STUB = bytes([0xB7, 0xC9])  # OR A; RET


def stub_routine(emu, sym_name: str) -> int:
    addr = emu.sym[sym_name]
    for index, byte in enumerate(STUB):
        emu.set_byte(addr + index, byte)
    return addr


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    if emu.errors:
        print(f"[load] {len(emu.errors)} warning(s) (non-fatal)")

    needed = (
        "Core.Init_Core",
        "LoadMoreGamesAssets",
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

    emu.call(emu.sym["Core.Init_Core"])
    for name in needed[2:]:
        addr = stub_routine(emu, name)
        print(f"[stub] {name} @ #{addr:04X} = OR A; RET")

    addr = emu.sym["LoadMoreGamesAssets"]
    print(f"[call] LoadMoreGamesAssets @ #{addr:04X}")
    before = emu.tstates
    try:
        steps = emu.call(addr, max_steps=10_000_000)
    except TimeoutError as error:
        print(f"FAIL: {error}")
        return 1

    print("PASS: returned cleanly")
    print(f"  steps   = {steps:,}")
    print(f"  t-states= {emu.tstates - before:,}")
    print(f"  slot2   = #{emu.mem.pages[2]:02X}")
    print(f"  slot3   = #{emu.mem.pages[3]:02X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
