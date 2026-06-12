#!/usr/bin/env python3
"""Полный игровой lose-путь на dual-уровне: PLAY → цепь1 доходит до KZ →
ABSORB → цепь1 пустеет → цепь2 ДОЛЖНА двинуться и всосаться.

В отличие от test_dual_chain_lose_absorb_z80 (ставит ABSORB-state вручную),
здесь состояние развивается ИГРОВЫМ кодом из PLAY — воспроизводит репорт
юзера «в lose цепь 2 не доходит до килл-зоны».
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import Harness  # noqa: E402

MAX_FRAMES = 1200


def big(h: Harness, name: str) -> None:
    h.e.call(h.S[name], max_steps=80_000_000)


def main() -> int:
    h = Harness(4)  # L05 dual
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 4)

    # Прогрев: цепи спавнятся игровым кодом
    for _ in range(120):
        h.sb("Core.VDC_GameState", 0)
        big(h, "Core.VDC_UpdateAllChains")

    sym = h.S
    cl_start = sym["Core.VDC_ChainLocalStart"]
    hsa_off = sym["Core.VDC_HSA"] - cl_start

    # Телепорт ГОЛОВ обеих цепей близко к их килл-зонам (имитируем проигрыш),
    # состояние остаётся PLAY — дальше пусть решает игровой код.
    tns1 = h.gw("Core.VDC_TrackNumSlots")
    tns2 = h.e.get_word(sym["Core.VDC2_ChainLocal"] + (sym["Core.VDC_TrackNumSlots"] - cl_start))
    # Сценарий юзера: ПРОИГРЫШ ВЫЗЫВАЕТ ЦЕПЬ 2 (её голова у своей KZ),
    # цепь 1 — в середине. На скрине: левая дыра пуста (цепь1 всосалась),
    # шар цепи 2 стоит у правой дыры и не тонет.
    h.sb("Core.VDC_HSA", tns1 // 2)
    h.sb("Core.VDC_HSub", 0)
    h.e.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, max(0, tns2 - 3))
    h.e.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off + 1, 0)

    def game_frame() -> None:
        # Воспроизводим MainLoop.Loop (без input): Frog_Update со swap-обвязкой
        # (MainLoop:70-85), VDC, Bullet, и ПОЛНЫЙ ZL_DrawFrame (рендер тоже
        # игровой код — может портить состояние).
        if (h.gb("Core.VDC_HasSecondChain") and h.gb("Core.VDC_SlotsLen") == 0
                and h.gb("Core.VDC2_SlotsLen") != 0):
            big(h, "Core.VDC_SwapChains")
            big(h, "Core.Frog_Update")
            big(h, "Core.VDC_SwapChains")
        else:
            big(h, "Core.Frog_Update")
        big(h, "Core.VDC_UpdateAllChains")
        big(h, "Core.Bullet_Update")
        big(h, "Core.Bullet_CheckCollisionAllChains")
        h.sw("FT.Coprocessor.BufferPtr", 0x4CB0)
        big(h, "Core.ZL_DrawFrame")

    prev = None
    stuck = 0
    for f in range(MAX_FRAMES):
        game_frame()
        st = h.gb("Core.VDC_GameState")
        l1 = h.gb("Core.VDC_SlotsLen")
        l2 = h.gb("Core.VDC2_SlotsLen")
        h2 = h.e.get_byte(sym["Core.VDC2_ChainLocal"] + hsa_off)
        kz1 = h.gb("Core.VDC_KzFrame")
        kz2 = h.gb("Core.VDC2_KzFrame")
        dlg = h.gb("Core.VDC_DialogState")
        cur = (st, l1, l2, h2, kz1, kz2, dlg)
        if cur != prev:
            print(f"f={f:4d} state={st} len1={l1:3d} len2={l2:3d} hsa2={h2:3d} "
                  f"kz1={kz1:2d} kz2={kz2:2d} dlg={dlg}", flush=True)
            prev = cur
            stuck = 0
        else:
            stuck += 1
        if l1 == 0 and l2 == 0:
            print(f"PASS: обе цепи всосались на кадре {f} (dlg={dlg})")
            return 0
        if dlg in (1, 2):
            print(f"{'PASS' if l2 == 0 else 'FAIL'}: диалог lose на кадре {f}, len2={l2}")
            return 0 if l2 == 0 else 1
        if stuck > 400:
            print(f"FAIL: застряло на 400 кадров: state={st} len1={l1} len2={l2} hsa2={h2} kz2={kz2}")
            return 1
    print(f"FAIL: за {MAX_FRAMES} кадров lose не завершился: {prev}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
