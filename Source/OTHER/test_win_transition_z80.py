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


def install_ret(sim: ZumaZ80Sim, addr: int) -> None:
    sim.set_byte(addr, 0xC9)  # RET


def require_symbols(sim: ZumaZ80Sim, names: tuple[str, ...]) -> bool:
    missing = [name for name in names if name not in sim.sym]
    if missing:
        print(f"FAIL: missing symbols: {', '.join(missing)}")
        return False
    return True


def check_dual_frame_win_gate() -> bool:
    sim = ZumaZ80Sim()
    needed = (
        "Core.VDC_UpdateAllChains",
        "Core.VDC_Update",
        "Core.VDC_UpdateActiveChainPlayOnly",
        "Core.SetSecondTrackPage",
        "Core.SetCurrentTrackPage",
        "Core.VDC_GameState",
        "Core.VDC_DialogState",
        "Core.VDC_GaugeFull",
        "Core.VDC_HasSecondChain",
        "Core.VDC_SecondActive",
        "Core.VDC_SlotsLen",
        "Core.VDC2_SlotsLen",
        "UnpackAndUploadPage",
    )
    if not require_symbols(sim, needed):
        return False

    install_ret(sim, sim.sym["Core.VDC_Update"])
    install_ret(sim, sim.sym["Core.VDC_UpdateActiveChainPlayOnly"])
    install_ret(sim, sim.sym["Core.SetSecondTrackPage"])
    install_ret(sim, sim.sym["Core.SetCurrentTrackPage"])
    install_ret(sim, sim.sym["UnpackAndUploadPage"])

    cases = (
        (0, 5, False, "chain2 still has balls"),
        (5, 0, False, "chain1 still has balls"),
        (0, 0, True, "both chains empty"),
    )
    for len1, len2, should_win, label in cases:
        sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
        sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
        sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
        sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 1)
        sim.set_byte(sim.sym["Core.VDC_SecondActive"], 0)
        sim.set_byte(sim.sym["Core.VDC_SlotsLen"], len1)
        sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], len2)
        sim.call(sim.sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        state = sim.get_byte(sim.sym["Core.VDC_GameState"])
        if should_win and state != VDC_STATE_WIN:
            print(f"FAIL: frame-loop dual win did not trigger when {label}")
            return False
        if not should_win and state == VDC_STATE_WIN:
            print(f"FAIL: frame-loop dual win triggered while {label}")
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
    # Head sample is folded into the mandatory cache pre-pass. It must not add
    # another full traversal to VDC_UpdateAllChains.
    vdc = (ROOT / "Source" / "ASM" / "VDC.asm").read_text(encoding="utf-8")
    ua_start = vdc.index("VDC_UpdateAllChains:")
    ua_end = vdc.index("VDC_UpdateActiveChainPlayOnly:", ua_start)
    ua_body = vdc[ua_start:ua_end]
    if "VDC_WinSnapAllChains" in ua_body:
        print("FAIL: VDC_UpdateAllChains still performs the duplicate WIN snapshot pass")
        return False
    cache_start = src.index("ZL_BuildActiveChainCache:")
    cache_end = src.index("ZL_DrawCachedActiveChainWithShadowMaybe:", cache_start)
    cache_body = src[cache_start:cache_end]
    required = ("VDC_WinHeadS1", "VDC_WinHeadS2", "VDC_GameState", "VDC_SecondActive")
    if any(name not in cache_body for name in required):
        print("FAIL: cache pre-pass does not maintain both WIN head samples")
        return False
    # WIN outro (бегущий эмиттер) гоняется из VDC_UpdateWin.
    main = (ROOT / "Source" / "ASM" / "main.asm").read_text(encoding="utf-8")
    uw_start = main.index("VDC_UpdateWin:")
    uw_body = main[uw_start:uw_start+1200]
    if "VDC_WinOutroUpdate" not in uw_body:
        print("FAIL: VDC_UpdateWin must run the win outro emitter")
        return False
    # VDC_WinOutroInit uploads WINEXP over BALLS_RAMG. During WIN the frog body
    # may stay visible, but held/next ball sprites and any leftover bullet must
    # not sample the overwritten ball atlas.
    ml = (ROOT / "Source" / "ASM" / "MainLoop.asm").read_text(encoding="utf-8")
    fg_start = ml.index("ZL_DrawFrogLayer:")
    fg_end = ml.index("ZL_AfterChains:", fg_start)
    fg_body = ml[fg_start:fg_end]
    if "CP   VDC_STATE_WIN" not in fg_body or ".skip_frog_ball_sprites:" not in fg_body:
        print("FAIL: WIN frog layer must gate held/next ball sprites")
        return False
    ball_now = fg_body.index("CALL Frog_DrawBallNow")
    ball_next = fg_body.index("CALL Frog_DrawNextBall")
    skip_label = fg_body.index(".skip_frog_ball_sprites:")
    if not (ball_now < skip_label and ball_next < skip_label):
        print("FAIL: WIN frog ball skip label must be after held/next ball calls")
        return False
    if "RET  Z" not in fg_body[skip_label:fg_body.index("CALL Bullet_Draw")]:
        print("FAIL: WIN frog layer must skip leftover Bullet_Draw")
        return False
    return True


def main() -> int:
    if not check_win_visual_source():
        return 1
    if not check_dual_frame_win_gate():
        return 1

    sim = ZumaZ80Sim()
    needed = (
        "Core.VDC_CheckWinMaybe",
        "Core.VDC_UpdateAllChains",
        "Core.VDC_UpdateActiveChainPlayOnly",
        "Core.VDC_SwapChains",
        "Core.VDC_UpdateWin",
        "Core.Frog_Update",
        "Core.ZL_AimUpdate",
        "Core.Bullet_Spawn",
        "Core.Bullet_Active",
        "Core.Bullet_Color",
        "Core.GS_PlaySfx",
        "Core.VDC_ResetBulletGapTracking",
        "Core.Input_KSpace",
        "Frog_RefilterCurrent",
        "Core.VDC_GameState",
        "Core.VDC_DialogState",
        "Core.VDC_GaugeFull",
        "Core.VDC_HasSecondChain",
        "Core.VDC_SecondActive",
        "Core.VDC_Slots",
        "Core.VDC_SlotsLen",
        "Core.VDC2_Slots",
        "Core.VDC2_SlotsLen",
        "Core.VDC_WinTick",
        "Core.VDC_WinOutroActive",
        "Core.VDC_PreviewTick",
        "Core.VDC_PlayerScore",
        "Core.VDC_GameSeconds",
        "Core.Frog_BallColor",
        "Core.Frog_NextBallColor",
        "Core.Frog_Angle",
        "Core.Frog_IsFire",
        "Core.Frog_KeySpacePrev",
        "Core.Frog_PosStartX",
        "Core.Frog_PosStartY",
        "Core.ZL_MouseMoved",
        "Core.ZL_MotionGrace",
        "CurrentLevel",
    )
    if not require_symbols(sim, needed):
        return 1

    # VDC_WinOutroInit now re-uploads the WIN-explosion atlas into the (now empty)
    # balls RAM_G region via UnpackAndUploadPage (real zx7 decomp + FT.WriteMem).
    # That needs the resident winexp SPG pages, which this focused harness does not
    # map, so stub the page uploader to RET — the win-state flow logic is unaffected.
    sim.set_byte(sim.sym["UnpackAndUploadPage"], 0xC9)  # RET
    if "LogShotFired" in sim.sym:
        install_ret(sim, sim.sym["LogShotFired"])
    install_ret(sim, sim.sym["Core.GS_PlaySfx"])
    install_ret(sim, sim.sym["Core.VDC_ResetBulletGapTracking"])

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

    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 5)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 0)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state == VDC_STATE_WIN:
        print("FAIL: dual-chain win triggered while chain1 still has balls")
        return 1

    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 0)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state != VDC_STATE_WIN:
        print("FAIL: dual-chain win did not trigger after both chains cleared")
        return 1

    # Regression guard: after the last color explodes, SlotsLen may still be
    # non-zero because only gap/explode markers remain. That is already outside
    # gameplay: enter WIN immediately, clear any in-flight shot/recoil, and make
    # Bullet_Spawn block on the next input frame.
    sim.set_byte(sim.sym["CurrentLevel"], 0)
    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
    sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 0)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 4)
    for idx, value in enumerate((0xFD, 0xFE, 0xFD, 0xFE)):
        sim.set_byte(sim.sym["Core.VDC_Slots"] + idx, value)
    sim.set_byte(sim.sym["Core.Bullet_Active"], 1)
    sim.set_byte(sim.sym["Core.Frog_IsFire"], 1)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state != VDC_STATE_WIN:
        print("FAIL: marker-only chain did not enter WIN immediately")
        return 1
    if sim.get_byte(sim.sym["Core.Bullet_Active"]) != 0 or sim.get_byte(sim.sym["Core.Frog_IsFire"]) != 0:
        print("FAIL: WIN entry did not clear active shot/recoil")
        return 1
    sim.set_byte(sim.sym["Core.Bullet_Active"], 0)
    sim.set_byte(sim.sym["Core.VDC_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.VDC2_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.Frog_BallColor"], 2)
    sim.set_byte(sim.sym["Core.Frog_Angle"], 0)
    set_word(sim, sim.sym["Core.Frog_PosStartX"], 512)
    set_word(sim, sim.sym["Core.Frog_PosStartY"], 384)
    sim.call(sim.sym["Core.Bullet_Spawn"])
    if sim.get_byte(sim.sym["Core.Bullet_Active"]) != 0:
        print("FAIL: marker-only WIN state still allowed a shot")
        return 1

    sim.set_byte(sim.sym["CurrentLevel"], 4)  # L05 blackswirley, zero-based
    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
    sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 0)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 3)
    for idx, value in enumerate((0xFD, 0xFE, 0xFD)):
        sim.set_byte(sim.sym["Core.VDC_Slots"] + idx, value)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 2)
    sim.set_byte(sim.sym["Core.VDC2_Slots"], 2)
    sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFD)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state == VDC_STATE_WIN:
        print("FAIL: marker-only primary chain entered WIN while chain2 still has a live ball")
        return 1

    # Real-failure guard: on a dual level, a transient false VDC_HasSecondChain
    # must not turn one empty chain into WIN while VDC2 still has balls. The
    # visible symptom is frog WIN behavior plus blocked shots; keep PLAY and
    # prove Bullet_Spawn still arms a shot.
    sim.set_byte(sim.sym["CurrentLevel"], 4)  # L05 blackswirley, zero-based
    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
    sim.set_byte(sim.sym["Core.VDC_GaugeFull"], 1)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 0)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 5)
    sim.call(sim.sym["Core.VDC_CheckWinMaybe"])
    state = sim.get_byte(sim.sym["Core.VDC_GameState"])
    if state == VDC_STATE_WIN:
        print("FAIL: dual level entered WIN through false single-chain gate")
        return 1

    sim.set_byte(sim.sym["Core.Bullet_Active"], 0)
    sim.set_byte(sim.sym["Core.VDC_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.VDC2_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.Frog_BallColor"], 2)
    sim.set_byte(sim.sym["Core.Frog_Angle"], 0)
    set_word(sim, sim.sym["Core.Frog_PosStartX"], 512)
    set_word(sim, sim.sym["Core.Frog_PosStartY"], 384)
    sim.call(sim.sym["Core.Bullet_Spawn"])
    if sim.get_byte(sim.sym["Core.Bullet_Active"]) != 1:
        print("FAIL: shot stayed blocked while dual level still has a live chain")
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
    if (ball, next_ball) != (5, 5):
        print(f"FAIL: remaining-chain refilter changed wrong frog colors, got {ball}/{next_ball}")
        return 1

    # Real input-order guard: Space/Enter/Kempston fire used to run in
    # ZL_AimUpdate before MainLoop swapped to the only live chain. With chain1
    # empty and chain2 alive that made Frog_NewNextColor see an empty mask.
    sim.set_byte(sim.sym["Core.VDC_GameState"], 0)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
    sim.set_byte(sim.sym["Core.VDC_HasSecondChain"], 1)
    sim.set_byte(sim.sym["Core.VDC_SecondActive"], 0)
    sim.set_byte(sim.sym["Core.VDC_SlotsLen"], 0)
    sim.set_byte(sim.sym["Core.VDC2_SlotsLen"], 1)
    sim.set_byte(sim.sym["Core.VDC2_Slots"], 2)
    sim.set_byte(sim.sym["Core.Frog_BallColor"], 5)
    sim.set_byte(sim.sym["Core.Frog_NextBallColor"], 5)
    sim.set_byte(sim.sym["Core.Frog_KeySpacePrev"], 0)
    sim.set_byte(sim.sym["Core.Frog_IsFire"], 0)
    sim.set_byte(sim.sym["Core.Bullet_Active"], 0)
    sim.set_byte(sim.sym["Core.VDC_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.VDC2_KzFrame"], 1)
    sim.set_byte(sim.sym["Core.Input_KSpace"], 1)
    sim.set_byte(sim.sym["Core.ZL_MouseMoved"], 0)
    sim.set_byte(sim.sym["Core.ZL_MotionGrace"], 0)
    sim.call(sim.sym["Core.ZL_AimUpdate"])
    if sim.get_byte(sim.sym["Core.Bullet_Active"]) != 0:
        print("FAIL: fire-key spawned before remaining-chain context was selected")
        return 1
    sim.call(sim.sym["Core.VDC_SwapChains"])
    sim.call(sim.sym["Core.Frog_Update"], max_steps=5_000_000)
    sim.call(sim.sym["Core.VDC_SwapChains"])
    sim.set_byte(sim.sym["Core.Input_KSpace"], 0)
    ball = sim.get_byte(sim.sym["Core.Frog_BallColor"])
    next_ball = sim.get_byte(sim.sym["Core.Frog_NextBallColor"])
    shot_color = sim.get_byte(sim.sym["Core.Bullet_Color"])
    if sim.get_byte(sim.sym["Core.Bullet_Active"]) != 1 or (ball, next_ball, shot_color) != (2, 2, 5):
        print(
            "FAIL: fire-key did not keep visible shot color and use chain2 for next colors, "
            f"ball/next/shot={ball}/{next_ball}/{shot_color}"
        )
        return 1

    # First verify the exact fallback-timer boundary: win_tick 1 decrements to
    # zero on this frame, then the next frame reaches LEVEL DONE.
    sim.set_byte(sim.sym["Core.VDC_GameState"], VDC_STATE_WIN)
    sim.set_byte(sim.sym["Core.VDC_DialogState"], 0)
    sim.set_byte(sim.sym["Core.VDC_WinOutroActive"], 0)
    sim.set_byte(sim.sym["Core.VDC_WinTick"], 1)
    sim.set_byte(sim.sym["Core.VDC_PreviewTick"], 0)
    sim.call(sim.sym["Core.VDC_UpdateWin"])
    sim.call(sim.sym["Core.VDC_UpdateWin"])
    dlg = sim.get_byte(sim.sym["Core.VDC_DialogState"])
    if dlg == 0:
        print("FAIL: expected LEVEL DONE dialog after win tick")
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

    print("PASS: win-state enters, awards bonus, reaches dialog, and resets level state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
