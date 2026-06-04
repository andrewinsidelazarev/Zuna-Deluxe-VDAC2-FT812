#!/usr/bin/env python3
"""Regression: gap-bonus SFX must not clobber HL before Score_Add24."""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    required = [
        "Core.Init_Core",
        "Score_Reset",
        "Core.VDC_AwardGapBonusSlot0",
        "Core.GetCurrentTargetScore",
        "Core.VDC_PlayerScore",
        "Core.VDC_GaugeScore",
        "Core.VDC_GaugeFull",
        "Core.VDC_BulletGapMinDist",
        "Core.VDC_BulletGapCount",
        "Core.VDC_StatChainCount",
    ]
    missing = [name for name in required if name not in sym]
    if missing:
        print("FAIL: missing symbols: " + ", ".join(missing))
        return 1

    emu.call(sym["Core.Init_Core"])
    emu.call(sym["Score_Reset"])

    def word(addr: int) -> int:
        return emu.mem.read(addr) | (emu.mem.read(addr + 1) << 8)

    def score24() -> int:
        addr = sym["Core.VDC_PlayerScore"]
        return emu.mem.read(addr) | (emu.mem.read(addr + 1) << 8) | (emu.mem.read(addr + 2) << 16)

    def target_score() -> int:
        emu.call(sym["Core.GetCurrentTargetScore"])
        return emu.reg.E | (emu.reg.D << 8)

    def set_gap(dist: int, count: int) -> None:
        emu.set_byte(sym["Core.VDC_BulletGapMinDist"], dist)
        emu.set_byte(sym["Core.VDC_BulletGapCount"], count)
        emu.set_byte(sym["Core.VDC_StatChainCount"], 7)

    fails: list[str] = []
    target = target_score()
    print(f"current level target from table/code: {target}")

    set_gap(0, 0)
    emu.call(sym["Core.VDC_AwardGapBonusSlot0"])
    got = (
        score24(),
        word(sym["Core.VDC_GaugeScore"]),
        emu.mem.read(sym["Core.VDC_GaugeFull"]),
        emu.mem.read(sym["Core.VDC_BulletGapCount"]),
    )
    exp = (500, 500, 1 if 500 >= target else 0, 1)
    print(f"first gap dist=0: score={got[0]} gauge={got[1]} full={got[2]} count={got[3]} expected={exp}")
    if got != exp:
        fails.append("first gap")

    set_gap(0, 1)
    emu.call(sym["Core.VDC_AwardGapBonusSlot0"])
    got = (
        score24(),
        word(sym["Core.VDC_GaugeScore"]),
        emu.mem.read(sym["Core.VDC_GaugeFull"]),
        emu.mem.read(sym["Core.VDC_BulletGapCount"]),
    )
    exp = (1500, 1500, 1 if 1500 >= target else 0, 2)
    print(f"second consecutive dist=0: score={got[0]} gauge={got[1]} full={got[2]} count={got[3]} expected={exp}")
    if got != exp:
        fails.append("second gap")

    set_gap(25, 2)
    emu.call(sym["Core.VDC_AwardGapBonusSlot0"])
    got = (score24(), word(sym["Core.VDC_GaugeScore"]), emu.mem.read(sym["Core.VDC_BulletGapCount"]))
    exp = (1500, 1500, 0)
    print(f"miss dist=25: score={got[0]} gauge={got[1]} count={got[2]} expected={exp}")
    if got != exp:
        fails.append("miss reset")

    if fails:
        print("FAIL: " + ", ".join(fails))
        return 1
    print("PASS: gap bonus score matches formula and survives SFX playback")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
