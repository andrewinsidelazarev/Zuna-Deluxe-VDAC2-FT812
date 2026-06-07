#!/usr/bin/env python3
"""Validate generated tunnel top overlay command tables."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
META = ROOT / "Source" / "ASM" / "top_mask_overlay_meta.inc"
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "top_masks"
META_BIN = ASSETS / "top_mask_meta.bin"
REC_SIZE = 36


def main() -> int:
    text = META.read_text(encoding="ascii")
    failures: list[str] = []
    if "TOP_MASK_CMD_BYTES EQU 28" not in text:
        failures.append("TOP_MASK_CMD_BYTES is not 28, expected COLOR_RGB + 6 bitmap commands")
    if "TOP_MASK_REC_SIZE EQU 36" not in text or "TOP_MASK_CMD_OFFSET EQU 8" not in text:
        failures.append("top-mask record format is not page+src_offset+ramg+size+commands")
    level_records = re.findall(r"TopMaskL\d\d: ; [^\n]+\n\s+DB (\d+) : DW #([0-9A-F]{4})", text)
    meta = META_BIN.read_bytes()
    if len(meta) % REC_SIZE != 0:
        failures.append(f"top_mask_meta.bin size {len(meta)} is not a multiple of {REC_SIZE}")
    records = []
    for count_s, offset_hex in level_records:
        count = int(count_s)
        offset = int(offset_hex, 16)
        if offset + count * REC_SIZE > len(meta):
            failures.append(f"level meta offset #{offset:04X} count {count} exceeds top_mask_meta.bin")
            continue
        for i in range(count):
            rec = meta[offset + i * REC_SIZE : offset + (i + 1) * REC_SIZE]
            page = rec[0]
            src_offset = int.from_bytes(rec[1:3], "little")
            size = int.from_bytes(rec[6:8], "little")
            cmds = [int.from_bytes(rec[8 + j * 4 : 12 + j * 4], "little") for j in range(7)]
            records.append((page, src_offset, size, cmds))
    if len(records) < 100:
        failures.append(f"expected tiled ARGB4 top-cover records, got only {len(records)}")
    fractional_vertices = 0
    pages = set()
    for page, src_offset, size, cmds in records:
        pages.add(page)
        if src_offset + size > 0x4000:
            failures.append(f"page #{page:02X}: source slice crosses SPG page boundary")
        if len(cmds) != 7:
            failures.append(f"page #{page:02X}: expected 7 commands, got {len(cmds)}")
            continue
        if (cmds[0] >> 24) != 0x04:
            failures.append(f"page #{page:02X}: first command is not COLOR_RGB")
        if (cmds[1] >> 24) != 0x01:
            failures.append(f"page #{page:02X}: second command is not BITMAP_SOURCE")
        if (cmds[3] >> 24) != 0x07 or ((cmds[3] >> 19) & 0x1F) != 6:
            failures.append(f"page #{page:02X}: BITMAP_LAYOUT is not FT_ARGB4")
        if (cmds[6] >> 30) != 0x01:
            failures.append(f"page #{page:02X}: last command is not VERTEX2F")
        x16 = (cmds[6] >> 15) & 0x7FFF
        y16 = cmds[6] & 0x7FFF
        if x16 % 16 != 0 or y16 % 16 != 0:
            fractional_vertices += 1
        if size >= 64 * 64 * 2 + 1:
            failures.append(f"page #{page:02X}: suspicious oversized ARGB4 tile ({size} bytes)")
    files = list(ASSETS.glob("top_mask_page_*.bin"))
    if len(files) != len(pages):
        failures.append(f"expected {len(pages)} packed top-mask page files, got {len(files)}")
    if len(files) > 52:
        failures.append(f"top-mask packed pages exceed #CC..#FF budget: {len(files)}")
    if fractional_vertices < 8:
        failures.append(f"expected many fractional scaled VERTEX2F coords, got {fractional_vertices}")
    if failures:
        print("FAIL: top-mask overlay command validation")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: top-mask overlays draw tiled ARGB4 top-cover fragments from packed SPG pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
