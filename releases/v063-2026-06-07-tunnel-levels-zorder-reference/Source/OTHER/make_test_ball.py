#!/usr/bin/env python3
"""Генерация тестового шара 40×40 в формате RGB565 для FT812 RAM_G.

RGB565: 2 байта на пиксель, big-endian внутри 16-bit, формат:
  bit 15..11 = R (5 бит)
  bit 10..5  = G (6 бит)
  bit 4..0   = B (5 бит)
В RAM_G FT812 little-endian → low byte first, потом high.

Шар: радиальный градиент оранжевого с тёмной обводкой,
вне круга — пурпурный (видимый цвет «фона», чтобы по краю спрайта
было заметно границу bitmap'а на этапе отладки).
"""
import struct, os, math

W, H = 40, 40
R = 19          # видимый радиус шара (диаметр 38, 1 px зазор по краям)
CX, CY = 19.5, 19.5

def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

def lerp(a, b, t):
    return int(round(a + (b - a) * t))

out = bytearray()
for y in range(H):
    for x in range(W):
        dx = x - CX
        dy = y - CY
        d = math.sqrt(dx * dx + dy * dy)
        if d > R:
            # вне шара — magenta маркер (видна форма bitmap)
            color = rgb565(255, 0, 255)
        elif d > R - 2:
            # обводка — тёмно-коричневый
            color = rgb565(60, 30, 0)
        else:
            # внутри шара — radial gradient оранжевый → жёлтый к центру
            t = d / max(R - 2, 1)        # 0 центр, 1 край
            r = lerp(255, 220, t)
            g = lerp(220, 100, t)
            b = lerp(80,  20,  t)
            color = rgb565(r, g, b)
        out += struct.pack('<H', color)  # little-endian word

HERE = os.path.dirname(os.path.abspath(__file__))
CONVERTED = os.path.join(os.path.abspath(os.path.join(HERE, '..', '..')), 'Graphics', 'Converted')
dst = os.path.join(CONVERTED, 'test_ball_40.bin')
with open(dst, 'wb') as f:
    f.write(out)
print(f'wrote {dst}: {len(out)} bytes ({W}×{H}, RGB565)')
