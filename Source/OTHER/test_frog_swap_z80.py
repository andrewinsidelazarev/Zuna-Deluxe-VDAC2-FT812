#!/usr/bin/env python3
"""Регрессия свопа шаров лягушки.

Проверяет:
  * правый Alt/AltGr определяется только как PS/2 E0 11;
  * AltGr и ПКМ дают один своп на фронт нажатия;
  * своп блокируется вне PLAY, в диалоге и во время recoil;
  * SFX для смены шара соответствует таблице звуков: SND_POP.
"""

from __future__ import annotations

import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


NEEDED = (
    "Core.Input_SetKey",
    "Core.Input_KAltGr",
    "Core.Input_PS2Brk",
    "Core.Frog_HandleSwap",
    "Core.Frog_SwapBalls",
    "Core.Frog_BallColor",
    "Core.Frog_NextBallColor",
    "Core.Frog_SwapPrev",
    "Core.VDC_GameState",
    "Core.VDC_DialogState",
    "Core.Frog_IsFire",
    "Core.GS_SfxRequestId",
    "Core.SND_POP",
)


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    missing = [name for name in NEEDED if name not in emu.sym]
    if missing:
        return fail("missing symbols: " + ", ".join(missing))

    sym = emu.sym
    sfx_pop = sym["Core.SND_POP"] & 0xFF

    def getb(name: str) -> int:
        return emu.get_byte(sym[name])

    def setb(name: str, value: int) -> None:
        emu.set_byte(sym[name], value)

    def call(name: str) -> None:
        emu.call(sym[name], max_steps=500_000)

    def colors() -> tuple[int, int]:
        return getb("Core.Frog_BallColor"), getb("Core.Frog_NextBallColor")

    def set_colors(ball: int, next_ball: int) -> None:
        setb("Core.Frog_BallColor", ball)
        setb("Core.Frog_NextBallColor", next_ball)

    def reset_play_state() -> None:
        setb("Core.VDC_GameState", 0)
        setb("Core.VDC_DialogState", 0)
        setb("Core.Frog_IsFire", 0)
        setb("Core.Frog_SwapPrev", 0)
        setb("Core.Input_KAltGr", 0)
        setb("Core.Input_PS2Brk", 0)
        setb("Core.GS_SfxRequestId", 0xEE)
        emu.input.mouse_buttons = 0x03  # ЛКМ/ПКМ отпущены

    def expect_colors(expected: tuple[int, int], context: str) -> int:
        got = colors()
        if got != expected:
            return fail(f"{context}: colors {got}, expected {expected}")
        return 0

    # Левый Alt (#11 без E0) не должен менять Input_KAltGr.
    reset_play_state()
    emu.call(sym["Core.Input_SetKey"], a=0x11, max_steps=50_000)
    if getb("Core.Input_KAltGr") != 0:
        return fail("left Alt was accepted as AltGr")

    # Нажатие AltGr = E0 11 -> нажато.
    setb("Core.Input_PS2Brk", 0x02)
    emu.call(sym["Core.Input_SetKey"], a=0x11, max_steps=50_000)
    if getb("Core.Input_KAltGr") != 1 or getb("Core.Input_PS2Brk") != 0:
        return fail("AltGr make did not set Input_KAltGr and clear PS/2 flags")

    # Отпускание AltGr = E0 F0 11 -> отпущено.
    setb("Core.Input_PS2Brk", 0x03)
    emu.call(sym["Core.Input_SetKey"], a=0x11, max_steps=50_000)
    if getb("Core.Input_KAltGr") != 0 or getb("Core.Input_PS2Brk") != 0:
        return fail("AltGr break did not clear Input_KAltGr and PS/2 flags")

    # Прямой своп должен поменять два цвета и выставить SND_POP.
    reset_play_state()
    set_colors(2, 5)
    call("Core.Frog_SwapBalls")
    if expect_colors((5, 2), "direct Frog_SwapBalls"):
        return 1
    if getb("Core.GS_SfxRequestId") != sfx_pop:
        return fail("direct Frog_SwapBalls did not request SND_POP")

    # AltGr: один своп на фронт, удержание не повторяет.
    reset_play_state()
    set_colors(1, 4)
    setb("Core.Input_KAltGr", 1)
    call("Core.Frog_HandleSwap")
    if expect_colors((4, 1), "AltGr press"):
        return 1
    if getb("Core.GS_SfxRequestId") != sfx_pop:
        return fail("AltGr swap did not request SND_POP")
    call("Core.Frog_HandleSwap")
    if expect_colors((4, 1), "AltGr hold"):
        return 1
    setb("Core.Input_KAltGr", 0)
    call("Core.Frog_HandleSwap")
    setb("Core.Input_KAltGr", 1)
    call("Core.Frog_HandleSwap")
    if expect_colors((1, 4), "AltGr second press"):
        return 1

    # ПКМ: тот же антидребезг по фронту. 0x01 = ЛКМ отпущена, ПКМ нажата.
    reset_play_state()
    set_colors(2, 3)
    emu.input.mouse_buttons = 0x01
    call("Core.Frog_HandleSwap")
    if expect_colors((3, 2), "RMB press"):
        return 1
    call("Core.Frog_HandleSwap")
    if expect_colors((3, 2), "RMB hold"):
        return 1
    emu.input.mouse_buttons = 0x03
    call("Core.Frog_HandleSwap")
    emu.input.mouse_buttons = 0x01
    call("Core.Frog_HandleSwap")
    if expect_colors((2, 3), "RMB second press"):
        return 1

    # Блокировки: только PLAY, без диалога и без активной отдачи.
    for field, value, context in (
        ("Core.VDC_GameState", 1, "non-play"),
        ("Core.VDC_DialogState", 1, "dialog"),
        ("Core.Frog_IsFire", 1, "recoil"),
    ):
        reset_play_state()
        set_colors(0, 4)
        setb(field, value)
        setb("Core.Input_KAltGr", 1)
        call("Core.Frog_HandleSwap")
        if expect_colors((0, 4), context):
            return 1
        if getb("Core.GS_SfxRequestId") != 0xEE:
            return fail(f"{context}: blocked swap still requested SFX")

    print("PASS: Frog swap handles AltGr/RMB edge, block states, and SND_POP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
