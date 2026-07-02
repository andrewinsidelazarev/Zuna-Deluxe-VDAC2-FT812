#!/usr/bin/env python3
"""Regression test for main-menu mouse hover vs keyboard focus.

Static mouse hover over a button must not keep resetting MenuSelection after
keyboard navigation takes focus. Mouse regains focus by entering another button
or by LMB.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    emu.mem.pages[3] = 0x41  # UI overlay: MenuMain.asm

    def getb(name: str) -> int:
        return emu.get_byte(sym[name])

    def setb(name: str, value: int) -> None:
        emu.set_byte(sym[name], value)

    def setw(name: str, value: int) -> None:
        emu.set_word(sym[name], value)

    def call(name: str) -> None:
        emu.call(sym[name], max_steps=200_000)

    # Minimal MenuMain input state initialization.
    setb("Core.MenuSelection", 0)
    setb("Core.MenuInputMode", 0)
    setb("Core.MenuMouseHoverNow", 0xFF)
    setb("Core.MenuMouseHoverPrev", 0xFF)
    setb("Core.MenuLmbPrev", 0)
    setb("Core.MenuKbdUpPrev", 0)
    setb("Core.MenuKbdDownPrev", 0)
    setb("Core.MenuKbdFirePrev", 0)
    setb("Core.Input_KUp", 0)
    setb("Core.Input_KDown", 0)
    setb("Core.Input_KSpace", 0)
    setb("Core.Input_KEnter", 0)
    setb("Core.Input_EvUp", 0)
    setb("Core.Input_EvDown", 0)
    setb("Core.Input_EvFireKey", 0)
    emu.input.mouse_buttons = 0x03  # released for normalized Input_MouseLMB

    # Input layer: PS/2 make codes produce per-frame events even if the sampled
    # key level was already pressed. Break codes only update the level.
    setb("Core.Input_KDown", 1)
    setb("Core.Input_EvDown", 0)
    emu.call(sym["Core.Input_SetKey"], a=0x72, max_steps=20_000)  # Down make
    assert getb("Core.Input_KDown") == 1
    assert getb("Core.Input_EvDown") == 1
    setb("Core.Input_PS2Brk", 1)
    setb("Core.Input_EvDown", 0)
    emu.call(sym["Core.Input_SetKey"], a=0x72, max_steps=20_000)  # Down break
    assert getb("Core.Input_KDown") == 0
    assert getb("Core.Input_EvDown") == 0

    # Cursor is inside Adventure.
    setw("Input.Mouse.PositionX", 760)
    setw("Input.Mouse.PositionY", 130)

    # First LMB press on a button must activate immediately. Holding the same
    # press must not retrigger every frame; release edge is still accepted.
    setb("Core.MenuLmbPrev", 0)
    emu.input.mouse_buttons = 0x02  # LMB pressed
    call("Core.MenuUpdateButtons")
    assert getb("Core.MenuAdventureClick") == 1
    assert getb("Core.MenuButtonStateAdventure") == 2
    assert getb("Core.MenuLmbPrev") == 1
    call("Core.MenuUpdateButtons")
    assert getb("Core.MenuAdventureClick") == 0
    setb("Core.MenuLmbPrev", 1)
    emu.input.mouse_buttons = 0x03  # LMB released
    call("Core.MenuUpdateButtons")
    assert getb("Core.MenuAdventureClick") == 1
    setb("Core.MenuLmbPrev", 0)
    emu.input.mouse_buttons = 0x03

    call("Core.MenuUpdateButtons")
    assert getb("Core.MenuSelection") == 0
    assert getb("Core.MenuButtonStateAdventure") == 1

    # Keyboard Down must take focus even while the cursor stays over Adventure.
    setb("Core.Input_KDown", 1)
    call("Core.MenuKeyboardNav")
    assert getb("Core.MenuSelection") == 1
    assert getb("Core.MenuInputMode") == 1
    assert getb("Core.MenuButtonStateAdventure") == 0
    assert getb("Core.MenuButtonStateGauntlet") == 1

    # Next frame with the same static cursor: Adventure must not steal focus back.
    call("Core.MenuUpdateButtons")
    call("Core.MenuKeyboardNav")
    assert getb("Core.MenuSelection") == 1
    assert getb("Core.MenuInputMode") == 1
    assert getb("Core.MenuButtonStateAdventure") == 0
    assert getb("Core.MenuButtonStateGauntlet") == 1

    # Fast PS/2 tap regression: if release+press happened between menu frames,
    # the sampled key level can still be "pressed" and MenuKbdDownPrev can still
    # be 1. The per-scan make event must still advance exactly one item.
    setb("Core.MenuSelection", 1)
    setb("Core.MenuKbdDownPrev", 1)
    setb("Core.Input_KDown", 1)
    setb("Core.Input_EvDown", 1)
    call("Core.MenuKeyboardNav")
    assert getb("Core.MenuSelection") == 2
    assert getb("Core.MenuKbdDownPrev") == 1
    setb("Core.Input_EvDown", 0)
    call("Core.MenuKeyboardNav")
    assert getb("Core.MenuSelection") == 2

    # Entering a different button gives focus back to the mouse.
    setb("Core.Input_KDown", 0)
    call("Core.MenuKeyboardNav")  # update edge bookkeeping on release
    setw("Input.Mouse.PositionX", 660)
    setw("Input.Mouse.PositionY", 520)
    call("Core.MenuUpdateButtons")
    assert getb("Core.MenuInputMode") == 0
    assert getb("Core.MenuSelection") == 2
    assert getb("Core.MenuButtonStateMore") == 1

    print("PASS: main-menu mouse hover does not block keyboard focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
