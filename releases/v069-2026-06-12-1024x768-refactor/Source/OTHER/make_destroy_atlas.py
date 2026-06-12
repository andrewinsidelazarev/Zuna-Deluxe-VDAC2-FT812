#!/usr/bin/env python3
"""Build FT812 ARGB4 atlas for the MATCH-3 ball-destroy animation.

Source: Zuma-Deluxe-HD-ref/content/images/gameobjects.png — HD-ref animBallDestroy
(ResourceStore.c): irect_t rectBallDestroy = { 395, 0, 105, 120 }, 13 кадров.
Это серо-белая «осыпь» (шар рассыпается) — штатный эффект уничтожения шаров
при match-3. ОРАНЖЕВЫЙ взрыв (animExplosion 528,0,100,130) — ОТДЕЛЬНАЯ анимация
ТОЛЬКО для победного экрана, см. make_win_explosion_atlas.py.

13 * 48 * 48 * 2 = 59904 байт = 4 страницы (#1C..#1F, RAM_G DESTROY_RAMG_ADDR).
"""
import os
import struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CONVERTED = os.path.join(PROJECT_ROOT, "Graphics", "Converted")
PAGE_SZ = 16384

SRC = r"C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\content\images\gameobjects.png"
if not os.path.exists(SRC):
    SRC = os.path.join(PROJECT_ROOT, "Graphics", "Original", "gameobjects.png")
if not os.path.exists(SRC):
    SRC = r"C:\z80\zuma\_gameobjects_hd.png"

# HD-ref animBallDestroy: rect (395,0,105,120), 13 кадров вертикально.
SRC_X, SRC_Y = 395, 0
SRC_W, SRC_H = 105, 120
SRC_FRAMES = 13
DST_FRAMES = 13
DST_W = DST_H = 48
PAGE_COUNT = 4


def to_argb4_le(im):
    out = bytearray()
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            v = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            out += struct.pack("<H", v)
    return out


def main():
    os.makedirs(CONVERTED, exist_ok=True)
    sheet = Image.open(SRC).convert("RGBA")

    atlas = Image.new("RGBA", (DST_W, DST_H * DST_FRAMES), (0, 0, 0, 0))
    preview = Image.new("RGBA", (DST_W * DST_FRAMES, DST_H), (0, 0, 0, 0))
    for i in range(SRC_FRAMES):
        crop = sheet.crop((
            SRC_X, SRC_Y + i * SRC_H,
            SRC_X + SRC_W, SRC_Y + (i + 1) * SRC_H,
        ))
        frame = crop.resize((DST_W, DST_H), Image.Resampling.LANCZOS)
        atlas.alpha_composite(frame, (0, i * DST_H))
        preview.alpha_composite(frame, (i * DST_W, 0))

    blob = to_argb4_le(atlas)
    if len(blob) > PAGE_SZ * PAGE_COUNT:
        raise RuntimeError(f"destroy atlas exceeds {PAGE_COUNT} pages: {len(blob)} bytes")
    with open(os.path.join(CONVERTED, "destroy_atlas.bin"), "wb") as f:
        f.write(blob)

    for page in range(PAGE_COUNT):
        chunk = blob[page * PAGE_SZ:(page + 1) * PAGE_SZ]
        chunk += b"\x00" * (PAGE_SZ - len(chunk))
        with open(os.path.join(CONVERTED, f"destroy_atlas_p{page:02d}.bin"), "wb") as f:
            f.write(chunk)

    preview.resize((DST_W * DST_FRAMES * 4, DST_H * 4), Image.Resampling.NEAREST).save(
        os.path.join(PROJECT_ROOT, "_destroy_atlas_preview.png")
    )
    print(f"wrote destroy_atlas.bin: {len(blob)} bytes, pages={PAGE_COUNT}, frames={SRC_FRAMES}")


if __name__ == "__main__":
    main()
