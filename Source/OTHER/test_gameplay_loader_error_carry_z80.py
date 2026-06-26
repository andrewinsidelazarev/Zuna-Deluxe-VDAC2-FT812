#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from full_stack_trace import FullStackTrace  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402


def patch_retry_to_fail(fs: FullStackTrace) -> None:
    """Force gameplay section reads to fail after TOC has already loaded."""
    addr = fs.sym["Core.RawPak_ReadOneLogicalIX_Retry"]
    loader_page = fs.sym.get("Core.LOADER_OVL_PAGE", 0x40) & 0xFF
    phys = loader_page * PAGE_SIZE + (addr & 0x3FFF)
    fs.emu.mem.physical[phys : phys + 2] = b"\x37\xc9"  # SCF; RET


def main() -> int:
    fs = FullStackTrace(ROOT, shadow_ft812=True)
    fs.call("Core.Init_Core", 1_000_000)
    fs.emu.mem.write(fs.sym["Core.CurrentLevel"], 18)  # L19, first bg sector will fail.
    patch_retry_to_fail(fs)

    fs.call("Core.LoadGameplayLevelSpecificFromPack", 20_000_000)
    if fs.emu.reg.F & 0x01:
        print("FAIL: gameplay loader returned CF=1 after forced bg SD-read error")
        return 1

    page3 = fs.emu.mem.pages[3]
    if page3 != 0x04:
        print(f"FAIL: gameplay loader did not restore slot3 to #04, got #{page3:02X}")
        return 1

    print("PASS: gameplay loader SD-read failure returns CF=0, not false success")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
