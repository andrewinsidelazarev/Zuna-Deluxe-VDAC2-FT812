#!/usr/bin/env python3
"""track_640.bin — трек уровня для FT812-рендера в 640×480.

Источник: HD .dat трекер из
  C:\\Users\\Администратор\\Desktop\\Zuma Deluxe\\graphics\\levels-HD\\<name>\\<name>.dat
Формат CURV (parse_zumahd_dat.py): float startX/Y + N×(t1,t2,dX,dY) c шагом
dX/100, dY/100. Координаты уже в native 640×480 пространстве — никакого
scale не нужно.

Уровень → имя графики (см. make_bg_level01.py LEVEL_ORDER).

Y НЕ clamp'им к 0: оригинал имеет y<0 в pre-spawn зоне над экраном,
шар плавно заезжает сверху. Track encodes signed sword.

Формат track_640.bin (5 байт на sample = X, Y, tangent angle):
  word LE : N (количество семплов)
  N × 5 байт: X (sword), Y (sword), tangent (byte 0..255 = 0..360°)

Tangent = atan2(dy, dx) в окне ±4 sample, нормализован к 8 битам
(256 = full circle). Используется в asm для cmd_rotate(tangent*256)
при рендере шара — сприт ориентируется по local tangent трека.

При N=2762: 2 + 2762*5 = 13812 байт (помещается в одну 16 KB страницу).

Использование:  python make_track_640.py [level_number=1]
"""
import math
import os, struct, sys
from pathlib import Path

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
LEVELS_HD = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe',
                         'graphics', 'levels-HD')


def parse_dat(path):
    data = Path(path).read_bytes()
    o = 0x10
    count1 = struct.unpack_from('<i', data, o)[0]
    o += 4 + count1 * 10
    curve_len = struct.unpack_from('<i', data, o)[0]
    o += 4
    x = struct.unpack_from('<f', data, o)[0]; o += 4
    y = struct.unpack_from('<f', data, o)[0]; o += 4
    pts = [(x, y)]
    for _ in range(curve_len):
        if o + 4 > len(data):
            break
        dx = struct.unpack_from('<b', data, o + 2)[0]
        dy = struct.unpack_from('<b', data, o + 3)[0]
        o += 4
        x += dx / 100.0
        y += dy / 100.0
        pts.append((x, y))
    return pts


level = int(sys.argv[1]) if len(sys.argv) > 1 else 1
graphics_name = LEVEL_ORDER[level - 1]
src = os.path.join(LEVELS_HD, graphics_name, f'{graphics_name}.dat')

raw = parse_dat(src)
# Resample на uniform 1.0 px steps по arc length (linear interpolation между
# HD samples). Иначе round-to-int на наклонных сегментах даёт sqrt(2)≈1.4
# distance, а на сегментах с малым delta — distance=0 (duplicates).
# Применённый паттерн из VDC TS-Conf (2026-05-15).
STEP = 1.0
cum = [0.0]
for i in range(1, len(raw)):
    dx = raw[i][0] - raw[i-1][0]
    dy = raw[i][1] - raw[i-1][1]
    cum.append(cum[-1] + math.hypot(dx, dy))
total_len = cum[-1]
points = []
src_i = 0
n_out = int(total_len / STEP) + 1
for k in range(n_out):
    target = k * STEP
    while src_i < len(raw) - 2 and cum[src_i + 1] < target:
        src_i += 1
    seg = cum[src_i + 1] - cum[src_i]
    t = (target - cum[src_i]) / seg if seg > 0 else 0.0
    x = raw[src_i][0] + t * (raw[src_i + 1][0] - raw[src_i][0])
    y = raw[src_i][1] + t * (raw[src_i + 1][1] - raw[src_i][1])
    points.append((int(round(x)), int(round(y))))

# Tangent precompute: для каждого sample считаем направление трека по
# скользящему окну ±WINDOW samples. atan2(dy, dx) даёт угол в радианах
# -π..+π, нормализуем к 0..255 (256 = full circle).
# WINDOW=8 даёт базовое сглаживание направления на крутых поворотах.
WINDOW = 8
SMOOTH_WINDOW = 5


def smooth_tangents_wrap(values, window=SMOOTH_WINDOW):
    """Wrap-aware moving average для 0..255 углов."""
    if window <= 1 or not values:
        return values[:]
    half = window // 2
    unwrapped = [float(values[0])]
    for value in values[1:]:
        prev = unwrapped[-1]
        candidate = float(value)
        while candidate - prev > 128.0:
            candidate -= 256.0
        while candidate - prev < -128.0:
            candidate += 256.0
        unwrapped.append(candidate)

    smoothed = []
    n_values = len(unwrapped)
    for i in range(n_values):
        lo = max(0, i - half)
        hi = min(n_values, i + half + 1)
        avg = sum(unwrapped[lo:hi]) / (hi - lo)
        smoothed.append(int(round(avg)) & 0xFF)
    return smoothed


n = len(points)
tangents = []
for i in range(n):
    j = max(0, i - WINDOW)
    k = min(n - 1, i + WINDOW)
    dx = points[k][0] - points[j][0]
    dy = points[k][1] - points[j][1]
    if dx == 0 and dy == 0:
        a8 = 0
    else:
        a = math.atan2(dy, dx)                          # -π..+π
        a8 = int(round((a / (2 * math.pi)) * 256)) & 0xFF
    tangents.append(a8)
tangents = smooth_tangents_wrap(tangents)

out = bytearray()
out += struct.pack('<H', n)
for (x, y), tan in zip(points, tangents):
    out += struct.pack('<hhB', x, y, tan)

with open(os.path.join(CONVERTED, 'track_640.bin'), 'wb') as f:
    f.write(out)

xs = [p[0] for p in points]
ys = [p[1] for p in points]
print(f'level {level} = "{graphics_name}"')
print(f'samples={len(points)} X=[{min(xs)}..{max(xs)}] Y=[{min(ys)}..{max(ys)}] bytes={len(out)}')
print(f'tangent window={WINDOW}, smooth_window={SMOOTH_WINDOW}')
