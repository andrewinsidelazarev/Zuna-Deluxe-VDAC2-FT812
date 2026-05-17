#!/usr/bin/env python3
"""bg_level01.bin — фон уровня для FT812 (320×240 RGB565, hardware bilinear upscale до 640×480).

Источник: HD jpg из levels-HD/<name>/<name>.jpg (1280×720). Crop 4:3 → resize 320×240
LANCZOS, encode RGB565 LE.

Memory: 320×240×2 = 153 600 байт (vs 614 400 для full 640×480 RGB565 → 75% economy).
Render: matrix cmd_scale(0.5, 0.5) + BITMAP_SIZE 640×480 + FT_BILINEAR → smooth upscale.

Использование:  python make_bg_level01.py [level_number=1]

Выход:
  bg_level01.bin              — 153600 байт
  bg_level01_p00.bin..p09.bin — 10 страниц × 16384 (last padding)
"""
import os, struct, sys
from PIL import Image

LEVEL_ORDER = [
    'spiral', 'riverbed', 'targetglyph', 'tunnellevel', 'groovefest',
    'blackswirley', 'snakepit', 'serpents', 'longrange', 'tiltspiral',
    'underover', 'claw', 'triangle', 'inversespiral', 'loopy',
    'turnaround', 'squaresville', 'warshak', 'overunder', 'spaceinvaders',
    'coaster', 'space',
]

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
TEMP_DIR = PROJECT_ROOT
LEVELS_SRC = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe',
                          'graphics', 'levels')

W, H = 400, 300                                  # native res, render upscaled 1.6x до 640×480
PAGE_SZ = 16384
START_PAGE = 7

level = int(sys.argv[1]) if len(sys.argv) > 1 else 1
src = os.path.join(LEVELS_SRC, f'level_src_{level:02d}.png')

im = Image.open(src).convert('RGB')                # native 640×480
# 640×480 → 320×240 LANCZOS (для render-time bilinear upscale обратно до 640×480)
im = im.resize((W, H), Image.LANCZOS)

# RGB565 little-endian: bit 15..11=R, 10..5=G, 4..0=B.
out = bytearray()
px = im.load()
for y in range(H):
    for x in range(W):
        r, g, b = px[x, y]
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        out += struct.pack('<H', v)
assert len(out) == W * H * 2 == 240000

with open(os.path.join(CONVERTED, 'bg_level01.bin'), 'wb') as f:
    f.write(out)

n_pages = (len(out) + PAGE_SZ - 1) // PAGE_SZ
for i in range(n_pages):
    chunk = bytes(out[i * PAGE_SZ : (i + 1) * PAGE_SZ])
    if len(chunk) < PAGE_SZ:
        chunk += b'\x00' * (PAGE_SZ - len(chunk))
    with open(os.path.join(CONVERTED, f'bg_level01_p{i:02d}.bin'), 'wb') as f:
        f.write(chunk)

print(f'level {level}: {os.path.basename(src)}')
print(f'wrote bg_level01.bin: {len(out)} bytes ({W}x{H} RGB565), {n_pages} pages')
im.save(os.path.join(TEMP_DIR, '_bg_level01_preview.png'))
