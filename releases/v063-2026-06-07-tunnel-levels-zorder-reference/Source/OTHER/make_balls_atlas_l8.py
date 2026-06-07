#!/usr/bin/env python3
"""balls_atlas L8 — 1 базовый шар × 32 spin phases.

Атлас 32×32 × 32 frames = 1 byte/pixel (L8 = luminance only) = 32 KB total.
Это в **12 раз меньше** оригинальных 384 KB ARGB4 (6×32 phases).

Цвет в игре делается на FT812 hardware через COLOR_RGB tint:
  cmd_dl(COLOR_RGB(r, g, b));
  cmd_dl(VERTEX2F(x, y));
FT812 умножает L8 luminance на (R, G, B), что даёт окрашенный шар.

Источник: тот же sprite-sheet что был для ARGB4. Берём ОДИН цвет (column 4 =
silver/white — самый "нейтральный" по shading) и конвертируем RGB → luminance
(ITU-R BT.601: Y = 0.299*R + 0.587*G + 0.114*B). Анти-aliased edges retained.

Атлас layout: 32 cells × 32×32 × 1 byte = 32768 bytes = 2 SPG pages.
"""
import os
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = Path(os.path.expanduser('~/Desktop/Zuma Deluxe/graphics/Zuma Deluxe - Gameplay - Balls.png'))
OUT_DIR = ROOT / 'Graphics' / 'Converted'

CELL = 32
N_FRAMES = 32
PAGE_BYTES = 16384
BASE_COLOR_COL = 4   # column index in source: 0=blue,1=green,2=red?,3=yellow?,4=silver(neutral)

def main():
    img = Image.open(SRC).convert('RGBA')
    arr = np.array(img)
    H, W = arr.shape[:2]
    assert W == 192, f'Source W={W}'

    atlas = bytearray()
    for fi in range(N_FRAMES):
        cell = arr[fi*CELL:(fi+1)*CELL, BASE_COLOR_COL*CELL:(BASE_COLOR_COL+1)*CELL]
        # Build L8: each pixel = max(luminance, ~alpha) so that alpha edges fade.
        # Actually for L8, FT812 treats byte as ALPHA * BASE_COLOR.
        # Pixels with low alpha → 0 (transparent), high alpha → luminance.
        rgb = cell[..., :3].astype(np.int32)
        alpha = cell[..., 3].astype(np.int32)
        # Luminance (ITU-R BT.601)
        y = (rgb[..., 0] * 77 + rgb[..., 1] * 150 + rgb[..., 2] * 29) >> 8
        # Combine with alpha: result = y * alpha / 255 (premultiplied effect)
        l8 = (y * alpha) // 255
        l8 = np.clip(l8, 0, 255).astype(np.uint8)
        atlas += l8.tobytes()

    total = len(atlas)
    print(f'L8 atlas: {total} bytes ({total/1024:.1f} KB), {N_FRAMES} frames × {CELL}×{CELL}')
    pages = (total + PAGE_BYTES - 1) // PAGE_BYTES
    print(f'SPG pages: {pages}')

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    # Write single file for compression / split
    with open(OUT_DIR / 'balls_atlas_l8.bin', 'wb') as f:
        f.write(atlas)
    # Also split into 16K chunks for SPG
    for i in range(pages):
        chunk = atlas[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        with open(OUT_DIR / f'balls_atlas_l8_p{i:02d}.bin', 'wb') as f:
            f.write(chunk)
    print(f'Wrote balls_atlas_l8_p00..p{pages-1:02d}.bin')

    # Preview: assemble all 32 frames as a 32×1 strip with white tint
    preview = Image.new('L', (CELL * N_FRAMES, CELL), 0)
    for fi in range(N_FRAMES):
        cell_data = atlas[fi*CELL*CELL:(fi+1)*CELL*CELL]
        sub = Image.frombytes('L', (CELL, CELL), bytes(cell_data))
        preview.paste(sub, (fi * CELL, 0))
    preview_scaled = preview.resize((preview.width * 3, preview.height * 3), Image.NEAREST)
    preview_scaled.save(ROOT / '_balls_l8_preview.png')
    print('Preview: _balls_l8_preview.png')

if __name__ == '__main__':
    main()
