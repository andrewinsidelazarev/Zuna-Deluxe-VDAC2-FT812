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
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
TEMP_DIR = PROJECT_ROOT
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')
HD_GAMEOBJECTS = os.path.join(PROJECT_ROOT, 'Graphics', 'Original', 'gameobjects.png')
if not os.path.exists(HD_GAMEOBJECTS):
    HD_GAMEOBJECTS = r'C:\z80\zuma\_gameobjects_hd.png'
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


def clear_red_guides(im):
    im = im.copy()
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a and r > 35 and g < 30 and b < 30:
                px[x, y] = (0, 0, 0, 0)
    return im


def write_pages(name, blob, first_page):
    npages = (len(blob) + PAGE_SZ - 1) // PAGE_SZ
    blob_padded = blob + b'\x00' * (npages * PAGE_SZ - len(blob))
    for i in range(npages):
        chunk = blob_padded[i*PAGE_SZ:(i+1)*PAGE_SZ]
        with open(os.path.join(CONVERTED, f'{name}_p{i:02d}.bin'), 'wb') as f:
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
    with open(os.path.join(CONVERTED, f'{name}.bin'), 'wb') as f:
        f.write(blob)
    write_pages(name, blob, first_page)


# ========================================================================
# Killzone — 64×64 ARGB4 = 8192 байт, 1 page.  Перенесён в bg padding
# (page 0x16, RAM_G #04C000) чтобы освободить #0FD000 для face overlay.
# ========================================================================
KW = KH = 64
KZ_FRAMES = 12
KZ_HOLE_X = 629
KZ_HOLE_Y = 0
KZ_SRC_X = 629
KZ_SRC_Y = 132
KZ_SRC_W = 132
KZ_SRC_H = 132
KZ_TARGET_MAX = 60

objects = clear_red_guides(Image.open(HD_GAMEOBJECTS).convert('RGBA'))
hole = objects.crop((KZ_HOLE_X, KZ_HOLE_Y, KZ_HOLE_X + KZ_SRC_W, KZ_HOLE_Y + KZ_SRC_H))
hole = hole.resize((KW, KH), Image.LANCZOS)
hole_alpha = Image.new('RGBA', (KW, KH), (0, 0, 0, 0))
hole_src = hole.load()
hole_dst = hole_alpha.load()
for y in range(KH):
    for x in range(KW):
        r, g, b, a = hole_src[x, y]
        if a and max(r, g, b) < 58:
            hole_dst[x, y] = (0, 0, 0, a)
src_frames = [
    objects.crop((KZ_SRC_X, KZ_SRC_Y + i * KZ_SRC_H,
                  KZ_SRC_X + KZ_SRC_W, KZ_SRC_Y + (i + 1) * KZ_SRC_H))
    for i in range(KZ_FRAMES)
]
bboxes = [frame.split()[3].getbbox() for frame in src_frames]
max_dim = max(max(box[2] - box[0], box[3] - box[1]) for box in bboxes if box)

# Якорь — source center (66, 66). Раньше каждый кадр crop'ался по своему
# alpha-bbox + re-center в 64×64 → asymmetric кадры (frame 5: челюсть отколота
# до x=0 → bbox-center сдвинут влево на 15 → череп визуально съезжал вправо
# на ~9px относительно других кадров).  Теперь: единый scale всей 132×132,
# crop центра 64×64.  Source-center (66,66) точно ложится в (32,32) ячейки.
scale = KZ_TARGET_MAX / max_dim
SCALED = max(KW, int(round(KZ_SRC_W * scale)))

atlas = Image.new('RGBA', (KW, KH * KZ_FRAMES), (0, 0, 0, 0))
preview = Image.new('RGBA', (KW * KZ_FRAMES, KH), (0, 0, 0, 0))
atlas.alpha_composite(hole_alpha, (0, 0))
preview.alpha_composite(hole_alpha, (0, 0))
for i, frame in enumerate(src_frames):
    if i == 0:
        continue
    scaled = clear_red_guides(frame.resize((SCALED, SCALED), Image.LANCZOS))
    off = (SCALED - KW) // 2
    cropped = scaled.crop((off, off, off + KW, off + KH))
    atlas.alpha_composite(cropped, (0, i * KH))
    preview.alpha_composite(cropped, (i * KW, 0))

kz_blob = to_argb4_le(atlas)
assert len(kz_blob) == KW * KH * KZ_FRAMES * 2
with open(os.path.join(CONVERTED, 'killzone.bin'), 'wb') as f:
    f.write(kz_blob)
write_pages('killzone', kz_blob, 0x16)
preview.resize((KW * KZ_FRAMES * 2, KH * 2), Image.NEAREST).save(
    os.path.join(PROJECT_ROOT, '_killzone_preview.png'))
