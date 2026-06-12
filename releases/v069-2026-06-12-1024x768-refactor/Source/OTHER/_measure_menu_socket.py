#!/usr/bin/env python3
"""Measure the baked MENU socket in frame_top.bin vs the hover sprite text,
to compute the exact HUD_MENU_X/Y (640-space) by aligning yellow text bboxes."""
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent.parent.parent
top = (ROOT / "Graphics" / "Converted" / "frame_top.bin").read_bytes()
pal = (ROOT / "Graphics" / "Converted" / "frame_palette_argb4.bin").read_bytes()

W, H = 640, 44


def argb4(idx):
    v = struct.unpack_from("<H", pal, idx * 2)[0]
    a = (v >> 12) & 0xF
    r = (v >> 8) & 0xF
    g = (v >> 4) & 0xF
    b = v & 0xF
    return a * 17, r * 17, g * 17, b * 17


def is_yellow(a, r, g, b):
    return a > 128 and r > 170 and g > 140 and b < 110


# Map of dark spans per row in the right part (the MENU socket plate is dark)
for y in range(H):
    row = y * W
    spans = []
    start = None
    for x in range(500, W):
        a, r, g, b = argb4(top[row + x])
        dark = a > 128 and (r + g + b) < 210
        if dark and start is None:
            start = x
        elif not dark and start is not None:
            if x - start >= 8:
                spans.append((start, x - 1))
            start = None
    if start is not None and W - start >= 8:
        spans.append((start, W - 1))
    if spans:
        print(y, spans)

# hover sprite: hud_menu_atlas.bin = 3 cells of 79x26 paletted (hud palette)
atlas = (ROOT / "Graphics" / "Converted" / "hud_menu_atlas.bin").read_bytes()
hpal = (ROOT / "Graphics" / "Converted" / "hud_palette_argb4.bin").read_bytes()
MW, MH = 79, 26


def hargb4(idx):
    v = struct.unpack_from("<H", hpal, idx * 2)[0]
    return ((v >> 12) & 0xF) * 17, ((v >> 8) & 0xF) * 17, ((v >> 4) & 0xF) * 17, (v & 0xF) * 17


for cell in range(3):
    minx, miny, maxx, maxy = 9999, 9999, -1, -1
    base = cell * MW * MH
    for y in range(MH):
        for x in range(MW):
            a, r, g, b = hargb4(atlas[base + y * MW + x])
            if is_yellow(a, r, g, b):
                minx = min(minx, x); maxx = max(maxx, x)
                miny = min(miny, y); maxy = max(maxy, y)
    print(f"sprite cell {cell} yellow bbox: x={minx}..{maxx} y={miny}..{maxy}")
