#!/usr/bin/env python3
"""
Diagnostic for v021 main0/main1 split. Loads SPG via paged emulator,
runs bootstrap from Core.Start (#5C00), and reports:
  - Initial page mapping
  - Page mapping after FMapAddrInit + SetPage1/2/3
  - Whether main1_play.bin is visible at #C000 after Init_Core
  - Where Z80 hangs/diverges if Initialize doesn't complete

Run after sjasmplus+spgbld of the split build.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

from zuma_full_z80_emulator import ZumaFullZ80Emulator, PROJECT_ROOT, RETURN_MARKER

def hex32(b):
    return ' '.join(f'{x:02x}' for x in b[:16])

def main():
    emu = ZumaFullZ80Emulator()
    sym = emu.sym

    print("=" * 70)
    print("Paged-sim diagnostic: v021 main0/main1 split")
    print("=" * 70)

    # Initial state
    print(f"\nInitial pages map: {[hex(p) for p in emu.mem.pages]}")
    print(f"  slot 0 (#0000-#3FFF) -> page {emu.mem.pages[0]:#04x}")
    print(f"  slot 1 (#4000-#7FFF) -> page {emu.mem.pages[1]:#04x}")
    print(f"  slot 2 (#8000-#BFFF) -> page {emu.mem.pages[2]:#04x}")
    print(f"  slot 3 (#C000-#FFFF) -> page {emu.mem.pages[3]:#04x}")
    print(f"\n#5C00 dump (should be main0/Core.bin start = LD SP, ...):")
    print(f"  {hex32(emu.get_memory(0x5C00, 16))}")
    print(f"\n#C000 dump BEFORE Init_Core (slot 3 mapping {emu.mem.pages[3]:#04x}):")
    print(f"  {hex32(emu.get_memory(0xC000, 16))}")

    # Run Init_Core
    print(f"\n--- Calling Core.Init_Core (#{sym['Core.Init_Core']:04X}) ---")
    try:
        emu.call(sym['Core.Init_Core'], max_steps=500_000)
        print("OK: Init_Core returned normally")
    except Exception as e:
        print(f"FAIL: {e}")

    print(f"\nAfter Init_Core pages map: {[hex(p) for p in emu.mem.pages]}")
    print(f"  slot 0 -> page {emu.mem.pages[0]:#04x} (expected 0x00 TSLib)")
    print(f"  slot 1 -> page {emu.mem.pages[1]:#04x} (expected 0x05 main0)")
    print(f"  slot 2 -> page {emu.mem.pages[2]:#04x} (expected 0x06 TrackData)")
    print(f"  slot 3 -> page {emu.mem.pages[3]:#04x} (expected 0x04 main1_play)")

    # Verify main1_play.bin visible at #C000
    main1_path = PROJECT_ROOT / 'Build' / 'main1_play.bin'
    if main1_path.exists():
        m1 = main1_path.read_bytes()
        visible = emu.get_memory(0xC000, 32)
        match = bytes(visible) == m1[:32]
        print(f"\nmain1_play.bin first 32 bytes:")
        print(f"  expected: {m1[:32].hex()}")
        print(f"  at #C000: {bytes(visible).hex()}")
        print(f"  MATCH: {match}")

    # Try to call Init_Video next
    if 'Core.Init_Video' in sym:
        print(f"\n--- Calling Core.Init_Video (#{sym['Core.Init_Video']:04X}) ---")
        try:
            emu.call(sym['Core.Init_Video'], max_steps=200_000)
            print("OK: Init_Video returned normally")
        except Exception as e:
            print(f"FAIL at PC=#{emu.reg.PC:04X}: {e}")
            # Show what's at that PC
            try:
                op = emu.mem.read(emu.reg.PC)
                op2 = emu.mem.read((emu.reg.PC + 1) & 0xFFFF)
                op3 = emu.mem.read((emu.reg.PC + 2) & 0xFFFF)
                print(f"  bytes at PC: {op:02x} {op2:02x} {op3:02x}")
            except Exception:
                pass

    # Full Initialize attempt with paging trace
    print(f"\n--- Calling Core.Initialize (#{sym['Core.Initialize']:04X}) full bootstrap WITH PAGING TRACE ---")
    emu2 = ZumaFullZ80Emulator()
    emu2._paging_trace = True
    emu2._pc_watch = 0x1000  # SetPage0 function entry
    emu2._pc_ring = []
    try:
        emu2.call(emu2.sym['Core.Initialize'], max_steps=5_000_000)
        print("OK: Initialize returned normally")
        print(f"Final pages map: {[hex(p) for p in emu2.mem.pages]}")
    except Exception as e:
        print(f"FAIL at PC=#{emu2.reg.PC:04X}: {e}")
        print(f"Pages at fail: {[hex(p) for p in emu2.mem.pages]}")

if __name__ == '__main__':
    main()
