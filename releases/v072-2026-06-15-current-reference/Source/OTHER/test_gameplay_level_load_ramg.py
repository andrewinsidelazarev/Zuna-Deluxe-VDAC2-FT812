#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from full_stack_trace import FullStackTrace  # noqa: E402


BG_RAMG = 0x010000
BG_SIZE = 400 * 300
BG_PAL_RAMG = 0x02D500
BG_PAL_SIZE = 512


def expected_bg(level_index: int) -> bytes:
    if level_index == 0:
        base = ROOT / "Graphics" / "levels" / "Converted"
        pattern = "bg_paletted_p%02d.bin"
    else:
        base = ROOT / "Graphics" / "levels" / "Converted" / "pack"
        pattern = f"bg_l{level_index + 1:02d}_paletted_p%02d.bin"
    return b"".join((base / (pattern % i)).read_bytes() for i in range(8))


def expected_pal(level_index: int) -> bytes:
    if level_index == 0:
        return (ROOT / "Graphics" / "levels" / "Converted" / "bg_palette_argb4.bin").read_bytes()
    return (ROOT / "Graphics" / "levels" / "Converted" / "pack" / f"bg_l{level_index + 1:02d}_palette_argb4.bin").read_bytes()


def first_diff(a: bytes, b: bytes) -> int | None:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    if len(a) != len(b):
        return min(len(a), len(b))
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--level-index", type=int, default=0, help="0-based CurrentLevel")
    ap.add_argument("--full", action="store_true", help="run full LoadGameplayAssets instead of just pack loader")
    args = ap.parse_args()

    fs = FullStackTrace(ROOT, shadow_ft812=True)
    fs.call("Core.Init_Core", 1_000_000)
    fs.emu.set_byte(fs.sym["Core.CurrentLevel"], args.level_index)
    if args.full:
        fs.call("Core.LoadGameplayAssets", 10_000_000)
    else:
        fs.call("Core.LoadGameplayLevelSpecificFromPack", 3_000_000)

    actual_bg = bytes(fs.emu.ft.ram_g[BG_RAMG : BG_RAMG + BG_SIZE])
    actual_pal = bytes(fs.emu.ft.ram_g[BG_PAL_RAMG : BG_PAL_RAMG + BG_PAL_SIZE])
    want_bg = expected_bg(args.level_index)[:BG_SIZE]
    want_pal = expected_pal(args.level_index)

    ok = True
    diff = first_diff(actual_bg, want_bg)
    if diff is None:
        print(f"OK bg RAM_G matches L{args.level_index + 1:02d} ({len(want_bg)} bytes)")
    else:
        print(f"FAIL bg first diff at #{diff:05X}: got #{actual_bg[diff]:02X}, want #{want_bg[diff]:02X}")
        ok = False

    diff = first_diff(actual_pal, want_pal)
    if diff is None:
        print(f"OK bg palette RAM_G matches L{args.level_index + 1:02d} ({len(want_pal)} bytes)")
    else:
        print(f"FAIL palette first diff at #{diff:03X}: got #{actual_pal[diff]:02X}, want #{want_pal[diff]:02X}")
        ok = False

    print(f"ZiFi_GpDbgStep=#{fs.emu.mem.read(fs.sym['Core.ZiFi_GpDbgStep']):02X}")
    print(f"CurrentLevel=#{fs.emu.mem.read(fs.sym['Core.CurrentLevel']):02X}")
    print(f"Carry={'set' if fs.emu.reg.F & 0x01 else 'clear'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
