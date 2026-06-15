#!/usr/bin/env python3
"""Targeted Z80 test for win-state and adventure level advance."""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
ROOT = HERE.parent.parent

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

VDC_STATE_INTRO = 3
VDC_STATE_WIN = 6
VDC_WIN_TICKS = 193


def set_word(sim: ZumaZ80Sim, addr: int, value: int) -> None:
    sim.set_byte(addr, value & 0xFF)
    sim.set_byte(addr + 1, (value >> 8) & 0xFF)


def install_store_a_ret(sim: ZumaZ80Sim, addr: int, target: int, value: int) -> None:
    sim.set_byte(addr, 0x3E)  # LD A,n
    sim.set_byte(addr + 1, value & 0xFF)
    sim.set_byte(addr + 2, 0x32)  # LD (nn),A
    sim.set_byte(addr + 3, target & 0xFF)
    sim.set_byte(addr + 4, (target >> 8) & 0xFF)
    sim.set_byte(addr + 5, 0xC9)  # RET


def require_symbols(sim: ZumaZ80Sim, names: tuple[str, ...]) -> bool:
    missing = [name for name in names if name not in sim.sym]
    if missing:
        print(f"FAIL: missing symbols: {', '.join(missing)}")
        return False
    return True


def check_win_visual_source() -> bool:
    src = (ROOT / "Source" / "ASM" / "MainLoop.asm").read_text(encoding="utf-8")
    start = src.index("DrawWinStateVisual:")
    end = src.index("ZL_AfterChains:", start)
    body = src[start:end]
    if "DrawPreviewSparklesAll" in body:
        print("FAIL: WIN visual still calls preview sparkles")
        return False
    # WIN визуал = пул частиц-взрывов (бегущий эмиттер в VDC_UpdateWin), рисуется здесь.
    if "VDC_WinPrtcl" not in body:
        print("FAIL: WIN visual must draw the explosion particle pool")
        return False
    # head-сэмпл головы снимается в VDC_UpdateAllChains (до очистки цепочки).
    vdc = (ROOT / "Source" / "ASM" / "VDC.asm").read_text(encoding="utf-8")
    ua_start = vdc.index("VDC_UpdateAllChains:")
    ua_end = vdc.index("VDC_UpdateActiveChainPlayOnly:", ua_start)
    ua_body = vdc[ua_start:ua_end]
    if "VDC_WinSnapAllChains" not in ua_body:
        print("FAIL: VDC_UpdateAllChains must snapshot head sample before clear")
        return False
    # WIN outro (бегущий эмиттер) гоняется из VDC_UpdateWin.
    main = (ROOT / "Source" / "ASM" / "main.asm").read_text(encoding="utf-8")
    uw_start = main.index("VDC_UpdateWin:")
    uw_body = main[uw_start:uw_start+1200]
    if "VDC_WinOutroUpdate" not in uw_body:
        print("FAIL: VDC_UpdateWin must run the win outro emitter")
        return False
    return True


