#!/usr/bin/env python3
"""balls_atlas.bin — 6 цветов × 8 native rolling frames = 48 cells (56×56 ARGB4)
для FT812 BITMAP_HANDLE 0.

Источник: spritesheet 192×1632 RGBA из
  Desktop\\Zuma Deluxe\\graphics\\Zuma Deluxe - Gameplay - Balls.png

Spritesheet: 6 колонок (один цвет) × 51 ряд анимации (32×32 каждая ячейка).
Берём первые 8 рядов как rolling-cycle (катящийся шар вокруг своей оси).

Frame-кадры — это «1-я ось вращения» (rolling). 2-я ось (поворот по тангенсу
трека) делается на лету через FT812 cmd_rotate(tangent) — НЕ запекается в atlas.

56×56 cell с 8-px transparent padding вокруг 40×40 ball — нужен чтобы при
hardware tangent-rotate ball circle не клипалась BITMAP_SIZE rect'ом
(rotated 40-diameter circle вписывается в 56×56 c запасом).

Layout: вертикальный, stride 56*2 = 112 байт/line, height 56/cell.
cell_idx = color * 8 + frame.

Memory: 48 × 56×56 × 2 = 301 056 байт ≈ 19 spgbld-pages по 16 384.
Pages 0x2D..0x3F (45..63).
"""
import os, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe',
                    'graphics', 'Zuma Deluxe - Gameplay - Balls.png')

CELL_SRC = 32                                     # native classic 640×480 ball
CELL_BALL = 32                                    # видимый диаметр = native (без upscale)
CELL_DST = 32                                     # ячейка = native (без padding для rotation —
                                                  # шары classic не вращаются по tangent визуально)
PAD = 0
N_COLORS = 6
N_FRAMES = 16                                     # 16 phases sparkle — smooth classic feel
PAGE_SZ  = 16384
START_PAGE = 0x2D

sheet = Image.open(SRC).convert('RGBA')
assert sheet.size[0] == CELL_SRC * N_COLORS, f'unexpected width {sheet.size[0]}'

total_cells = N_COLORS * N_FRAMES
atlas = Image.new('RGBA', (CELL_DST, CELL_DST * total_cells), (0, 0, 0, 0))

# Spritesheet 51 rows TOTAL, но color 0 (blue) имеет valid frames только 0..46 (47 frames).
# Остальные colors имеют 50-51 valid. Берём 47 как common cycle для всех colors → consistent
# rolling animation без empty cells (которые вызывали flicker синих шаров).
SRC_TOTAL_ROWS = 47
SRC_ROW_INDICES = [round(i * SRC_TOTAL_ROWS / N_FRAMES) for i in range(N_FRAMES)]
# 16 phases = [0, 3, 6, 9, 12, 15, 18, 21, 24, 26, 29, 32, 35, 38, 41, 44]
for color in range(N_COLORS):
    for f in range(N_FRAMES):
        src_y = SRC_ROW_INDICES[f] * CELL_SRC
        src_box = (color * CELL_SRC, src_y, (color + 1) * CELL_SRC, src_y + CELL_SRC)
        ball_src = sheet.crop(src_box)
        # 32×32 → 40×40 (LANCZOS upscale)
        ball = ball_src.resize((CELL_BALL, CELL_BALL), Image.LANCZOS)
        # Пасте в центр 56×56 cell с alpha mask
        cell = Image.new('RGBA', (CELL_DST, CELL_DST), (0, 0, 0, 0))
        cell.paste(ball, (PAD, PAD), ball)
        cell_idx = color * N_FRAMES + f
        atlas.paste(cell, (0, cell_idx * CELL_DST))

# ARGB4 little-endian: bits 15..12=A, 11..8=R, 7..4=G, 3..0=B
out = bytearray()
px = atlas.load()
for y in range(atlas.size[1]):
    for x in range(atlas.size[0]):
        r, g, b, a = px[x, y]
        v = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        out += struct.pack('<H', v)

expected = CELL_DST * CELL_DST * total_cells * 2
assert len(out) == expected, f'size mismatch: {len(out)} vs {expected}'

with open(os.path.join(HERE, 'balls_atlas.bin'), 'wb') as f:
    f.write(out)

n_pages = (len(out) + PAGE_SZ - 1) // PAGE_SZ
for i in range(n_pages):
    chunk = bytes(out[i * PAGE_SZ : (i + 1) * PAGE_SZ])
    if len(chunk) < PAGE_SZ:
        chunk += b'\x00' * (PAGE_SZ - len(chunk))
    with open(os.path.join(HERE, f'balls_atlas_p{i:02d}.bin'), 'wb') as f:
        f.write(chunk)

print(f'wrote balls_atlas.bin: {len(out)} bytes, {n_pages} pages')
print(f'  total cells = {total_cells} (6 colors × 8 frames)')
print(f'  cell size = {CELL_DST}×{CELL_DST}, ball {CELL_BALL}×{CELL_BALL} centered')
print('\n# spgbld_vdac2.ini block lines:')
for i in range(n_pages):
    pg = START_PAGE + i
    print(f'Block = #0000, #{pg:02X}, balls_atlas_p{i:02d}.bin')

atlas.save(os.path.join(HERE, '_balls_atlas_preview.png'))
