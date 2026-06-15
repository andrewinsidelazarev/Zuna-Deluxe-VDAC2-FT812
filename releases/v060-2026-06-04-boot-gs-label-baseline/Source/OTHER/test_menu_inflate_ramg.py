#!/usr/bin/env python3
"""Hook SafeInflatePage2 in Z80 emu, do REAL zlib via Python, dump RAM_G.

Goal: verify that after LoadMainMenuAssets the FT812 RAM_G actually holds
plausible PALETTED4444 pixel data at MENU_FG_RAMG=#000000, MENU_SKY_RAMG=#04B000,
etc. If data is corrupt → inflate args wrong. If data is OK → bug is in
rendering side (DL, palette, format).
"""
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator, PAGE_SIZE  # noqa: E402

ROOT = HERE.parent.parent
STUB = bytes([0xB7, 0xC9])  # OR A; RET


def stub(emu, name):
    a = emu.sym[name]
    for i, b in enumerate(STUB):
        emu.set_byte(a + i, b)


def main():
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym

    inflate_addr = sym["SafeInflatePage2"]

    # Track inflate calls
    calls = []

    orig_step = emu.step

    def hooked_step():
        if emu.reg.PC == inflate_addr:
            # On entry: A=dest_hi, DE=dest_lo, BC=size_lo, B' (alt)=size_hi,
            # HL=src_offset, A' (alt)=src_page
            dest = (emu.reg.A << 16) | (emu.reg.D << 8) | emu.reg.E
            size_lo = (emu.reg.B << 8) | emu.reg.C
            # Alt registers in cburbridge: A_, B_, C_, etc.
            size_hi = emu.reg["B_"]
            src_page = emu.reg["A_"]
            src_offset = (emu.reg.H << 8) | emu.reg.L

            # Read compressed data from physical memory (contiguous starting at
            # src_page * PAGE_SIZE + (src_offset & 0x3FFF)). SafeInflatePage2
            # will stream via PAGE2 at runtime, but the SPG physical layout is
            # still contiguous.
            phys_start = src_page * PAGE_SIZE + (src_offset & 0x3FFF)
            # Grab a big slice (zlib will stop when stream ends)
            phys_slice = bytes(emu.mem.physical[phys_start:phys_start + 200_000])
            try:
                decompressed = zlib.decompress(phys_slice)
            except Exception as e:
                calls.append((dest, src_page, src_offset, None, str(e)))
                # Simulate RET (clear CF, pop)
                sp = emu.reg.SP
                ret_addr = emu.mem.read(sp) | (emu.mem.read(sp + 1) << 8)
                emu.reg.SP = (sp + 2) & 0xFFFF
                emu.reg.PC = ret_addr
                emu.reg.F &= ~0x01  # clear CF
                return 0

            # Write decompressed into ft.ram_g at dest, emulating FT812
            # CMD_INFLATE completion.
            for i, byte in enumerate(decompressed):
                if dest + i < len(emu.ft.ram_g):
                    emu.ft.ram_g[dest + i] = byte
            calls.append((dest, src_page, src_offset, len(decompressed), None))

            # Simulate RET (clear CF, pop)
            sp = emu.reg.SP
            ret_addr = emu.mem.read(sp) | (emu.mem.read(sp + 1) << 8)
            emu.reg.SP = (sp + 2) & 0xFFFF
            emu.reg.PC = ret_addr
            emu.reg.F &= ~0x01
            return 0

        return orig_step()

    emu.step = hooked_step

    # Stub low-level FT calls just in case (SafeInflate hook bypasses them, but
    # other code paths might call).
    for n in ("FT.Coprocessor.WaitFlush", "FT.Coprocessor.Write",
              "FT.Coprocessor.Write32", "FT.Coprocessor.IsFault",
              "FT.Coprocessor.Wait"):
        if n in sym:
            stub(emu, n)

    # Init_Core
    emu.call(sym["Core.Init_Core"])
    # LoadMainMenuAssets
    print(f"[call] LoadMainMenuAssets @ #{sym['Core.LoadMainMenuAssets']:04X}")
    try:
        steps = emu.call(sym["Core.LoadMainMenuAssets"], max_steps=50_000_000)
    except TimeoutError as e:
        print(f"TIMEOUT: {e}")
        return 1
    print(f"returned in {steps:,} steps, {len(calls)} safe inflate calls")
    print()
    print(f"{'dest':>10}  {'page':>4}  {'src_off':>6}  {'dec_size':>8}  notes")
    for dest, page, off, dec, err in calls:
        n = err if err else ''
        ds = '-' if dec is None else f"{dec}"
        print(f"  #{dest:06X}  #{page:02X}  #{off:04X}     {ds:>8}  {n}")
    if not calls:
        print("FAIL: no SafeInflatePage2 calls were observed")
        return 1

    # Dump RAM_G regions
    print()
    print("RAM_G snapshots (first 16 bytes):")
    for name, addr in [
        ("MENU_FG  @ #000000", 0x000000),
        ("MENU_SKY @ #04B000", 0x04B000),
        ("MENU_SUN @ #065180", 0x065180),
        ("MENU_QUIT_N @ #09F410", 0x09F410),
        ("MENU_SKY_PAL @ #0ABA60", 0x0ABA60),
        ("MENU_UI_PAL  @ #0ABC60", 0x0ABC60),
    ]:
        data = bytes(emu.ft.ram_g[addr:addr + 16])
        non_zero = sum(1 for b in data if b)
        print(f"  {name}: {data.hex(' ')}  ({non_zero}/16 non-zero)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
