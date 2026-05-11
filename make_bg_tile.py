#!/usr/bin/env python3
"""Генератор тайла фона 64×64 в RGB565 для FT812 BITMAP_REPEAT.

Простая stone-like текстура: тёмно-серая основа + 4 диагональные полосы для
визуальной структуры (видно что фон не однородный + видна сетка тайлов).
"""
import struct, os, math

W, H = 64, 64

def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)

out = bytearray()
for y in range(H):
    for x in range(W):
        # Контрастный тестовый паттерн: красная рамка тайла + цветные
        # квадранты 32×32, чтобы по экрану была явная 64×64 сетка.
        if x == 0 or y == 0:                             # левая/верхняя кромка
            r, g, b = 200, 0, 0                          # ярко-красная
        elif x == W - 1 or y == H - 1:                   # правая/нижняя кромка
            r, g, b = 80, 0, 0                           # тёмно-красная
        elif x < 32 and y < 32:
            r, g, b = 40, 60, 90                         # верх-лево синий
        elif x >= 32 and y < 32:
            r, g, b = 90, 60, 40                         # верх-право жёлтый
        elif x < 32 and y >= 32:
            r, g, b = 60, 90, 40                         # низ-лево зелёный
        else:
            r, g, b = 90, 40, 80                         # низ-право пурпурный
        out += struct.pack('<H', rgb565(min(r, 255), min(g, 255), min(b, 255)))

dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bg_tile_64.bin')
with open(dst, 'wb') as f:
    f.write(out)
print(f'wrote bg_tile_64.bin: {len(out)} bytes ({W}x{H} RGB565)')
