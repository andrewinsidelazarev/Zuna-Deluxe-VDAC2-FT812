#!/usr/bin/env python3
"""Export an EVE playback bundle from the exact L05 full-stack warm state."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from audit_level5_ft812_budget import chain_budget_frame, cmd_frame  # noqa: E402
from profile_dual_chain_perf import Harness  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--warm-frames", type=int, default=160)
    ap.add_argument(
        "--out",
        default=str(ROOT / "Diagnostics" / "FT812Bundles" / "l05_warm160_dual_exact_ramg"),
    )
    ap.add_argument("--mode", choices=("budget", "real"), default="budget")
    args = ap.parse_args()

    h = Harness(4)
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if "CurrentCodePage" in h.S:
        h.sb("CurrentCodePage", 0x04)
    h.run_play_frames(args.warm_frames)
    h.e.reg.SP = 0x40F2
    h.e.mem.pages[0] = 0x00
    h.e.mem.pages[1] = 0x05
    h.e.mem.pages[3] = 0x04
    h.call("Core.SetCurrentTrackPage")
    cmd = cmd_frame(h) if args.mode == "real" else chain_budget_frame(h)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "ram_g.bin").write_bytes(bytes(h.e.ft.ram_g))
    frame_name = f"cmd_frame_{args.warm_frames:04d}.bin"
    (out / frame_name).write_bytes(cmd)
    (out / "manifest.json").write_text(
        json.dumps(
            {
                "project": str(ROOT),
                "source": "full-stack Harness(4) after LoadGameplayAssets + warm frames",
                "mode": args.mode,
                "ram_g_file": "ram_g.bin",
                "ram_g_size": len(h.e.ft.ram_g),
                "frames": [
                    {
                        "frame": args.warm_frames,
                        "file": frame_name,
                        "cmd_bytes": len(cmd),
                        "level": 5,
                        "warm_frames": args.warm_frames,
                        "slots_len_1": h.gb("Core.VDC_SlotsLen"),
                        "slots_len_2": h.gb("Core.VDC2_SlotsLen"),
                        "hsa_1": h.gb("Core.VDC_HSA"),
                    }
                ],
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"wrote {out}")
    print(
        f"L05 warm={args.warm_frames} "
        f"slots=({h.gb('Core.VDC_SlotsLen')},{h.gb('Core.VDC2_SlotsLen')}) "
        f"cmd={len(cmd)} ram_g={len(h.e.ft.ram_g)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
