#!/usr/bin/env python3
"""Validate generated tunnel top overlay command tables."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
META = ROOT / "Source" / "ASM" / "top_mask_overlay_meta.inc"
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "top_masks"


def main() -> int:
    text = META.read_text(encoding="ascii")
    failures: list[str] = []
    if "TOP_MASK_CMD_BYTES EQU 28" not in text:
        failures.append("TOP_MASK_CMD_BYTES is not 28, expected COLOR_RGB + 6 bitmap commands")
    records = re.findall(r"DB #([0-9A-F]{2}) : DW #[0-9A-F]{4} : DB #[0-9A-F]{2} : DW (\d+)\n\s+DW ([^\n]+)", text)
    if len(records) != 17:
        failures.append(f"expected 17 top-mask components, got {len(records)}")
    fractional_vertices = 0
    for page_hex, size_s, words_s in records:
        size = int(size_s)
        words = [int(part.strip().lstrip("#"), 16) for part in words_s.split(",")]
        cmds = [words[i] | (words[i + 1] << 16) for i in range(0, len(words), 2)]
        if len(cmds) != 7:
            failures.append(f"page #{page_hex}: expected 7 commands, got {len(cmds)}")
            continue
        if (cmds[0] >> 24) != 0x04:
            failures.append(f"page #{page_hex}: first command is not COLOR_RGB")
        if (cmds[1] >> 24) != 0x01:
            failures.append(f"page #{page_hex}: second command is not BITMAP_SOURCE")
        if (cmds[3] >> 24) != 0x07 or ((cmds[3] >> 19) & 0x1F) != 2:
            failures.append(f"page #{page_hex}: BITMAP_LAYOUT is not FT_L4")
        if (cmds[6] >> 30) != 0x01:
            failures.append(f"page #{page_hex}: last command is not VERTEX2F")
        x16 = (cmds[6] >> 15) & 0x7FFF
        y16 = cmds[6] & 0x7FFF
        if x16 % 16 != 0 or y16 % 16 != 0:
            fractional_vertices += 1
        if size >= 400 * 300 // 2:
            failures.append(f"page #{page_hex}: suspicious fullscreen-sized L4 component ({size} bytes)")
    files = list(ASSETS.glob("top_mask_*.bin"))
    if len(files) != 17:
        failures.append(f"expected 17 generated top-mask files, got {len(files)}")
    if fractional_vertices < 8:
        failures.append(f"expected many fractional scaled VERTEX2F coords, got {fractional_vertices}")
    if failures:
        print("FAIL: top-mask overlay command validation")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: top-mask overlays draw colored FT_L4 cropped components at scaled screen coords")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
