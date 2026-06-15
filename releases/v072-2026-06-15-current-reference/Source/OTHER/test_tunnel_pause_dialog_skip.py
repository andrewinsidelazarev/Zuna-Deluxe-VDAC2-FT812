#!/usr/bin/env python3
"""Validate pause/dialog tunnel rendering uses the cheap perceptual path."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAINLOOP = ROOT / "Source" / "ASM" / "MainLoop.asm"
MAIN = ROOT / "Source" / "ASM" / "main.asm"


def block_between(text: str, start: str, end: str) -> str:
    a = text.index(start)
    b = text.index(end, a)
    return text[a:b]


def main() -> int:
    ml = MAINLOOP.read_text(encoding="utf-8")
    main_asm = MAIN.read_text(encoding="utf-8")
    failures: list[str] = []

    for_level = block_between(ml, "ZL_DrawActiveChainForLevel:", "ZL_GetTopMaskForCurrentLevel:")
    if "CALL ZL_RestoreActiveTrackPage" not in for_level.split("CALL ZL_GetTopMaskForCurrentLevel", 1)[0]:
        failures.append("chain renderer does not restore slot2 track page after lazy dialog upload")
    if "Core.VDC_DialogState" not in for_level:
        failures.append("top-mask path does not branch on VDC_DialogState")
    if "LD   A, 3" not in for_level or "ZL_ChainDrawPass" not in for_level:
        failures.append("pause/dialog path does not select chain draw pass 3")
    dialog_part = for_level.split("Core.VDC_DialogState", 1)[1].split(".gameplay_top_mask:", 1)[0]
    if "ZL_UploadTopMasksMaybe" in dialog_part:
        failures.append("pause/dialog path still uploads tunnel top-cover")
    first_pause = block_between(ml, ".dialog_state:", ".dialog_skip_tunnel:")
    if "LD   A, 3" not in first_pause or "ZL_DrawTopMaskOverlay" not in first_pause:
        failures.append("first pause frame must skip tunnel balls before disabling top-cover")

    per_ball = block_between(ml, ".PerBallLoop:", ".PBPassUnder:")
    if "CP   3" not in per_ball or ".PBPassSkipTunnel" not in per_ball:
        failures.append("per-ball loop does not implement pass 3")
    skip_block = block_between(ml, ".PBPassSkipTunnel:", ".PBPassUnder:")
    if "ZL_TRACKF_TUNNEL" not in skip_block or "JP   NZ, .PBSkip" not in skip_block:
        failures.append("pass 3 does not skip TRACKF_TUNNEL balls")
    frog_layer = block_between(ml, "ZL_DrawFrogLayer:", "ZL_AfterChains:")
    frog_gate = frog_layer.split(".draw_until_dialog_loaded:", 1)[0]
    if "CP   3" not in frog_gate or ".draw_until_dialog_loaded" not in frog_gate:
        failures.append("pause dialog no longer keeps the dialog-load frog guard")
    if "CP   DLG_WIN_DONE" in frog_gate or "RET  NZ" in frog_gate:
        failures.append("lose/win dialog still hides frog instead of falling through to draw_frog")
    if "JR   .draw_frog" not in frog_gate.split("CP   3", 1)[1]:
        failures.append("non-pause dialogs do not fall through to frog draw")

    if "EnsureDialogFrameUploaded" not in main_asm:
        failures.append("dialog frame is not loaded lazily")
    all_asm = main_asm + "\n" + ml
    if "LD   (Core.ZL_TopMaskUploadedLevel), A" not in all_asm and "LD   (ZL_TopMaskUploadedLevel), A" not in all_asm:
        failures.append("dialog frame upload does not invalidate top-mask upload state")
    if "LD   (DialogFrameLoaded), A" not in ml:
        failures.append("top-mask upload does not mark dialog frame as evicted")
    ensure = block_between(ml, "EnsureDialogFrameUploaded:", "ZL_DrawActiveChainForLevel:")
    if "ZL_DialogFrameUploadDeferred" not in ensure:
        failures.append("dialog frame upload is not deferred after live top-mask RAM_G use")
    if "ZL_TopMaskUploadedLevel" not in ensure or "CurrentLevel" not in ensure:
        failures.append("dialog frame defer does not check current top-mask ownership")
    if "CP   2" not in ensure or "INC  A" not in ensure:
        failures.append("dialog frame upload must wait through a second no-top-cover barrier frame")
    draw_retry = block_between(main_asm, "DrawRetryDialog:", "; --- Dialog frame")
    if "CALL Core.EnsureDialogFrameUploaded" not in draw_retry or "RET  Z" not in draw_retry:
        failures.append("DrawRetryDialog still draws dialog frame when lazy upload was deferred")

    load_area = block_between(main_asm, "; --- Dialog palette", "; --- Native font atlas")
    if "DIALOG_FRAME_PAGE_BASE" in load_area and "EnsureDialogFrameUploaded" not in load_area:
        failures.append("level load still uploads DIALOG_FRAME eagerly")

    if failures:
        print("FAIL: tunnel pause/dialog perceptual skip")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: pause/dialog skips tunnel balls and reloads dialog frame lazily")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
