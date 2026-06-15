#!/usr/bin/env python3
"""Hybrid balls: L8 alpha body (32 KB) + ARGB4 face overlay (64 KB) = 96 KB total.

Layer 1 (L8 = alpha mask FT812-style):
  Just the SPHERE shape — all body pixels alpha=255, anti-aliased edges fade out.
  Source: silver ball (col 4) — самый neutral, plain shape без насыщенных accents.
  Render с COLOR_RGB(body_color) → opaque colored circle.

Layer 2 (ARGB4 face overlay):
  Только face accents (Maya design). Body pixels = transparent.
  Source: blue ball (col 0) — body=blue, face accents=orange/yellow.
  Detection: pixels where (R - B) > 30 → "warm/orange" accent.
  Render с COLOR_RGB(255,255,255) → native accent colors preserved.

Result:
  - L8 body tinted to body_color for current ball
  - Face overlay draws Maya accents on top in original orange color
  - All 6 ball colors share одну and ту же face overlay (accent color =const orange)

Atlas layout:
  balls_l8_p00..p01.bin       (2 SPG pages = 32 KB)  alpha mask × 32 frames
  balls_face_p00..p03.bin     (4 SPG pages = 64 KB)  ARGB4 face × 32 frames
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

L8_SRC_COL = 4       # silver — for L8 alpha mask (neutral plain ball)
FACE_SRC_COL = 0     # blue — для face extraction (face accent = orange-on-blue)
FACE_R_MINUS_B = 30  # threshold: pixel is "face accent" if R - B > this

def to_argb4_bytes(arr):
    """RGBA H×W×4 → ARGB4 packed bytes (little-endian 16-bit per pixel)."""
    arr = arr.astype(np.uint16)
    a = (arr[..., 3] >> 4) & 0xF
    r = (arr[..., 0] >> 4) & 0xF
    g = (arr[..., 1] >> 4) & 0xF
    b = (arr[..., 2] >> 4) & 0xF
    out = (a << 12) | (r << 8) | (g << 4) | b
    return out.astype('<u2').tobytes()

def main():
    img = Image.open(SRC).convert('RGBA')
    arr = np.array(img)

    l8_atlas = bytearray()
    face_atlas = bytearray()

    face_pixel_total = 0

    for fi in range(N_FRAMES):
        # L8 body: silver ball, just alpha channel as L8 byte.
        silver = arr[fi*CELL:(fi+1)*CELL, L8_SRC_COL*CELL:(L8_SRC_COL+1)*CELL]
        l8 = np.clip(silver[..., 3], 0, 255).astype(np.uint8)
        l8_atlas += l8.tobytes()

        # Face overlay: blue ball, isolate orange accent pixels.
        blue = arr[fi*CELL:(fi+1)*CELL, FACE_SRC_COL*CELL:(FACE_SRC_COL+1)*CELL].copy()
        r = blue[..., 0].astype(np.int32)
        b = blue[..., 2].astype(np.int32)
        a = blue[..., 3].astype(np.int32)
        face_mask = ((r - b) > FACE_R_MINUS_B) & (a > 50)
        face_rgba = np.zeros_like(blue)
        face_rgba[face_mask] = blue[face_mask]
        face_atlas += to_argb4_bytes(face_rgba)
        face_pixel_total += int(face_mask.sum())

    print(f'L8 body atlas (silver alpha mask): {len(l8_atlas)} bytes ({len(l8_atlas)/1024:.1f} KB)')
    print(f'ARGB4 face overlay: {len(face_atlas)} bytes ({len(face_atlas)/1024:.1f} KB)')
    print(f'Face pixels total (across 32 frames): {face_pixel_total}')

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    pages_l8 = (len(l8_atlas) + PAGE_BYTES - 1) // PAGE_BYTES
    for i in range(pages_l8):
        chunk = l8_atlas[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        with open(OUT_DIR / f'balls_l8_p{i:02d}.bin', 'wb') as f:
            f.write(chunk)
    print(f'  → {pages_l8} pages balls_l8_p*.bin')

    pages_face = (len(face_atlas) + PAGE_BYTES - 1) // PAGE_BYTES
    for i in range(pages_face):
        chunk = face_atlas[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        with open(OUT_DIR / f'balls_face_p{i:02d}.bin', 'wb') as f:
            f.write(chunk)
    print(f'  → {pages_face} pages balls_face_p*.bin')

    # Preview composite: tint L8 with various colors + overlay face
    colors = [
        (50, 100, 240),    # blue
        (40, 220, 80),     # green
        (240, 50, 50),     # red
        (240, 220, 30),    # yellow
        (230, 80, 220),    # purple
        (200, 200, 200),   # silver
    ]
    preview = Image.new('RGBA', (CELL * 6, CELL), (0, 0, 0, 0))
    for ci, color in enumerate(colors):
        # Frame 0 only
        l8_data = l8_atlas[0:CELL*CELL]
        l8_img = Image.frombytes('L', (CELL, CELL), bytes(l8_data))
        # Tint L8 to body color (multiply)
        body = Image.new('RGBA', (CELL, CELL), (0, 0, 0, 0))
        body_arr = np.zeros((CELL, CELL, 4), dtype=np.uint8)
        body_arr[..., 0] = (np.array(l8_img) * color[0]) // 255
        body_arr[..., 1] = (np.array(l8_img) * color[1]) // 255
        body_arr[..., 2] = (np.array(l8_img) * color[2]) // 255
        body_arr[..., 3] = np.array(l8_img)   # alpha = L8 byte
        body = Image.fromarray(body_arr, 'RGBA')
        # Face overlay
        face_data = face_atlas[0:CELL*CELL*2]
        face_words = np.frombuffer(face_data, dtype='<u2').reshape(CELL, CELL)
        face_rgba = np.zeros((CELL, CELL, 4), dtype=np.uint8)
        face_rgba[..., 3] = ((face_words >> 12) & 0xF) * 17
        face_rgba[..., 0] = ((face_words >> 8)  & 0xF) * 17
        face_rgba[..., 1] = ((face_words >> 4)  & 0xF) * 17
        face_rgba[..., 2] = ( face_words        & 0xF) * 17
        face_img = Image.fromarray(face_rgba, 'RGBA')
        body.alpha_composite(face_img)
        preview.paste(body, (ci * CELL, 0))

    preview.resize((preview.width * 4, preview.height * 4), Image.NEAREST).save(ROOT / '_balls_hybrid_preview.png')
    print('Preview: _balls_hybrid_preview.png (6 colors с tint + face overlay)')

if __name__ == '__main__':
    main()
