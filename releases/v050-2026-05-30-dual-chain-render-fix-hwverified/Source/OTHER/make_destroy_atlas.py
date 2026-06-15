#!/usr/bin/env python3
"""Build FT812 ARGB4 atlas for match-3 destroy animation.

Source: Zuma-Deluxe-HD gameobjects.png, rectBallDestroy = (395, 0, 105, 120),
13 vertical frames. Runtime uses 7 64x64 cells and hardware ColorA fade.
"""
import os
import struct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CONVERTED = os.path.join(PROJECT_ROOT, "Graphics", "Converted")
PAGE_SZ = 16384

SRC = os.path.join(PROJECT_ROOT, "Graphics", "Original", "gameobjects.png")
if not os.path.exists(SRC):
    SRC = r"C:\z80\zuma\_gameobjects_hd.png"

SRC_X, SRC_Y = 395, 0
SRC_W, SRC_H = 105, 120
SRC_FRAMES = 13
DST_FRAMES = 7
DST_W = DST_H = 64


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
    indices = [round(i * (SRC_FRAMES - 1) / (DST_FRAMES - 1)) for i in range(DST_FRAMES)]

    atlas = Image.new("RGBA", (DST_W, DST_H * DST_FRAMES), (0, 0, 0, 0))
    preview = Image.new("RGBA", (DST_W * DST_FRAMES, DST_H), (0, 0, 0, 0))
    for out_idx, src_idx in enumerate(indices):
        crop = sheet.crop((
            SRC_X,
            SRC_Y + src_idx * SRC_H,
            SRC_X + SRC_W,
            SRC_Y + (src_idx + 1) * SRC_H,
        ))
        frame = crop.resize((DST_W, DST_H), Image.Resampling.LANCZOS)
        atlas.alpha_composite(frame, (0, out_idx * DST_H))
        preview.alpha_composite(frame, (out_idx * DST_W, 0))

    blob = to_argb4_le(atlas)
    with open(os.path.join(CONVERTED, "destroy_atlas.bin"), "wb") as f:
        f.write(blob)

    page_count = (len(blob) + PAGE_SZ - 1) // PAGE_SZ
    for page in range(page_count):
        chunk = blob[page * PAGE_SZ:(page + 1) * PAGE_SZ]
        chunk += b"\x00" * (PAGE_SZ - len(chunk))
        with open(os.path.join(CONVERTED, f"destroy_atlas_p{page:02d}.bin"), "wb") as f:
            f.write(chunk)

    preview.resize((DST_W * DST_FRAMES * 4, DST_H * 4), Image.Resampling.NEAREST).save(
        os.path.join(PROJECT_ROOT, "_destroy_atlas_preview.png")
    )
    print(f"wrote destroy_atlas.bin: {len(blob)} bytes, pages={page_count}, frames={indices}")


if __name__ == "__main__":
    main()
