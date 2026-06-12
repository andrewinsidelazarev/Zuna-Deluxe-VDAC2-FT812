from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAINLOOP = ROOT / "Source" / "ASM" / "MainLoop.asm"
LEVELS = ROOT / "Source" / "ASM" / "level_runtime_table.inc"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def block(text: str, start: str, end: str) -> str:
    i = text.index(start)
    j = text.index(end, i)
    return text[i:j]


def star_table_count(text: str, label: str, next_label: str | None) -> int:
    i = text.index(label + ":")
    if next_label is None:
        tail = text[i:]
        m = re.search(r"\n\S", tail[len(label) + 2 :])
        chunk = tail if m is None else tail[: len(label) + 2 + m.start()]
    else:
        j = text.index(next_label + ":", i)
        chunk = text[i:j]
    nums = re.findall(r"\b\d+\b", chunk)
    return len(nums)


def main() -> None:
    ml = MAINLOOP.read_text(encoding="utf-8")
    levels = LEVELS.read_text(encoding="utf-8")

    require("ZL_SPACE_LEVEL_INDEX EQU LEVEL_RUNTIME_COUNT - 1" in ml,
            "Space starfield must target the final runtime level")
    require("ZL_SPACE_STARS_PER_LAYER EQU 24" in ml,
            "Unexpected Space star count")
    require("LEVEL_RUNTIME_COUNT  EQU 22" in levels,
            "Runtime level count changed; re-check Space index")
    require("; 22: space / Space" in levels,
            "Space must remain level 22 in runtime table")

    draw_frame = block(ml, "ZL_DrawFrame:", "ZL_DrawActiveChain:")
    bg_end = draw_frame.index("FT_Vertex2ii 0, 0, ZL_BG_HANDLE, 0")
    stars = draw_frame.index("CALL ZL_DrawSpaceStarsMaybe")
    bitmaps = draw_frame.index("; One bitmap primitive for the remaining bitmap layers.")
    require(bg_end < stars < bitmaps,
            "Space stars must be drawn after background and before gameplay bitmaps")

    maybe = block(ml, "ZL_DrawSpaceStarsMaybe:", "; In: HL=seed pairs")
    require("LD   A, (CurrentLevel)" in maybe and "CP   ZL_SPACE_LEVEL_INDEX" in maybe,
            "Space stars must be gated by CurrentLevel")
    require(maybe.count("CALL ZL_DrawSpaceStarLayer") == 3,
            "Space starfield must draw exactly three parallax layers")
    require("JP   FT.Coprocessor.ColorRGB" in maybe and "LD   E, 255" in maybe,
            "Space starfield must restore white/opaque color state")

    layer = block(ml, "ZL_DrawSpaceStarLayer:", "ZL_ReduceHLMod640:")
    require("FT_Begin FT_POINTS" in layer, "Star layer must use FT_POINTS")
    require("FT_End" in layer, "Star layer must close FT_POINTS before returning")
    require("CALL FT.Coprocessor.Vertex2f" in layer, "Star layer must emit vertices")

    for label, next_label in (
        ("ZL_StarsFar", "ZL_StarsMid"),
        ("ZL_StarsMid", "ZL_StarsNear"),
        ("ZL_StarsNear", None),
    ):
        count = star_table_count(ml, label, next_label)
        require(count == 48, f"{label} must contain 24 x/y pairs, got {count} bytes")

    print("PASS: Space starfield static checks")


if __name__ == "__main__":
    main()
