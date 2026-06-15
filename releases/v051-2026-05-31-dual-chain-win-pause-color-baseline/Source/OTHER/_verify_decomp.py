#!/usr/bin/env python3
"""Визуализировать c0/c1/L2 plane из bg_dxt_decomp.bin для sanity-check."""
import os, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
TEMP_DIR = PROJECT_ROOT
W, H = 640, 480
BW, BH = W // 4, H // 4

with open(os.path.join(CONVERTED, 'bg_dxt_decomp.bin'), 'rb') as f:
    data = f.read()

c0 = data[0:38400]
c1 = data[38400:76800]
l2 = data[76800:153600]

def rgb565_plane_to_img(buf, w, h):
    img = Image.new('RGB', (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            off = (y * w + x) * 2
            v = struct.unpack('<H', buf[off:off+2])[0]
            r = ((v >> 11) & 0x1F) << 3
            g = ((v >> 5) & 0x3F) << 2
            b = (v & 0x1F) << 3
            px[x, y] = (r, g, b)
    return img

def l2_plane_to_img(buf, w, h):
    img = Image.new('L', (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            byte_off = y * (w // 4) + (x >> 2)
            bit_off = (3 - (x & 3)) * 2     # MSB-first
            idx = (buf[byte_off] >> bit_off) & 3
            px[x, y] = idx * 85
    return img

rgb565_plane_to_img(c0, BW, BH).save(os.path.join(TEMP_DIR, '_decomp_c0.png'))
rgb565_plane_to_img(c1, BW, BH).save(os.path.join(TEMP_DIR, '_decomp_c1.png'))
l2_plane_to_img(l2, W, H).save(os.path.join(TEMP_DIR, '_decomp_l2.png'))
print('saved _decomp_c0.png, _decomp_c1.png, _decomp_l2.png')
