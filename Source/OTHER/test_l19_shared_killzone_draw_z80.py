#!/usr/bin/env python3
"""L19 has two chains but one visible kill-zone skull.

If chain2 is closer to lose than chain1, DrawKillzoneDual must draw exactly one
shared L19 skull using the more open frame. Other dual levels still draw two
separate kill-zones.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


def drawn_cells(level_idx0: int, kz1: int, kz2: int) -> list[int]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    emu.set_byte(sym["Core.CurrentLevel"], level_idx0)
    emu.set_byte(sym["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(sym["Core.VDC_GameState"], 0)  # PLAY: per-chain KzFrame is active
    emu.set_byte(sym["Core.VDC_KzFrame"], kz1)
    emu.set_byte(sym["Core.VDC2_KzFrame"], kz2)

    cells: list[int] = []
    base_step = emu.step
    cell_pc = sym["FT.Coprocessor.Cell"]

    def step() -> int:
        if emu.reg.PC == cell_pc:
            cells.append(emu.reg.A & 0xFF)
        return base_step()

    emu.step = step
    emu.call(sym["DrawKillzoneDual"], max_steps=2_000_000)
    return cells


def check(name: str, actual: list[int], expected: list[int]) -> bool:
    ok = actual == expected
    print(f"{'PASS' if ok else 'FAIL'}: {name}: cells={actual}, expected={expected}")
    return ok


def main() -> int:
    checks = [
        check("L19 shared skull uses chain2 open frame once", drawn_cells(18, 1, 9), [0, 9]),
        check("L19 shared skull keeps chain1 open frame once", drawn_cells(18, 9, 1), [0, 9]),
        check("L05 still draws two kill-zones", drawn_cells(4, 1, 9), [0, 1, 0, 9]),
        check("L12 still draws two kill-zones", drawn_cells(11, 1, 9), [0, 1, 0, 9]),
        check("L19 clamps corrupt shared frame to last atlas cell", drawn_cells(18, 1, 255), [0, 11]),
        check("L05 clamps corrupt chain1 frame", drawn_cells(4, 99, 1), [0, 11, 0, 1]),
        check("L12 clamps corrupt chain2 frame", drawn_cells(11, 1, 12), [0, 1, 0, 11]),
    ]
    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
