#!/usr/bin/env python3
"""Z80 harness for the 24-bit cumulative score + 50000 extra-life mechanic.

Drives the real Score_Reset / Score_Add24 (Core, resident) in the emulator and
checks VDC_PlayerScore (3-byte LE) carry propagation past 65535 and the
+1-life-per-50000 award (including a single add that crosses two thresholds).
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    for n in ("Core.Init_Core", "Score_Reset", "Score_Add24",
              "Core.VDC_PlayerScore", "Core.NextLifeScore", "Core.VDC_Lives"):
        if n not in sym:
            print(f"FAIL: missing symbol {n}")
            return 1

    emu.call(sym["Core.Init_Core"])

    def score():
        a = sym["Core.VDC_PlayerScore"]
        return emu.mem.read(a) | (emu.mem.read(a + 1) << 8) | (emu.mem.read(a + 2) << 16)

    def threshold():
        a = sym["Core.NextLifeScore"]
        return emu.mem.read(a) | (emu.mem.read(a + 1) << 8) | (emu.mem.read(a + 2) << 16)

    def lives():
        return emu.mem.read(sym["Core.VDC_Lives"])

    def add(delta):
        emu.call(sym["Score_Add24"], h=(delta >> 8) & 0xFF, l=delta & 0xFF)

    # New run reset must restore lives as well as score/extra-life threshold.
    emu.set_byte(sym["Core.VDC_Lives"], 1)
    emu.call(sym["Score_Reset"])

    fails = []

    def check(label, exp_score, exp_lives, exp_thr):
        got = (score(), lives(), threshold())
        ok = got == (exp_score, exp_lives, exp_thr)
        print(f"  [{'ok' if ok else 'XX'}] {label}: score={got[0]} lives={got[1]} next={got[2]} "
              f"(expect score={exp_score} lives={exp_lives} next={exp_thr})")
        if not ok:
            fails.append(label)

    check("after reset", 0, 3, 50000)

    add(30000)
    check("+30000 (no life)", 30000, 3, 50000)

    add(30000)  # 60000 -> crosses 50000 (also proves >16-bit add: 60000 < 65536 still)
    check("+30000 -> 60000 (1 life)", 60000, 4, 100000)

    add(50000)  # 110000 -> exceeds 65535 (24-bit), crosses 100000
    check("+50000 -> 110000 (carry past 65535, 1 life)", 110000, 5, 150000)

    # single add crossing TWO thresholds: from 110000 add 65535 -> 175535,
    # crosses 150000 and 200000? 175535 < 200000 -> only 150000 -> 1 life.
    add(65535)
    check("+65535 -> 175535 (1 life)", 175535, 6, 200000)

    # craft a double-threshold crossing: reset, set score near, add big.
    emu.set_byte(sym["Core.VDC_Lives"], 1)
    emu.call(sym["Score_Reset"])
    add(40000)            # 40000, next=50000
    add(65000)            # 105000 -> crosses 50000 AND 100000 -> +2 lives, next=150000
    check("40000+65000 -> 105000 (two thresholds, +2 lives)", 105000, 5, 150000)

    if fails:
        print(f"FAIL: {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("PASS: 24-bit score carry + 50000 extra-life mechanic correct")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
