#!/usr/bin/env python3
"""Трасса CMD-потока кадра: какая матрица действует на спрайт кнопки MENU.

Строит реальный кадр (Core.ZL_DrawFrame) на L01 с VDC_HudMenuState=1 (hover),
парсит Z80 CMD-буфер (#4CB0..BufferPtr) и находит:
  - слово BITMAP_SIZE 126×42 (уникальная сигнатура окна MENU-спрайта);
  - последний матричный оп перед ним (CMD_LOADIDENTITY/CMD_SCALE/CMD_SETMATRIX
    или прямые BITMAP_TRANSFORM_A..F);
  - следующий за ним VERTEX2F (фактическая позиция спрайта).

PASS-критерий: на момент MENU действуют ЗАПЕЧЁННЫЕ BITMAP_TRANSFORM A=E=160
(=ровно 1/1.6; CMD_SCALE запрещён — усечённая инверсия даёт ×1.6101), и
vertex = (13798, 77) — дробная позиция точно на запечённой в рамке кнопке
(539×1.6×16 = 13798.4; 3×1.6×16 = 76.8).
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import Harness, CMD  # noqa: E402  (CMD=0x4CB0)

MENU_SIZE_WORD = 0x08000000 | (126 << 9) | 42
SCALE_16 = 0x0001999A

CO_NAMES = {
    0xFFFFFF26: ("LOADIDENTITY", 0),
    0xFFFFFF28: ("SCALE", 2),
    0xFFFFFF29: ("ROTATE", 1),
    0xFFFFFF27: ("TRANSLATE", 2),
    0xFFFFFF2A: ("SETMATRIX", 0),
}


def words(buf: bytes):
    for i in range(0, len(buf) - 3, 4):
        yield i, struct.unpack_from("<I", buf, i)[0]


def main() -> int:
    h = Harness(0)  # L01 spiral
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    h.run_play_frames(200)

    h.sb("Core.VDC_GameState", 0)
    h.sb("Core.VDC_HudMenuState", 1)  # hover → DrawHudMenu рисует спрайт
    h.reset_cmd()
    h.call("Core.ZL_DrawFrame")
    size = (h.gw("FT.Coprocessor.BufferPtr") - CMD) & 0xFFFF
    buf = bytes(h.e.get_memory(CMD, size))
    print(f"frame CMD bytes: {size}")

    # позиция сигнатуры MENU
    menu_off = None
    for off, w in words(buf):
        if w == MENU_SIZE_WORD:
            menu_off = off
    if menu_off is None:
        print("FAIL: BITMAP_SIZE 126x42 (MENU) не найден в кадре")
        return 1

    # скан матричных оп до MENU; параметры coproc-команд учитываем по счётчику
    last_ops: list[tuple[int, str, list[int]]] = []
    skip = 0
    pending: tuple[int, str, int, list[int]] | None = None
    for off, w in words(buf[:menu_off]):
        if pending is not None:
            o, name, need, args = pending
            args.append(w)
            if len(args) == need:
                last_ops.append((o, name, args))
                pending = None
            continue
        if w in CO_NAMES:
            name, nargs = CO_NAMES[w]
            if nargs == 0:
                last_ops.append((off, name, []))
            else:
                pending = (off, name, nargs, [])
        elif (w >> 24) in (0x15, 0x16, 0x17, 0x18, 0x19, 0x1A):
            last_ops.append((off, f"TRANSFORM_{chr(ord('A') + (w >> 24) - 0x15)}", [w & 0xFFFFFF]))

    tail = last_ops[-8:]
    print("последние матричные оп до MENU:")
    for off, name, args in tail:
        print(f"  @{off:5d} {name} {[hex(a) for a in args]}")

    # vertex после MENU-сигнатуры
    vertex = None
    for off, w in words(buf[menu_off:menu_off + 64]):
        if (w >> 30) == 1:  # VERTEX2F
            x = (w >> 15) & 0x7FFF
            y = w & 0x7FFF
            vertex = (x, y)
            break
    print(f"MENU vertex: {vertex} (ожидается (13798, 77))")

    # вердикт: ищем модель матрицы на момент MENU
    cur: list[tuple[str, list[int]]] = []
    applied: list[tuple[str, list[int]]] = []
    for _off, name, args in last_ops:
        if name == "LOADIDENTITY":
            cur = []
        elif name == "SETMATRIX":
            applied = list(cur)
        elif name.startswith("TRANSFORM_"):
            applied.append((name, args))
        else:
            cur.append((name, args))
    print(f"действующая матрица при MENU: {applied}")

    ok_a = any(n == "TRANSFORM_A" and a == [160] for n, a in applied)
    ok_e = any(n == "TRANSFORM_E" and a == [160] for n, a in applied)
    bad_scale = any(n == "SCALE" for n, a in applied)
    ok_vertex = vertex == (13798, 77)
    if ok_a and ok_e and not bad_scale and ok_vertex:
        print("PASS: MENU рисуется запечённой 160/256-матрицей в (862.4, 4.8) — точно на запечённой кнопке")
        return 0
    print(f"FAIL: transform_a={ok_a} transform_e={ok_e} cmd_scale_present={bad_scale} vertex_ok={ok_vertex}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
