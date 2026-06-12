#!/usr/bin/env python3
"""Scan L05 chain lengths after warm gameplay frames."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import Harness  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402

ROOT = HERE.parent.parent
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-frames", type=int, default=600)
    ap.add_argument("--step", type=int, default=40)
    args = ap.parse_args()

    h = Harness(4)
    track2 = PACK / "track_l05_2_640.bin"
    data = track2.read_bytes()
    start = 0x0F * PAGE_SIZE
    h.e.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    h.e.mem.physical[start : start + len(data)] = data
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if "CurrentCodePage" in h.S:
        h.sb("CurrentCodePage", 0x04)

    print("frame len1 hsa1 len2")
    for frame in range(args.max_frames + 1):
        if frame % args.step == 0:
            print(
                f"{frame:5d} {h.gb('Core.VDC_SlotsLen'):4d} "
                f"{h.gb('Core.VDC_HSA'):4d} {h.gb('Core.VDC2_SlotsLen'):4d}",
                flush=True,
            )
        if frame < args.max_frames:
            h.sb("Core.VDC_GameState", 0)
            h.call("Core.VDC_UpdateAllChains")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
