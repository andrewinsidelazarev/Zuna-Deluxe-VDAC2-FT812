#!/usr/bin/env python3
"""bg_level01.bin — фон уровня для FT812 в ASTC 8×8 формате (эксперимент).

ВНИМАНИЕ: ASTC формально не поддерживается FT81x (его 5-bit format field
вмещает значения 0..31). Это пробный заход — проверяем, реализует ли Unreal x64
ASTC через backdoor / extension. Если фон чёрный/мусор — fallback на RGB565.

Источник: levels/level_src_NN.png 640×480.
Pipeline: PNG → astcenc-avx2 8x8 -medium → strip 16-byte ASTC header → raw blocks.

Размер: 640×480 ASTC 8x8 = (640/8)×(480/8)×16 = 4800×16 = 76800 байт.
5 spgbld pages × 16384 = 81920 байт (последняя — padding).

Использование:  python make_bg_level01_astc.py [level_number=1]
"""
import os, struct, subprocess, sys

LEVEL_ORDER = [
    'spiral', 'riverbed', 'targetglyph', 'tunnellevel', 'groovefest',
    'blackswirley', 'snakepit', 'serpents', 'longrange', 'tiltspiral',
    'underover', 'claw', 'triangle', 'inversespiral', 'loopy',
    'turnaround', 'squaresville', 'warshak', 'overunder', 'spaceinvaders',
    'coaster', 'space',
]

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'levels', 'Converted')
TEMP_DIR = PROJECT_ROOT
LEVELS_SRC = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe',
                          'graphics', 'levels')
ASTCENC = r'c:\z80\tsconf_project\exe\astcenc\bin\astcenc-avx2.exe'

W, H = 640, 480
BLOCK = '8x8'
QUALITY = '-medium'
PAGE_SZ = 16384

level = int(sys.argv[1]) if len(sys.argv) > 1 else 1
src_png = os.path.join(LEVELS_SRC, f'level_src_{level:02d}.png')
tmp_astc = os.path.join(CONVERTED, 'bg_level01_astc.astc')

# 1. Convert PNG → ASTC.
print(f'level {level}: {os.path.basename(src_png)}')
print(f'  encoding ASTC {BLOCK} {QUALITY}...')
subprocess.run([ASTCENC, '-cl', src_png, tmp_astc, BLOCK, QUALITY], check=True)

# 2. Strip 16-byte ASTC header.
with open(tmp_astc, 'rb') as f:
    astc_full = f.read()
header = astc_full[:16]
assert header[:4] == b'\x13\xab\xa1\x5c', f'bad ASTC magic: {header[:4].hex()}'
raw = astc_full[16:]
expected = (W // 8) * (H // 8) * 16
assert len(raw) == expected, f'size {len(raw)} != expected {expected}'

# 3. Write raw .bin + pages.
with open(os.path.join(CONVERTED, 'bg_level01.bin'), 'wb') as f:
    f.write(raw)

n_pages = (len(raw) + PAGE_SZ - 1) // PAGE_SZ
for i in range(n_pages):
    chunk = bytes(raw[i * PAGE_SZ : (i + 1) * PAGE_SZ])
    if len(chunk) < PAGE_SZ:
        chunk += b'\x00' * (PAGE_SZ - len(chunk))
    with open(os.path.join(CONVERTED, f'bg_level01_p{i:02d}.bin'), 'wb') as f:
        f.write(chunk)

print(f'wrote bg_level01.bin: {len(raw)} bytes (raw ASTC {W}×{H} {BLOCK}), {n_pages} pages')
