#!/usr/bin/env python3
"""balls_atlas MONO ARGB4 — single colorless atlas + COLOR_RGB tint per-ball.

Идея: ARGB4 атлас одного NEUTRAL шара (R=G=B=luminance/16, A=alpha/16).
FT812 при отрисовке умножает (R,G,B,A) на COLOR_RGB(R',G',B'),COLOR_A(A')
→ tinted version с сохранением shading (Maya face = darker shades of body color).

Размер: 32 spin phases × 32×32 × 2 bpp = 64 KB = 4 SPG pages.
Save vs 384 KB ARGB4 = 320 KB.

Источник: silver ball (col 4) — colorless luminance, best для tint.

Output:
  balls_mono_p00..p03.bin   (4 pages = 64 KB)
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
SOURCE_COL = 4   # silver — neutral luminance

def main():
    img = Image.open(SRC).convert('RGBA')
    arr = np.array(img)

    atlas = bytearray()
    for fi in range(N_FRAMES):
        cell = arr[fi*CELL:(fi+1)*CELL, SOURCE_COL*CELL:(SOURCE_COL+1)*CELL].copy()
        r = cell[..., 0].astype(np.int32)
        g = cell[..., 1].astype(np.int32)
        b = cell[..., 2].astype(np.int32)
        a = cell[..., 3].astype(np.int32)

        # Compute luminance (ITU-R BT.601: Y = 0.299*R + 0.587*G + 0.114*B)
        y = (r * 77 + g * 150 + b * 29) >> 8
        y = np.clip(y, 0, 255).astype(np.uint16)
        a16 = np.clip(a, 0, 255).astype(np.uint16)

        # Pack ARGB4 (LE 16-bit per pixel): R=G=B=luminance/16, A=alpha/16
        a4 = (a16 >> 4) & 0xF
        l4 = (y >> 4) & 0xF
        word = (a4 << 12) | (l4 << 8) | (l4 << 4) | l4
        atlas += word.astype('<u2').tobytes()

    pages = (len(atlas) + PAGE_BYTES - 1) // PAGE_BYTES
    print(f'MONO ARGB4 atlas: {len(atlas)} bytes ({len(atlas)/1024:.1f} KB), {pages} SPG pages')

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for i in range(pages):
        chunk = atlas[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        with open(OUT_DIR / f'balls_mono_p{i:02d}.bin', 'wb') as f:
            f.write(chunk)
    print(f'Wrote balls_mono_p00..p{pages-1:02d}.bin')

    # Preview: 6 colors tinted
    colors = [
        (50, 100, 240),    # blue
        (40, 220, 80),     # green
        (240, 50, 50),     # red
        (240, 220, 30),    # yellow
        (230, 80, 220),    # purple
        (220, 220, 220),   # silver
    ]
    preview = Image.new('RGBA', (CELL * 6, CELL), (0, 0, 0, 0))
    for ci, (R, G, B) in enumerate(colors):
        cell_bytes = atlas[0:CELL*CELL*2]
        words = np.frombuffer(cell_bytes, dtype='<u2').reshape(CELL, CELL)
        a4 = (words >> 12) & 0xF
        l4 = (words >> 8) & 0xF
        rgba = np.zeros((CELL, CELL, 4), dtype=np.uint8)
        # FT812-style multiply: output.RGB = COLOR.RGB * pixel.RGB/15
        rgba[..., 0] = (R * l4 / 15).astype(np.uint8)
        rgba[..., 1] = (G * l4 / 15).astype(np.uint8)
        rgba[..., 2] = (B * l4 / 15).astype(np.uint8)
        rgba[..., 3] = (a4 * 17).astype(np.uint8)
        ball = Image.fromarray(rgba, 'RGBA')
        preview.paste(ball, (ci * CELL, 0))

    preview.resize((preview.width * 4, preview.height * 4), Image.NEAREST).save(ROOT / '_balls_mono_preview.png')
    print('Preview: _balls_mono_preview.png')

if __name__ == '__main__':
    main()
