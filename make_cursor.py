#!/usr/bin/env python3
"""make_cursor.py — single-sprite cursor (arrow1.png) с белой заливкой внутри outline.

arrow1.png — чёрный outline стрелки (Windows pointer-style), внутри transparent.
Алгоритм:
  1. Read RGBA, tight-crop alpha bbox.
  2. Outline = alpha >= 128.
  3. Flood-fill from 4 corners — выделяет внешнюю transparent зону.
  4. Внутренние transparent пиксели (НЕ outline ∧ НЕ внешние) → залить (255,255,255,255).
  5. Острие = opaque pixel ближайший к top-left углу bbox.
  6. Resize до CURSOR_W×CURSOR_H, recompute tip.
  7. Save cursor.bin (ARGB4 LE) + preview + debug overlay.
"""
import os, struct
from collections import deque
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics', 'arrow1.png')

CURSOR_W = 24
CURSOR_H = 24
PAGE_SZ  = 16384

ALPHA_OUTLINE = 128                                     # treat as outline
ALPHA_TIP     = 200                                     # strong opacity для tip detection


def to_argb4_le(im):
    out = bytearray()
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            v = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            out += struct.pack('<H', v)
    return out


sheet = Image.open(SRC).convert('RGBA')
print(f'arrow1.png: {sheet.size}')

bbox = sheet.getbbox()
arrow = sheet.crop(bbox).copy()                         # mutable copy
w, h = arrow.size
print(f'tight-crop: {w}x{h} (bbox {bbox})')

px = arrow.load()

# Outline mask.
outline = [[px[x, y][3] >= ALPHA_OUTLINE for x in range(w)] for y in range(h)]

# Flood-fill from 4 corners → external transparent mask.
external = [[False] * w for _ in range(h)]
q = deque()
for cx, cy in [(0, 0), (w-1, 0), (0, h-1), (w-1, h-1)]:
    if not outline[cy][cx] and not external[cy][cx]:
        external[cy][cx] = True
        q.append((cx, cy))
while q:
    x, y = q.popleft()
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < w and 0 <= ny < h and not outline[ny][nx] and not external[ny][nx]:
            external[ny][nx] = True
            q.append((nx, ny))

# Заливка внутренних transparent пикселей белым.
filled = 0
for y in range(h):
    for x in range(w):
        if not outline[y][x] and not external[y][x]:
            px[x, y] = (255, 255, 255, 255)
            filled += 1
print(f'filled inside (white): {filled} pixels')

# Острие = opaque pixel ближайший к top-left углу (0, 0).
best, best_score = None, None
for y in range(h):
    for x in range(w):
        if px[x, y][3] >= ALPHA_TIP:
            score = x * x + y * y
            if best_score is None or score < best_score:
                best_score, best = score, (x, y)
tip_pre = best
print(f'tip in pre-resize sprite: {tip_pre}')

# Debug overlay (pre-resize, downscaled для просмотра).
debug = arrow.copy()
dpx = debug.load()
for dy_off in range(-12, 13):
    for dx_off in range(-12, 13):
        if dx_off*dx_off + dy_off*dy_off <= 144:
            xx, yy = tip_pre[0] + dx_off, tip_pre[1] + dy_off
            if 0 <= xx < w and 0 <= yy < h:
                dpx[xx, yy] = (255, 0, 0, 255)
debug.thumbnail((400, 400), Image.LANCZOS)
debug.save(os.path.join(HERE, 'cursor_debug.png'))

# Resize.
arrow_resized = arrow.resize((CURSOR_W, CURSOR_H), Image.LANCZOS)
tip_x = round(tip_pre[0] * CURSOR_W / w)
tip_y = round(tip_pre[1] * CURSOR_H / h)
if tip_x >= CURSOR_W: tip_x = CURSOR_W - 1
if tip_y >= CURSOR_H: tip_y = CURSOR_H - 1
print(f'tip in resized sprite: ({tip_x}, {tip_y})')

# Save preview PNG.
arrow_resized.save(os.path.join(HERE, 'cursor.png'))

# ARGB4 LE bytes + page.
blob = to_argb4_le(arrow_resized)
assert len(blob) == CURSOR_W * CURSOR_H * 2
blob_padded = blob + b'\x00' * (PAGE_SZ - len(blob))
with open(os.path.join(HERE, 'cursor_p00.bin'), 'wb') as f:
    f.write(blob_padded)
print(f'cursor_p00.bin: {len(blob)} real + {PAGE_SZ - len(blob)} padding = {PAGE_SZ}')

print()
print(f'CURSOR_W = {CURSOR_W}, CURSOR_H = {CURSOR_H}')
print(f'CURSOR_TIP_X = {tip_x}, CURSOR_TIP_Y = {tip_y}')
