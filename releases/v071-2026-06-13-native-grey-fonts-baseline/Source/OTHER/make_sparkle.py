#!/usr/bin/env python3
"""Extract sparkle/diamond sprite from HD gameobjects.png and render as ARGB4.

Source: `~/Desktop/Zuma-Deluxe-HD-ref/content/images/gameobjects.png`
Sprite location: x=735..757, y=2467..2490 (biggest diamond frame, ~18×17 px).
Padded/centered into 24×24 ARGB4 cell = 1152 bytes.
"""
import os
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = Path(r"C:/Users/Администратор/Desktop/Zuma-Deluxe-HD-ref/content/images/gameobjects.png")
OUT_BIN = ROOT / "Graphics" / "Converted" / "sparkle.bin"
OUT_PREVIEW = ROOT / "_sparkle_preview.png"

CELL_W = 24
CELL_H = 24

def to_argb4(img):
    arr = np.array(img).astype(np.uint16)
    a = (arr[..., 3] >> 4) & 0xF
    r = (arr[..., 0] >> 4) & 0xF
    g = (arr[..., 1] >> 4) & 0xF
    b = (arr[..., 2] >> 4) & 0xF
    out = (a << 12) | (r << 8) | (g << 4) | b
    return out.astype('<u2').tobytes()

def main():
    img = Image.open(SRC).convert('RGBA')
    # crop biggest sparkle (~18×17 at 738..755, 2470..2486)
    sparkle = img.crop((738, 2470, 756, 2487))
    cell = Image.new('RGBA', (CELL_W, CELL_H), (0, 0, 0, 0))
    cell.paste(sparkle, ((CELL_W - sparkle.width) // 2, (CELL_H - sparkle.height) // 2), sparkle)
    cell.save(OUT_PREVIEW)
    data = to_argb4(cell)
    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_BIN, 'wb') as f:
        f.write(data)
    print(f'Wrote {OUT_BIN}: {len(data)} bytes ({CELL_W}×{CELL_H} ARGB4)')

if __name__ == '__main__':
    main()
