#!/usr/bin/env python3
"""balls_atlas paletted — 6 цветов × 32 spin phases × 32×32 8-bit indexed.

8 bpp pixel data + 256-color ARGB4 palette (FT_PALETTED4444):
  - Index 0: fully transparent (alpha=0)
  - Index 1..255: opaque RGB colors quantized from source
  - Edges рендерятся как binary alpha (0 или 15) — anti-alias теряется,
    но при BILINEAR на FT812 края всё равно сглаживаются.

Output:
  balls_palette.bin (256 entries × 2 bytes ARGB4 = 512 байт)
  balls_atlas_p00.bin..balls_atlas_p11.bin (12 pages, 196608 byte total = 192 KB)
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
N_COLORS = 6
N_FRAMES = 32
PAGE_BYTES = 16384

ALPHA_THRESHOLD = 128   # binary alpha threshold

def main():
    img = Image.open(SRC).convert('RGBA')
    arr = np.array(img)
    H, W = arr.shape[:2]
    assert W == N_COLORS * CELL, f'Source W={W}, expected {N_COLORS*CELL}'

    # Extract all 6×32 sprites (column = color, row = spin frame)
    sprites = []
    for ci in range(N_COLORS):
        for fi in range(N_FRAMES):
            cell = arr[fi*CELL:(fi+1)*CELL, ci*CELL:(ci+1)*CELL].copy()
            sprites.append(cell)
    assert len(sprites) == N_COLORS * N_FRAMES

    # Collect all opaque pixels for palette generation
    opaque_rgb = []
    for s in sprites:
        mask = s[..., 3] >= ALPHA_THRESHOLD
        opaque_rgb.append(s[mask, :3])
    opaque_all = np.concatenate(opaque_rgb, axis=0)
    print(f'Opaque pixels for palette: {len(opaque_all)}')

    # PIL median-cut quantization to 255 colors (index 0 reserved for transparent)
    fake_img = Image.fromarray(opaque_all.reshape(-1, 1, 3), 'RGB')
    fake_q = fake_img.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    pal_rgb_flat = fake_q.getpalette()[:255*3]  # 255 × (R,G,B)

    # Build ARGB8 palette for FT_PALETTED8: 256 entries × 4 bytes (B, G, R, A) LE.
    # FT812 PALETTED8 format reads palette as 32-bit BGRA in little-endian SPI.
    # Index 0 = transparent (all 0), 1..255 = full-alpha RGB.
    # PALETTED8 + FT812 RGBA8888: byte order = R, G, B, A
    # (R первый в memory, NOT little-endian ARGB)
    palette_bytes = bytearray()
    palette_bytes += b'\x00\x00\x00\x00'   # index 0 = transparent
    for i in range(255):
        r = pal_rgb_flat[i*3]
        g = pal_rgb_flat[i*3 + 1]
        b = pal_rgb_flat[i*3 + 2]
        a = 0xFF
        palette_bytes += bytes([r, g, b, a])   # RGBA byte order
    assert len(palette_bytes) == 1024

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(OUT_DIR / 'balls_palette.bin', 'wb') as f:
        f.write(palette_bytes)
    print(f'Wrote balls_palette.bin: 512 bytes (256 entries ARGB4)')

    # Build pixel-lookup: for each sprite pixel, find nearest palette index
    # Use sklearn-like vectorized: build palette RGB array, compute distance
    pal_rgb_arr = np.array(pal_rgb_flat, dtype=np.int32).reshape(255, 3)

    atlas_bytes = bytearray()
    for s in sprites:
        H_s, W_s = s.shape[:2]
        for y in range(H_s):
            for x in range(W_s):
                r, g, b, a = s[y, x]
                if a < ALPHA_THRESHOLD:
                    atlas_bytes.append(0)
                else:
                    pix = np.array([r, g, b], dtype=np.int32)
                    diffs = pal_rgb_arr - pix
                    dist2 = (diffs * diffs).sum(axis=1)
                    idx = int(np.argmin(dist2)) + 1   # 1-based (0 = transparent)
                    atlas_bytes.append(idx)
    expected = N_COLORS * N_FRAMES * CELL * CELL
    assert len(atlas_bytes) == expected, f'len={len(atlas_bytes)}, expected {expected}'
    total_kb = len(atlas_bytes) / 1024
    n_pages = (len(atlas_bytes) + PAGE_BYTES - 1) // PAGE_BYTES
    print(f'Atlas size: {len(atlas_bytes)} bytes = {total_kb:.1f} KB, {n_pages} SPG pages')

    # Split into 16K SPG pages
    for i in range(n_pages):
        chunk = atlas_bytes[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        # pad to 16K
        chunk += bytes(PAGE_BYTES - len(chunk))
        path = OUT_DIR / f'balls_atlas_paletted_p{i:02d}.bin'
        with open(path, 'wb') as f:
            f.write(chunk)
    print(f'Wrote {n_pages} pages')

    # Preview: rebuild first row (6 balls, frame 0) to RGB and save
    preview = Image.new('RGBA', (N_COLORS * CELL, CELL), (0, 0, 0, 0))
    # Build the inverse palette table (idx → RGBA)
    pal_lookup = [(0, 0, 0, 0)]
    for i in range(255):
        r = pal_rgb_flat[i*3]
        g = pal_rgb_flat[i*3 + 1]
        b = pal_rgb_flat[i*3 + 2]
        pal_lookup.append((r, g, b, 255))
    for ci in range(N_COLORS):
        sprite_idx = ci * N_FRAMES + 0
        offset_bytes = sprite_idx * CELL * CELL
        pixel_data = atlas_bytes[offset_bytes:offset_bytes + CELL * CELL]
        sprite_img = Image.new('RGBA', (CELL, CELL), (0, 0, 0, 0))
        for y in range(CELL):
            for x in range(CELL):
                idx = pixel_data[y * CELL + x]
                sprite_img.putpixel((x, y), pal_lookup[idx])
        preview.paste(sprite_img, (ci * CELL, 0))
    preview.resize((preview.width * 4, preview.height * 4), Image.NEAREST).save(ROOT / '_balls_paletted_preview.png')
    print('Preview: _balls_paletted_preview.png')

if __name__ == '__main__':
    main()
