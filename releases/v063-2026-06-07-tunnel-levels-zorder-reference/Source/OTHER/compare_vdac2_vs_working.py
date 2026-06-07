#!/usr/bin/env python3
"""Small diagnostics comparing VDAC2 runtime behavior with the working build.

This script does not patch game code.  It uses the assembled VDAC2 SPG through
zuma_full_z80_emulator.py and prints focused checks found by source comparison.
"""

from __future__ import annotations

from pathlib import Path

from zuma_full_z80_emulator import PROJECT_ROOT, ZumaFullZ80Emulator


WORKING_ROOT = Path(r"C:\Users\Администратор\Desktop\Zuma Deluxe")


def u16(emu: ZumaFullZ80Emulator) -> int:
    return ((emu.reg.H & 0xFF) << 8) | (emu.reg.L & 0xFF)


def signed16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def check_slot_before_head() -> None:
    emu = ZumaFullZ80Emulator(PROJECT_ROOT)
    emu.game_init()
    s = emu.sym

    emu.set_byte(s["Core.VDC_HSA"], 0)
    emu.set_byte(s["Core.VDC_HSub"], 0)
    emu.set_byte(s["Core.VDC_SlotsLen"], 2)
    emu.set_byte(s["Core.VDC_Slots"], 0)
    emu.set_byte(s["Core.VDC_Slots"] + 1, 1)
    emu.set_byte(s["Core.VDC_Offsets"], 0)
    emu.set_byte(s["Core.VDC_Offsets"] + 1, 0)

    emu.call(s["Core.VDC_SlotT"], a=1)
    t = u16(emu)
    emu.call(s["Core.VDC_SlotPos"], a=1)
    cf = bool(emu.reg.F & 1)
    x = ((emu.reg.B & 0xFF) << 8) | (emu.reg.C & 0xFF)
    y = ((emu.reg.D & 0xFF) << 8) | (emu.reg.E & 0xFF)

    print("check: slot before head")
    print("  setup: HSA=0 HSub=0 slot i=1 offset=0")
    print(f"  VDAC2 VDC_SlotT: 0x{t:04X} ({signed16(t)})")
    print(f"  VDAC2 VDC_SlotPos: CF={int(cf)} X={signed16(x)} Y={signed16(y)}")
    print("  working-source expectation: HSA-i<0 is PRESERVE/skip, not TrackData[0]")


def check_absorb_symbols() -> None:
    asm = PROJECT_ROOT / "Source" / "ASM" / "VDC.asm"
    working = WORKING_ROOT / "src" / "zuma_new_spg.asm"
    vdac2_text = asm.read_text(encoding="utf-8", errors="replace")
    working_text = working.read_text(encoding="utf-8", errors="replace")

    print("check: game-over absorption code presence")
    for name in ("GameState", "CheckHeadAtKillzone", "MoveChainAbsorb", "AbsorbHead"):
        print(
            f"  {name}: VDAC2={'yes' if name in vdac2_text else 'no'} "
            f"working={'yes' if name in working_text else 'no'}"
        )


def main() -> int:
    check_slot_before_head()
    print()
    check_absorb_symbols()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
