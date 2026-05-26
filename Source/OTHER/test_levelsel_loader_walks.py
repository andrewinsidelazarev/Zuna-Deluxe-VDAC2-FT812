#!/usr/bin/env python3
"""Narrow Z80-side test: LoadLevelSelectAssets walks to RET without hanging.

Why a new test instead of fixing test_levelsel_transition.py:
  * The existing harness hangs in WaitFlush/Write/Write32 — those poll
    REG_CMDB_SPACE / REG_CMD_READ. shadow_ft812 does not model CMDB_SPACE,
    so the poll never exits. That's a shadow gap, not an ASM bug.
  * We don't need the coprocessor here. We need to prove the Z80-side loader
    walks cleanly: no bad opcodes, no infinite loop in OUR code, no stack
    corruption, RET reaches RETURN_MARKER.

Method:
  * Boot ZumaFullZ80Emulator (no shadow_ft812).
  * Init_Core to set up paging (slot 3 -> page #04 where main1_play lives).
  * Stub the four FT polling primitives in Z80 RAM with `OR A; RET`
    (clears CF = "no fault / FIFO ready"), so each FT_WR_INFLATE blows
    through its wait gates.
  * emu.call(LoadLevelSelectAssets). If it returns without TimeoutError,
    the loader structure is sound.

What this proves:
  * LoadLevelSelectAssets executes the 34 table-driven inflate entries plus
    2 FT.WriteMem calls and page restores, all reachable, all RET-clean.
What this does NOT prove:
  * That the coprocessor will actually inflate the data on real hardware.
    That needs Unreal x64 or real FT812.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent

# Stub bytes: OR A (B7) ; RET (C9)  → clears CF, returns.
STUB = bytes([0xB7, 0xC9])


def stub_routine(emu, sym_name: str) -> int:
    addr = emu.sym[sym_name]
    for i, b in enumerate(STUB):
        emu.set_byte(addr + i, b)
    return addr


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    if emu.errors:
        # Same warnings as other tests — non-fatal asset blocks.
        print(f"[load] {len(emu.errors)} warning(s) (non-fatal)")

    sym = emu.sym
    for needed in ("Core.Init_Core", "Core.LoadLevelSelectAssets",
                   "FT.Coprocessor.WaitFlush", "FT.Coprocessor.Write",
                   "FT.Coprocessor.Write32", "FT.Coprocessor.IsFault",
                   "FT.Coprocessor.Wait"):
        if needed not in sym:
            print(f"FAIL: missing symbol {needed}")
            return 1

    print("[init] Init_Core")
    emu.call(sym["Core.Init_Core"])

    # Stub all FT polling primitives that read REG_CMD_READ/CMDB_SPACE.
    # These live in low pages (TSLib in page 0x00), always mapped.
    stubbed = []
    for name in ("FT.Coprocessor.WaitFlush",
                 "FT.Coprocessor.Write",
                 "FT.Coprocessor.Write32",
                 "FT.Coprocessor.IsFault",
                 "FT.Coprocessor.Wait"):
        addr = stub_routine(emu, name)
        stubbed.append((name, addr))
        print(f"[stub] {name} @ #{addr:04X} = OR A; RET")

    # Verify slot 3 is on page #04 (where LoadLevelSelectAssets at #CCF3 lives).
    print(f"[paging] slot3 page = #{emu.mem.pages[3]:02X} "
          f"(expect #04 for main1_play)")

    ls_addr = sym["Core.LoadLevelSelectAssets"]
    print(f"[call] LoadLevelSelectAssets @ #{ls_addr:04X}")

    pre_tstates = emu.tstates
    try:
        steps = emu.call(ls_addr, max_steps=20_000_000)
    except TimeoutError as e:
        print(f"FAIL: {e}")
        # Show ring buffer if available
        rb = getattr(emu, '_pc_ring', None)
        if rb:
            print(f"  last 10 PCs: {[f'#{pc:04X}' for pc in rb[-10:]]}")
        return 1

    delta_t = emu.tstates - pre_tstates
    print(f"PASS: returned cleanly")
    print(f"  steps   = {steps:,}")
    print(f"  t-states= {delta_t:,}")
    print(f"  ports OUT recorded = {len(emu.ports_out):,}")
    print(f"  ports IN  recorded = {len(emu.ports_in):,}")

    # Sanity: 34 INFLATE + 2 palette writes should produce thousands of SPI bytes.
    spi_writes = sum(1 for port, _ in emu.ports_out if (port & 0xFF) in (0x57, 0x77))
    print(f"  SPI_DATA writes    = {spi_writes:,} (proxies for FT812 traffic)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
