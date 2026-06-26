"""Z80 regression: level-select preview stream writes to the selected RAM_G buffer.

The loader overlay maps slot0 to the ZiFi driver while streaming from SD.  Preview
destination variables live in slot0, so the resident trampoline must copy them to
Core.BgRamL/H before entering the overlay.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Source" / "OTHER"))

from full_stack_trace import FullStackTrace  # noqa: E402


LEVEL_INDEX = 17  # L18, non-trivial tunnel art.
DEST_RAMG = 0x0D4000


def main() -> int:
    fs = FullStackTrace(ROOT, shadow_ft812=True)
    sym = fs.sym

    fs.call("Core.Init_Core", 1_000_000)
    fs.emu.mem.write(sym["Core.CurrentLevel"], LEVEL_INDEX)
    fs.emu.mem.write(sym["LevelSelectPreviewLoadRamL"], DEST_RAMG & 0xFF)
    fs.emu.mem.write(sym["LevelSelectPreviewLoadRamL"] + 1, (DEST_RAMG >> 8) & 0xFF)
    fs.emu.mem.write(sym["LevelSelectPreviewLoadRamH"], (DEST_RAMG >> 16) & 0xFF)

    fs.call("Core.LoadLevelSelectPreviewAssets", 5_000_000)
    if not (fs.emu.reg.F & 1):
        print("FAIL: LoadLevelSelectPreviewAssets returned CF=0")
        rb = sym.get("Core.RawPak_ReadbackBuf")
        if rb is not None:
            got = bytes(fs.emu.mem.read(rb + i) for i in range(16))
            print(f"  readback={got.hex(' ')}")
        staged = bytes(fs.emu.mem.physical[0x07 * 0x4000 : 0x07 * 0x4000 + 16])
        print(f"  staged07={staged.hex(' ')}")
        print(f"  ramg={bytes(fs.emu.ft.ram_g[DEST_RAMG:DEST_RAMG+16]).hex(' ')}")
        for event in list(fs.events)[-16:]:
            print("  " + event)
        return 1

    raw_reads = sum(1 for call in fs.zifi_calls if "RawPak_ReadOneLogicalIX" in call)
    if raw_reads != 256:
        print(f"FAIL: expected 256 preview sectors, got {raw_reads}")
        return 1

    pak = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()
    toc = pak[512 + LEVEL_INDEX * 20 : 512 + (LEVEL_INDEX + 1) * 20]
    vals = struct.unpack("<10H", toc)
    preview_off, preview_size = vals[8], vals[9]
    expected = pak[preview_off * 512 : (preview_off + preview_size) * 512]
    got = bytes(fs.emu.ft.ram_g[DEST_RAMG : DEST_RAMG + len(expected)])
    if got != expected:
        print("FAIL: RAM_G preview buffer does not match ZUMALVL.PAK preview section")
        print(f"  first16 got={got[:16].hex(' ')} expected={expected[:16].hex(' ')}")
        return 1

    write_events = [event for event in fs.events if "WRITEMEM" in event]
    if not write_events or "dest=#0D4000" not in write_events[0]:
        print("FAIL: first preview WriteMem did not target #0D4000")
        for event in write_events[:4]:
            print("  " + event)
        return 1

    print("PASS: level-select preview stream writes selected RAM_G buffer byte-for-byte")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
