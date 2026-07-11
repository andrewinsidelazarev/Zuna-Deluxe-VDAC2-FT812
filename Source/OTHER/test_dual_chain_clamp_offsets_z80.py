#!/usr/bin/env python3
"""Проверка допустимого порядка offsets и указателя активной цепи."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def write_bytes(emu: ZumaFullZ80Emulator, addr: int, values: list[int]) -> None:
    for index, value in enumerate(values):
        emu.set_byte(addr + index, value & 0xFF)


def read_bytes(emu: ZumaFullZ80Emulator, addr: int, length: int) -> list[int]:
    return [emu.get_byte(addr + index) for index in range(length)]


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    s = emu.sym
    primary = [4, 50, 8, 60]
    secondary = [5, 50, 6, 60]

    emu.set_byte(s["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(s["Core.VDC_SecondActive"], 0)
    emu.set_byte(s["Core.VDC_SlotsLen"], len(primary))
    emu.set_byte(s["Core.VDC2_SlotsLen"], len(secondary))
    write_bytes(emu, s["Core.VDC_Offsets"], primary)
    write_bytes(emu, s["Core.VDC2_Offsets"], secondary)
    emu.call(s["Core.VDC_SelectChain1"], max_steps=20_000)

    emu.call(s["Core.VDC_SwapChains"], max_steps=200_000)
    if emu.get_byte(s["Core.VDC_SecondActive"]) != 1:
        raise AssertionError("swap did not activate chain2")
    if emu.get_word(s["Core.VDC_pOffsets"]) != s["Core.VDC2_Offsets"]:
        raise AssertionError("chain2 offset pointer was not selected")

    emu.call(s["ClampOffsetOrder"], max_steps=100_000)
    emu.call(s["Core.VDC_SwapChains"], max_steps=200_000)

    got_primary = read_bytes(emu, s["Core.VDC_Offsets"], len(primary))
    got_secondary = read_bytes(emu, s["Core.VDC2_Offsets"], len(secondary))
    if got_primary != primary:
        raise AssertionError(f"chain1 was clamped during chain2 update: {got_primary}")
    if got_secondary != [5, 36, 6, 37]:
        raise AssertionError(f"chain2 was not clamped through VDC_pOffsets: {got_secondary}")
    if emu.get_byte(s["Core.VDC_SecondActive"]) != 0:
        raise AssertionError("final swap did not restore chain1")

    print("PASS: ClampOffsetOrder ограничивает только offsets активной цепи")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
