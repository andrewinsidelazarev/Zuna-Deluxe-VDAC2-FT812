#!/usr/bin/env python3
"""Targeted Z80 test for win-state and adventure level advance."""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

VDC_STATE_INTRO = 3
VDC_STATE_WIN = 6
VDC_WIN_TICKS = 193


def set_word(sim: ZumaZ80Sim, addr: int, value: int) -> None:
    sim.set_byte(addr, value & 0xFF)
    sim.set_byte(addr + 1, (value >> 8) & 0xFF)


def require_symbols(sim: ZumaZ80Sim, names: tuple[str, ...]) -> bool:
    missing = [name for name in names if name not in sim.sym]
    if missing:
        print(f"FAIL: missing symbols: {', '.join(missing)}")
        return False
    return True


def main() -> int:
    sim = ZumaZ80Sim()
    needed = (
        "Core.VDC_CheckWinMaybe",
        "Core.VDC_UpdateWin",
        "Core.LoadGameplayAssets",
        "Core.VDC_GameState",
        "Core.VDC_GaugeFull",
        "Core.VDC_SlotsLen",
        "Core.VDC_WinTick",
        "Core.VDC_PreviewTick",
        "Core.VDC_PlayerScore",
        "Core.VDC_GameSeconds",
        "CurrentLevel",
    )
    if not require_symbols(sim, needed):
        return 1

    # VDC_UpdateWin calls LoadGameplayAssets after level advance. That path is
    # covered by loader tests; keep this test focused on win-state control flow.
    sim.set_byte(sim.sym["Core.LoadGameplayAssets"], 0xC9)  # RET

    sim.set_byte(sim.sym["CurrentLevel"], 0)
    sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    set_word(sim, sim.sym["Core.VDC_GameSeconds"], 0)
    set_word(sim, sim.sym["Core.VDC_PlayerScore"], 0)

    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    win_tick = sim.get_byte(sim.sym["Core.VDC_WinTick"])
    preview_tick = sim.get_byte(sim.sym["Core.VDC_PreviewTick"])
    score = sim.get_word(sim.sym["Core.VDC_PlayerScore"])

    if state != VDC_STATE_WIN:
        print(f"FAIL: expected win state {VDC_STATE_WIN}, got {state}")
        return 1
    if win_tick != VDC_WIN_TICKS or preview_tick != VDC_WIN_TICKS:
        print(
            "FAIL: expected win/preview ticks "
            f"{VDC_WIN_TICKS}, got {win_tick}/{preview_tick}"
        )
        return 1
    if score == 0:
        print("FAIL: expected non-zero fast-completion score bonus")
        return 1

    # First verify the exact boundary behavior with the heavy asset loader
    # stubbed out: win_tick 1 falls through into AdvanceToNextLevel.
    sim.set_byte(sim.sym["Core.VDC_WinTick"], 1)
    sim.set_byte(sim.sym["Core.VDC_PreviewTick"], 0)
    sim.call(sim.sym["Core.VDC_UpdateWin"])
    level = sim.get_byte(sim.sym["CurrentLevel"])
    if level != 1:
        print(f"FAIL: expected CurrentLevel 1 after win tick, got {level}")
        return 1

    sim.set_byte(sim.sym["CurrentLevel"], 21)
    sim.set_byte(sim.sym["Core.VDC_WinTick"], 0)
    sim.set_byte(sim.sym["Core.VDC_PreviewTick"], 0)
    sim.call(sim.sym["Core.VDC_UpdateWin"])
    level = sim.get_byte(sim.sym["CurrentLevel"])
    if level != 0:
        print(f"FAIL: expected CurrentLevel wrap to 0, got {level}")
        return 1

    # LoadGameplayAssets calls VDC_Init after uploading the selected level. The
    # real path must therefore leave gameplay in INTRO, not stuck in WIN.
    sim.call(sim.sym["Core.VDC_Init"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    gauge_full = sim.get_byte(sim.sym["Core.VDC_GaugeFull"])
    if state != VDC_STATE_INTRO or gauge_full != 0:
        print(
            "FAIL: expected VDC_Init reset to INTRO/gauge=0, "
            f"got state={state} gauge={gauge_full}"
        )
        return 1

    print("PASS: win-state enters, awards bonus, advances, wraps, and resets level state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
