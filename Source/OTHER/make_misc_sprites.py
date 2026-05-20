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
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CONVERTED = os.path.join(PROJECT_ROOT, 'Graphics', 'Converted')
TEMP_DIR = PROJECT_ROOT
GFX = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma Deluxe', 'graphics')
HD_GAMEOBJECTS = os.path.join(PROJECT_ROOT, 'Graphics', 'Original', 'gameobjects.png')
HD_REF_GAMEOBJECTS = os.path.join(os.path.expanduser('~'), 'Desktop', 'Zuma-Deluxe-HD-ref',
                                  'content', 'images', 'gameobjects.png')
if os.path.exists(HD_REF_GAMEOBJECTS):
    HD_GAMEOBJECTS = HD_REF_GAMEOBJECTS
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
# Killzone — 88×88 PALETTED4444. 88px matches the baked level-1 star bbox
# (~86×87 px) better than the previous 64×64 overlay. Palette is appended in
# the padding after the 12 cells, so the existing 6 upload pages stay enough.
# ========================================================================
KW = KH = 88
KZ_FRAMES = 12
KZ_HOLE_X = 629
KZ_HOLE_Y = 0
KZ_SRC_X = 629
KZ_SRC_Y = 132
KZ_SRC_W = 132
KZ_SRC_H = 132

objects = clear_red_guides(Image.open(HD_GAMEOBJECTS).convert('RGBA'))
hole_alpha = objects.crop((KZ_HOLE_X, KZ_HOLE_Y, KZ_HOLE_X + KZ_SRC_W, KZ_HOLE_Y + KZ_SRC_H))
hole_alpha = clear_red_guides(hole_alpha.resize((KW, KH), Image.LANCZOS))
src_frames = [
    objects.crop((KZ_SRC_X, KZ_SRC_Y + i * KZ_SRC_H,
                  KZ_SRC_X + KZ_SRC_W, KZ_SRC_Y + (i + 1) * KZ_SRC_H))
    for i in range(KZ_FRAMES)
]

atlas = Image.new('RGBA', (KW, KH * KZ_FRAMES), (0, 0, 0, 0))
preview = Image.new('RGBA', (KW * KZ_FRAMES, KH), (0, 0, 0, 0))
atlas.alpha_composite(hole_alpha, (0, 0))
preview.alpha_composite(hole_alpha, (0, 0))
for i, frame in enumerate(src_frames[:KZ_FRAMES - 1]):
    cropped = clear_red_guides(frame.resize((KW, KH), Image.LANCZOS))
    cell = i + 1
    atlas.alpha_composite(cropped, (0, cell * KH))
    preview.alpha_composite(cropped, (cell * KW, 0))

q = atlas.quantize(colors=255, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
raw_idx = np.array(q, dtype=np.uint8)
rgba = np.array(atlas, dtype=np.uint16)
alpha = rgba[:, :, 3]
indices = np.where(alpha > 0, raw_idx.astype(np.uint16) + 1, 0).astype(np.uint8)

palette = np.zeros((256, 4), dtype=np.uint8)
for qi in range(255):
    mask = (raw_idx == qi) & (alpha > 0)
    if not mask.any():
        continue
    avg = rgba[mask].mean(axis=0)
    palette[qi + 1] = np.clip(avg, 0, 255).astype(np.uint8)

pal_blob = bytearray()
for r, g, b, a in palette:
    word = (((int(a) >> 4) & 0xF) << 12) | (((int(r) >> 4) & 0xF) << 8) | \
           (((int(g) >> 4) & 0xF) << 4) | ((int(b) >> 4) & 0xF)
    pal_blob += struct.pack('<H', word)

kz_pixels = indices.tobytes()
assert len(kz_pixels) == KW * KH * KZ_FRAMES
kz_blob = kz_pixels + bytes(pal_blob)
assert len(kz_blob) <= 6 * PAGE_SZ
with open(os.path.join(CONVERTED, 'killzone.bin'), 'wb') as f:
    f.write(kz_blob)
write_pages('killzone', kz_blob, 0x16)
Image.fromarray(palette[indices].reshape(KH * KZ_FRAMES, KW, 4), 'RGBA').save(
    os.path.join(PROJECT_ROOT, '_killzone_paletted_preview_stack.png'))
preview.resize((KW * KZ_FRAMES * 2, KH * 2), Image.NEAREST).save(
    os.path.join(PROJECT_ROOT, '_killzone_preview.png'))
