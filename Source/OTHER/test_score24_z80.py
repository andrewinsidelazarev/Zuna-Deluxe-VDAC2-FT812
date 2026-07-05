#!/usr/bin/env python3
"""Z80 harness для 24-bit cumulative score + 50000 extra-life.

Гоняет реальные Score_Reset / Score_Add24 (Core, resident) в эмуляторе и
проверяет VDC_PlayerScore (3-byte LE), перенос за 65535 и cap жизней:
+1 жизнь за 50000 очков только если VDC_Lives < 3.
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

    # Новый run должен восстановить lives, score и extra-life threshold.
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

    add(30000)  # 60000 -> crosses 50000, но lives уже 3: cap, threshold consumed.
    check("+30000 -> 60000 (cap at 3)", 60000, 3, 100000)

    emu.set_byte(sym["Core.VDC_Lives"], 2)
    add(50000)  # 110000 -> exceeds 65535 (24-bit), crosses 100000, 2->3.
    check("+50000 -> 110000 (carry past 65535, 2->3 lives)", 110000, 3, 150000)

    # Single add crossing one threshold at cap: threshold advances, lives stays 3.
    add(65535)
    check("+65535 -> 175535 (cap at 3)", 175535, 3, 200000)

    # Single add crossing TWO thresholds: lives 1 -> 3, not above 3.
    emu.set_byte(sym["Core.VDC_Lives"], 1)
    emu.call(sym["Score_Reset"])
    emu.set_byte(sym["Core.VDC_Lives"], 1)
    add(40000)            # 40000, next=50000
    add(65000)            # 105000 -> crosses 50000 AND 100000 -> +2 lives, next=150000
    check("40000+65000 -> 105000 (two thresholds, cap at 3)", 105000, 3, 150000)

    if fails:
        print(f"FAIL: {len(fails)} case(s): {', '.join(fails)}")
        return 1
    print("PASS: 24-bit score carry + 50000 extra-life cap correct")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