def main() -> int:
    if not check_win_visual_source():
        return 1

    sim = ZumaZ80Sim()
    needed = (
        "Core.VDC_CheckWinMaybe",
        "Core.VDC_UpdateAllChains",
        "Core.VDC_UpdateActiveChainPlayOnly",
        "Core.VDC_SwapChains",
        "Core.VDC_UpdateWin",
        "Frog_RefilterCurrent",
        "Core.ShowCurrentLevelLoadingScreen",
        "Core.LoadGameplayAssets",
        "Core.MainLoop",
        "Core.EnterGameplayForCurrentLevel",
        "Core.VDC_GameState",
        "Core.VDC_DialogState",
        "Core.VDC_GaugeFull",
        "Core.VDC_HasSecondChain",
        "Core.VDC_SecondActive",
        "Core.VDC_SlotsLen",
        "Core.VDC2_Slots",
        "Core.VDC2_SlotsLen",
        "Core.VDC_WinTick",
        "Core.VDC_PreviewTick",
        "Core.VDC_PlayerScore",
        "Core.VDC_GameSeconds",
        "Core.Frog_BallColor",
        "Core.Frog_NextBallColor",
        "CurrentLevel",
        "CurrentCodePage",
    )
    if not require_symbols(sim, needed):
        return 1

    # VDC_UpdateWin shows the loading frame and then calls LoadGameplayAssets.
    # Those paths are covered separately; keep this test focused on win-state flow.
    sim.set_byte(sim.sym["Core.ShowCurrentLevelLoadingScreen"], 0xC9)  # RET
    sim.set_byte(sim.sym["Core.LoadGameplayAssets"], 0xC9)  # RET
    # Win/menu gameplay entry was unified (EnterGameplayForCurrentLevel) and now
    # ends in `JP MainLoop` (clean frame-loop restart) instead of RET into the
    # mid-frame dialog handler. Stub MainLoop with RET so the handoff still
    # returns to this harness after setting CurrentLevel/CurrentCodePage.
    sim.set_byte(sim.sym["Core.MainLoop"], 0xC9)  # RET

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

    # Regression guard: the frame loop calls VDC_CheckWinMaybe after VDC_Update.
    # Once already in WIN, that must not re-arm WinTick/PreviewTick every frame.
    sim.set_byte(sim.sym["Core.VDC_WinTick"], 10)
    sim.set_byte(sim.sym["Core.VDC_PreviewTick"], 10)
    sim.call(sim.sym["Core.VDC_UpdateAllChains"])
    win_tick = sim.get_byte(sim.sym["Core.VDC_WinTick"])
    preview_tick = sim.get_byte(sim.sym["Core.VDC_PreviewTick"])
    if win_tick != 9 or preview_tick != 9:
        print(
            "FAIL: win state was re-armed instead of ticking down, "
            f"got win/preview {win_tick}/{preview_tick}"
        )
        return 1

    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 1)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 5)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state == VDC_STATE_WIN:
        print("FAIL: dual-chain win triggered while chain2 still has balls")
        return 1

    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 0)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state != VDC_STATE_WIN:
        print("FAIL: dual-chain win did not trigger after both chains cleared")
        return 1

    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 3)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 1)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 7)
    install_store_a_ret(
        sim,
        sim.sym["Core.VDC_UpdateActiveChainPlayOnly"],
        sim.sym["Core.VDC2_SlotsLen"],
        0x77,
    )
    sim.call(sim.sym["Core.VDC_UpdateAllChains"])
    slots2 = sim.get_byte(sim.sym["Core.VDC2_SlotsLen"])
    if slots2 != 7:
        print("FAIL: pause dialog did not freeze second chain update")
        return 1

    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 1)
    sim.set_byte(sim.sym["Core.VDC_SecondActive"], 0)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 1)
    sim.set_byte(sim.sym["Core.VDC2_Slots"], 2)
    sim.set_byte(sim.sym["Core.Frog_BallColor"], 5)
    sim.set_byte(sim.sym["Core.Frog_NextBallColor"], 5)
    sim.call(sim.sym["Core.VDC_SwapChains"])
    sim.call(sim.sym["Frog_RefilterCurrent"])
    sim.call(sim.sym["Core.VDC_SwapChains"])
    ball = sim.get_byte(sim.sym["Core.Frog_BallColor"])
    next_ball = sim.get_byte(sim.sym["Core.Frog_NextBallColor"])
    if (ball, next_ball) != (2, 2):
        print(f"FAIL: remaining-chain color filter ignored chain2 mask, got {ball}/{next_ball}")
        return 1

    # First verify the exact boundary behavior: win_tick 1 reaches LEVEL DONE.
    sim.set_byte(sim.sym["Core.VDC_WinTick"], 1)
    sim.set_byte(sim.sym["Core.VDC_PreviewTick"], 0)
    sim.call(sim.sym["Core.VDC_UpdateWin"])
    dlg = sim.get_byte(sim.sym["Core.VDC_DialogState"])
    if dlg == 0:
        print("FAIL: expected LEVEL DONE dialog after win tick")
        return 1

    # The OK/fade path calls LoadNextLevelWithLoading; verify that helper advances.
    sim.set_byte(sim.sym["CurrentCodePage"], 0x41)
    sim.call(sim.sym["Core.LoadNextLevelWithLoading"])
    level = sim.get_byte(sim.sym["CurrentLevel"])
    if level != 1:
        print(f"FAIL: expected CurrentLevel 1 after loading handoff, got {level}")
        return 1
    code_page = sim.get_byte(sim.sym["CurrentCodePage"])
    if code_page != 0x04:
        print(f"FAIL: expected gameplay CurrentCodePage #04 after loading handoff, got #{code_page:02X}")
        return 1

    sim.set_byte(sim.sym["CurrentLevel"], 21)
    sim.set_byte(sim.sym["CurrentCodePage"], 0x41)
    sim.call(sim.sym["Core.LoadNextLevelWithLoading"])
    level = sim.get_byte(sim.sym["CurrentLevel"])
    if level != 0:
        print(f"FAIL: expected CurrentLevel wrap to 0, got {level}")
        return 1
    code_page = sim.get_byte(sim.sym["CurrentCodePage"])
    if code_page != 0x04:
        print(f"FAIL: expected gameplay CurrentCodePage #04 after wrap handoff, got #{code_page:02X}")
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
