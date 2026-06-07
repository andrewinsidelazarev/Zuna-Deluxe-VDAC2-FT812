#!/usr/bin/env python3
"""Разложить DXT1 (549556_l2.bin, 640×480) в три плоскости для FT812 эмуляции:
  c0 plane: 160×120 RGB565       (38400 bytes)
  c1 plane: 160×120 RGB565       (38400 bytes)
  L2 plane: 640×480 2bpp index   (76800 bytes)
  → склейка c0|c1|L2 = 153600 bytes (ровно 10 spgbld pages × 16384, last padded).

FT_L2 packing: leftmost pixel in MSB (биты 7..6 = pixel x=0, биты 1..0 = pixel x=3).
DXT1 index packing: bits 0..1 = pixel (0,0), bits 30..31 = pixel (3,3).
"""
import struct, os

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
SRC  = os.path.join(CONVERTED, '549556_l2.bin')
W, H = 640, 480
BW, BH = W // 4, H // 4         # 160 × 120 blocks

with open(SRC, 'rb') as f:
    dxt = f.read()
assert len(dxt) == BW * BH * 8 == 153600, f'expected 153600, got {len(dxt)}'

c0_plane = bytearray()
c1_plane = bytearray()
l2_plane = bytearray(W // 4 * H)        # 76800 bytes, init to 0

for by in range(BH):
    for bx in range(BW):
        off = (by * BW + bx) * 8
        c0_plane += dxt[off:off+2]
        c1_plane += dxt[off+2:off+4]
        idx32 = struct.unpack('<I', dxt[off+4:off+8])[0]
        for py in range(4):
            for px in range(4):
                idx = (idx32 >> ((py * 4 + px) * 2)) & 3
                ix = bx * 4 + px
                iy = by * 4 + py
                byte_off = iy * (W // 4) + (ix >> 2)
                bit_off  = (3 - (ix & 3)) * 2     # MSB-first within byte
                l2_plane[byte_off] |= idx << bit_off

assert len(c0_plane) == 38400
assert len(c1_plane) == 38400
assert len(l2_plane) == 76800

merged = bytes(c0_plane) + bytes(c1_plane) + bytes(l2_plane)
assert len(merged) == 153600

# Сохранить flat (на всякий)
with open(os.path.join(CONVERTED, 'bg_dxt_decomp.bin'), 'wb') as f:
    f.write(merged)

# Сплит в 10 страниц по 16384 байт (last page padded zeros)
PAGE = 16384
n_pages = (len(merged) + PAGE - 1) // PAGE
for i in range(n_pages):
    chunk = merged[i * PAGE : (i + 1) * PAGE]
    if len(chunk) < PAGE:
        chunk = chunk + b'\x00' * (PAGE - len(chunk))
    with open(os.path.join(CONVERTED, f'bg_dxt_p{i:02d}.bin'), 'wb') as f:
        f.write(chunk)

print(f'OK: c0={len(c0_plane)} c1={len(c1_plane)} l2={len(l2_plane)} total={len(merged)}; {n_pages} pages')
