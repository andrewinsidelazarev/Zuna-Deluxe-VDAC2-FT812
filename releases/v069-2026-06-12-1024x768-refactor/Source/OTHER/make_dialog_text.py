#!/usr/bin/env python3
"""Render 3 dialog text strings into ARGB4 bitmaps using Cancun TTF.

Strings:
  '2 LIVES LEFT'  → text_dialog_2lives.bin
  '1 LIVES LEFT'  → text_dialog_1lives.bin
  'GAME OVER'     → text_dialog_gameover.bin

Output: ARGB4 LE 16bpp, padded to multiple of 4 bytes width (FT812 stride req).
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
FONT_PATH = Path(r'C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\content\fonts\ttf\Cancun Regular.ttf')
OUT = ROOT / 'Graphics' / 'Converted'
OUT.mkdir(parents=True, exist_ok=True)

# Cancun13 в HD-ref = TTF size 26 (см. ResourceStore.c:525). Это title-размер.
FONT_SIZE = 26

# Yellow-orange title цвет (как в screenshot)
TEXT_COLOR = (255, 220, 80, 255)
OUTLINE_COLOR = (60, 30, 0, 255)

STRINGS = [
    ('text_dialog_2lives',   '2 LIVES LEFT'),
    ('text_dialog_1lives',   '1 LIVES LEFT'),
    ('text_dialog_gameover', 'GAME OVER'),
]


def render_text(text: str) -> Image.Image:
    """Render text with outline. Returns RGBA tight-cropped."""
    font = ImageFont.truetype(str(FONT_PATH), FONT_SIZE)
    # Measure
    dummy = Image.new('RGBA', (1, 1), (0, 0, 0, 0))
    draw = ImageDraw.Draw(dummy)
    bbox = draw.textbbox((0, 0), text, font=font)
    pad = 4
    w = bbox[2] - bbox[0] + 2*pad
    h = bbox[3] - bbox[1] + 2*pad
    canvas = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    # Outline: 4 offsets
    ox, oy = pad - bbox[0], pad - bbox[1]
    for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]:
        d.text((ox+dx, oy+dy), text, font=font, fill=OUTLINE_COLOR)
    d.text((ox, oy), text, font=font, fill=TEXT_COLOR)
    # Tight crop
    arr = np.array(canvas)
    alpha = arr[..., 3]
    ys, xs = np.where(alpha > 0)
    if len(ys) == 0:
        return canvas
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    x0, x1 = int(xs.min()), int(xs.max()) + 1
    return canvas.crop((x0, y0, x1, y1))


def rgba_to_argb4_le_bytes(im: Image.Image) -> bytes:
    """Каждый pixel = 2 байта ARGB4 LE: AAAA RRRR GGGG BBBB → little-endian."""
    arr = np.array(im)
    H, W, _ = arr.shape
    # Stride must be 4-byte multiple (FT812 req): pad W to even.
    pad = (-W) & 1
    if pad:
        new_arr = np.zeros((H, W + pad, 4), dtype=np.uint8)
        new_arr[:, :W] = arr
        arr = new_arr
        W += pad
    out = bytearray()
    for y in range(H):
        for x in range(W):
            r, g, b, a = arr[y, x]
            a4 = (int(a) >> 4) & 0xF
            r4 = (int(r) >> 4) & 0xF
            g4 = (int(g) >> 4) & 0xF
            b4 = (int(b) >> 4) & 0xF
            word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
            out += word.to_bytes(2, 'little')
    return bytes(out), W, H


def main():
    # Render все, найти max W/H, потом pad всех к (max_w, max_h) для одинакового
    # stride — упрощает asm draw (один FT_BitmapLayout/Size для всех 3).
    rendered = []
    for name, text in STRINGS:
        im = render_text(text)
        rendered.append((name, text, im))
    max_w = max(im.size[0] for _, _, im in rendered)
    max_h = max(im.size[1] for _, _, im in rendered)
    # Pad W to even (stride 4-byte alignment for ARGB4 не required, но fits format).
    if max_w & 1: max_w += 1
    print(f'Unified canvas: {max_w}×{max_h}')

    for name, text, im in rendered:
        # Center-pad to (max_w, max_h)
        canvas = Image.new('RGBA', (max_w, max_h), (0, 0, 0, 0))
        # Center horizontally, top-align vertically (or center both)
        ox = (max_w - im.size[0]) // 2
        oy = (max_h - im.size[1]) // 2
        canvas.alpha_composite(im, (ox, oy))
        canvas.save(ROOT / f'_{name}_preview.png')
        argb4_data, W, H = rgba_to_argb4_le_bytes(canvas)
        raw_path = OUT / f'{name}.bin'
        raw_path.write_bytes(argb4_data)
        print(f'{name}: "{text}" → padded {W}×{H} ARGB4 = {len(argb4_data)} bytes')


if __name__ == '__main__':
    main()
