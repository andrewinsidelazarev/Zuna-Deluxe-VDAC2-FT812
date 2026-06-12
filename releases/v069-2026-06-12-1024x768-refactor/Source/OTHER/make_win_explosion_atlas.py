#!/usr/bin/env python3
"""Build FT812 ARGB4 atlas for the WIN-state ORANGE explosion (HD-ref animExplosion).

Source: Zuma-Deluxe-HD-ref/content/images/gameobjects.png — HD-ref animExplosion
(ResourceStore.c): irect_t rectExplosion = { 528, 0, 100, 130 }, 17 кадров.
Оранжевый огненный взрыв. Используется ТОЛЬКО на победном экране
(ZL_DrawWinExplosions). Match-3 уничтожение шаров — серый animBallDestroy,
см. make_destroy_atlas.py (отдельный атлас/handle/RAM_G).

Кадр i = (528, i*130, 100, 130). Квадрат-кроп 100x100 (центр 130-кадра,
блоб взрыва ~93px центрирован) → resize 48x48. Шар 32px → спрайт 48 = 1.5x.
17 * 48 * 48 * 2 = 78336 байт = 5 страниц.

FT812 RAM_G = ровно 1 МБ. WINEXP_RAMG_ADDR переиспользует BALLS_RAMG_ADDR
(#050000): атлас дозаливается на входе в WIN, когда шары уже исчезли.
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

# HD-ref animExplosion: rect (528,0,100,130), 17 кадров.
SRC_X, SRC_Y = 528, 0
SRC_W, SRC_H = 100, 130
SRC_FRAMES = 17
CROP = 100
CROP_Y_OFF = (SRC_H - CROP) // 2          # 15: центрируем 100x100 в 130-высоком кадре
DST_W = DST_H = 48
PAGE_COUNT = 5


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

    atlas = Image.new("RGBA", (DST_W, DST_H * SRC_FRAMES), (0, 0, 0, 0))
    preview = Image.new("RGBA", (DST_W * SRC_FRAMES, DST_H), (0, 0, 0, 0))
    for i in range(SRC_FRAMES):
        fx = SRC_X
        fy = SRC_Y + i * SRC_H + CROP_Y_OFF
        crop = sheet.crop((fx, fy, fx + CROP, fy + CROP))
        frame = crop.resize((DST_W, DST_H), Image.Resampling.LANCZOS)
        atlas.alpha_composite(frame, (0, i * DST_H))
        preview.alpha_composite(frame, (i * DST_W, 0))

    blob = to_argb4_le(atlas)
    if len(blob) > PAGE_SZ * PAGE_COUNT:
        raise RuntimeError(f"win explosion atlas exceeds {PAGE_COUNT} pages: {len(blob)} bytes")

    for page in range(PAGE_COUNT):
        chunk = blob[page * PAGE_SZ:(page + 1) * PAGE_SZ]
        chunk += b"\x00" * (PAGE_SZ - len(chunk))
        with open(os.path.join(CONVERTED, f"winexp_p{page:02d}.bin"), "wb") as f:
            f.write(chunk)

    preview.resize((DST_W * SRC_FRAMES * 4, DST_H * 4), Image.Resampling.NEAREST).save(
        os.path.join(PROJECT_ROOT, "_winexp_atlas_preview.png")
    )
    print(f"wrote winexp atlas: {len(blob)} bytes, pages={PAGE_COUNT}, frames={SRC_FRAMES}")


if __name__ == "__main__":
    main()
