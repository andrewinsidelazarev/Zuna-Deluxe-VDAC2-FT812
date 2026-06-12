#!/usr/bin/env python3
"""balls_atlas NATIVE ARGB4 — 6 colors × 16 spin phases @ 32×32.

Source: ~/Desktop/Zuma Deluxe/graphics/spritesheet.png (TS-Conf reference).
Columns в источнике (28×28 cells начиная с x=8):
  0=purple/cyan-blue, 1=green, 2=yellow-gold, 3=red, 4=white, 5=...?
Реальный mapping проверяем сэмплом.

VDC colors:  0=BLUE, 1=GREEN, 2=RED, 3=YELLOW, 4=PURPLE, 5=WHITE.

Layout: 48 cells vertically stacked, cell = color*8 + spin.
Total = 48 × 32×32 × 2 bpp = 96 KB = 6 SPG pages.

Output:
  balls_native_p00..p11.bin   (12 pages)
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
N_PHASES = 16
N_COLORS = 6
PAGE_BYTES = 16384

# Mapping VDC index -> source PNG column:
# PNG cols (from sampling): 0=cyan-blue, 1=green, 2=purple, 3=red, 4=white, 5=yellow
VDC_TO_PNG = {
    0: 0,   # BLUE   -> cyan-blue
    1: 1,   # GREEN  -> green
    2: 3,   # RED    -> red
    3: 5,   # YELLOW -> yellow
    4: 2,   # PURPLE -> purple
    5: 4,   # WHITE  -> white
}
VDC_NAMES = ['BLUE','GREEN','RED','YELLOW','PURPLE','WHITE']

def to_argb4_bytes(arr):
    """RGBA H×W×4 → ARGB4 packed bytes (little-endian)."""
    arr = arr.astype(np.uint16)
    a = (arr[..., 3] >> 4) & 0xF
    r = (arr[..., 0] >> 4) & 0xF
    g = (arr[..., 1] >> 4) & 0xF
    b = (arr[..., 2] >> 4) & 0xF
    word = (a << 12) | (r << 8) | (g << 4) | b
    return word.astype('<u2').tobytes()

def main():
    img = np.array(Image.open(SRC).convert('RGBA'))
    print('source shape:', img.shape)

    atlas = bytearray()
    for vdc_color in range(N_COLORS):
        png_col = VDC_TO_PNG[vdc_color]
        for phase in range(N_PHASES):
            # Blue has 47 valid source frames; use that common cycle for all colors.
            src_frame = round(phase * 47 / N_PHASES)
            y0 = src_frame * CELL
            x0 = png_col * CELL
            cell = img[y0:y0+CELL, x0:x0+CELL]
            if cell.shape[:2] != (CELL, CELL):
                print(f'WARN: vdc={vdc_color} ({VDC_NAMES[vdc_color]}) phase={phase} cell shape {cell.shape}')
                cell = np.zeros((CELL, CELL, 4), dtype=np.uint8)
            atlas += to_argb4_bytes(cell)
        print(f'  VDC color {vdc_color} ({VDC_NAMES[vdc_color]:<6}) <- PNG col {png_col}')

    pages = (len(atlas) + PAGE_BYTES - 1) // PAGE_BYTES
    print(f'NATIVE ARGB4 atlas: {len(atlas)} bytes ({len(atlas)/1024:.1f} KB), {pages} SPG pages')

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for i in range(pages):
        chunk = atlas[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        with open(OUT_DIR / f'balls_native_p{i:02d}.bin', 'wb') as f:
            f.write(chunk)
    print(f'Wrote balls_native_p00..p{pages-1:02d}.bin')

    # Preview: phase 0 of all 6 colors side by side
    preview = Image.new('RGBA', (CELL * N_COLORS, CELL), (0, 0, 0, 0))
    for vdc_color in range(N_COLORS):
        png_col = VDC_TO_PNG[vdc_color]
        cell = img[0:CELL, png_col*CELL:(png_col+1)*CELL]
        preview.paste(Image.fromarray(cell, 'RGBA'), (vdc_color * CELL, 0))
    preview.resize((preview.width * 4, preview.height * 4), Image.NEAREST).save(ROOT / '_balls_native_preview.png')
    print('Preview: _balls_native_preview.png')

if __name__ == '__main__':
    main()
