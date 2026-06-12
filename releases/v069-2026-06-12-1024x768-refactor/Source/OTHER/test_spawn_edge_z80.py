#!/usr/bin/env python3
"""test_spawn_edge_z80.py — «шары выезжают не из-за края экрана» (L11 и др.).

Гоняет первые кадры уровня на полном Z80-эмуляторе и печатает, ГДЕ рисуется
головной шар в каждом кадре (из ball-кэша #4100). Ожидание: первый видимый
шар должен войти с края экрана (x ~>= 1024-51 для правого края), а не
материализоваться в середине.
"""
import functools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from audit_level5_ft812_budget import cmd_frame  # noqa: E402
from profile_dual_chain_perf import Harness  # noqa: E402
from shadow_ft812 import disasm_dl  # noqa: E402

print = functools.partial(print, flush=True)

BALL_CACHE = 0x4100
SCREEN_W, SCREEN_H = 1024, 768
BALL_DRAW = 51


def read_cache(h, count):
    """[(tan, cell, x16, y16, flags)] — знаковые Vx/Vy из кэша."""
    out = []
    for i in range(count):
        base = BALL_CACHE + i * 7
        tan = h.e.get_byte(base)
        cell = h.e.get_byte(base + 1)
        vx = h.e.get_word(base + 2)
        vy = h.e.get_word(base + 4)
        fl = h.e.get_byte(base + 6)
        if vx >= 0x8000:
            vx -= 0x10000
        if vy >= 0x8000:
            vy -= 0x10000
        out.append((tan, cell, vx, vy, fl))
    return out


def main():
    level = int(sys.argv[1]) if len(sys.argv) > 1 else 11
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    h = Harness(level - 1)
    h.setup()
    for nm in ("Core.CurrentCodePage", "CurrentCodePage"):
        if nm in h.S:
            h.sb(nm, 0x04)
    print(f"L{level}: после загрузки SlotsLen={h.gb('Core.VDC_SlotsLen')} "
          f"HSA={h.gb('Core.VDC_HSA')} state={h.gb('Core.VDC_GameState')}")

    first_visible = None
    for f in range(frames):
        h.sb("Core.VDC_GameState", 0)
        h.call("Core.VDC_UpdateAllChains")
        if f < 4:
            # ground truth: ПОЛНЫЙ кадр → DL, вершины шаров глазами FT812
            data = cmd_frame(h)
            ops = disasm_dl(data, max_ops=4096, stop_at_display=False)
            ball_zone = False
            verts = []
            for op in ops:
                if op.name == "BITMAP_SOURCE":
                    a = op.fields.get("addr")
                    a = int(a.lstrip("#"), 16) if isinstance(a, str) else a
                    ball_zone = (a == 0x050000)
                elif op.name == "VERTEX2F" and ball_zone:
                    verts.append((op.fields["x"] / 16, op.fields["y"] / 16))
            print(f"  DL f{f}: шаров-вершин={len(verts)}: " +
                  ", ".join(f"({x:.0f},{y:.0f})" for x, y in verts[:6]))
        h.call("Core.SetCurrentTrackPage")
        h.reset_cmd()
        h.call("Core.ZL_DrawActiveChain", max_steps=6_000_000)
        n = h.gb("Core.VDC_SlotsLen")
        balls = [b for b in read_cache(h, n) if b[1] != 0xFF]
        if not balls:
            if f % 10 == 0:
                print(f"f{f:3d}: len={n} (нет шаров в кэше)")
            continue
        # головной шар = слот 0 (первая запись)
        tan, cell, vx, vy, fl = balls[0]
        hx, hy = vx / 16, vy / 16
        vis = [b for b in balls
               if -BALL_DRAW < b[2] / 16 < SCREEN_W and -BALL_DRAW < b[3] / 16 < SCREEN_H]
        mark = ""
        if vis and first_visible is None:
            first_visible = (f, vis[0][2] / 16, vis[0][3] / 16, len(vis))
            mark = "  <-- ПЕРВЫЙ ВИДИМЫЙ"
        if f % 5 == 0 or mark:
            print(f"f{f:3d}: len={n:3d} head=({hx:7.1f},{hy:7.1f}) fl={fl:02X} "
                  f"видимых={len(vis)}{mark}")

    if first_visible:
        f, x, y, k = first_visible
        print(f"\nПервый видимый шар: кадр {f}, draw-XY=({x:.1f},{y:.1f})")
        on_edge = (x >= SCREEN_W - BALL_DRAW - 8 or x <= 8 - BALL_DRAW
                   or y >= SCREEN_H - BALL_DRAW - 8 or y <= 8 - BALL_DRAW)
        print("ВЕРДИКТ:", "из-за края — OK" if on_edge
              else f"ПОЯВЛЯЕТСЯ В СЕРЕДИНЕ ЭКРАНА — ({x:.0f},{y:.0f}) — БАГ")
    else:
        print("\nЗа", frames, "кадров видимых шаров не появилось")


if __name__ == "__main__":
    main()
