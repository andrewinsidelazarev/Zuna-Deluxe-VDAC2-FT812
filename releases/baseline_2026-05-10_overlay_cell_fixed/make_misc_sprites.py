#!/usr/bin/env python3
"""make_misc_sprites.py — frog body/plate/tongue/face-overlay + killzone.

Координаты подспрайтов в frog.png (324×648 RGBA) — 1:1 с
Zuma-Deluxe-HD/src/zuma/ResourceStore.c _MakeSprites/_MakeAnimations:
  SPR_FROG          (0,   0,   162, 162)  — body с лапами + открытым ртом
  SPR_FROG_TONGUE   (162, 0,   162, 162)  — язык (узкая полоска ~20×72 в центре кадра)
  SPR_FROG_PLATE    (162, 162, 162, 162)  — диск-подставка
  ANIM_FROG_BLINK0  (0,   162, 162, 162)  — frog без лап (face-overlay для tongue mask)

body / plate / face-overlay: 122×122 ARGB4 = 29768 байт = 2 spgbld pages.
tongue: tight-crop по alpha bbox + 4 px padding для bilinear → resize до
32×80 ARGB4 = 5120 байт = 1 page.  Это сохраняет 1 page RAM_G и tip
торчит на полную длину sprite за пределы face.
"""
import os, struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')
PAGE_SZ = 16384


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


def write_pages(name, blob, first_page):
    npages = (len(blob) + PAGE_SZ - 1) // PAGE_SZ
    blob_padded = blob + b'\x00' * (npages * PAGE_SZ - len(blob))
    for i in range(npages):
        chunk = blob_padded[i*PAGE_SZ:(i+1)*PAGE_SZ]
        with open(os.path.join(HERE, f'{name}_p{i:02d}.bin'), 'wb') as f:
            f.write(chunk)
    print(f'{name}: {len(blob)} bytes -> {npages} pages #{first_page:02X}..#{first_page+npages-1:02X}')


sheet = Image.open(os.path.join(GFX, 'frog.png')).convert('RGBA')

# ========================================================================
# 122×122 ARGB4 sprites — body, plate, tongue (full, no tight-crop как в Python).
# ========================================================================
W = H = 122
PARTS_122 = [
    # name              src_crop                  first_page
    ('frog',           (0,   0,   162, 162),      0x52),  # body+legs
    ('frog_plate',     (162, 162, 324, 324),      0x54),
    ('frog_tongue',    (162, 0,   324, 162),      0x56),  # full sprite, pivot (61,61)
    ('frog_overlay',   (0,   162, 162, 324),      0x58),  # full 122 = same scale as body, features alignment ✓
]
for name, crop, first_page in PARTS_122:
    region = sheet.crop(crop)
    canvas = region.resize((W, H), Image.LANCZOS)
    blob = to_argb4_le(canvas)
    assert len(blob) == W * H * 2 == 29768
    with open(os.path.join(HERE, f'{name}.bin'), 'wb') as f:
        f.write(blob)
    write_pages(name, blob, first_page)


# ========================================================================
# Killzone — 64×64 ARGB4 = 8192 байт, 1 page.  Перенесён в bg padding
# (page 0x16, RAM_G #04C000) чтобы освободить #0FD000 для face overlay.
# ========================================================================
KW = KH = 64
kz = Image.open(os.path.join(GFX, 'killzone-64-64.png')).convert('RGBA')
if kz.size != (KW, KH):
    kz = kz.resize((KW, KH), Image.LANCZOS)
kz_blob = to_argb4_le(kz)
assert len(kz_blob) == KW * KH * 2 == 8192
with open(os.path.join(HERE, 'killzone.bin'), 'wb') as f:
    f.write(kz_blob)
write_pages('killzone', kz_blob, 0x16)
