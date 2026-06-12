#!/usr/bin/env python3
"""Process Gemini-generated Maya dialog frame:
   1. Load source PNG (already background-removed).
   2. Detect green felt area and fill it solid to remove all text.
   3. Crop to non-transparent bbox.
   4. Save to Graphics/Original/sprites/dialog_frame.png.
"""
import sys
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
SRC_PATH = ROOT / 'Graphics' / 'Original' / 'Безымянный (1).png'
DST_PATH = ROOT / 'Graphics' / 'Original' / 'sprites' / 'dialog_frame.png'
PREVIEW = ROOT / '_dialog_frame_clean.png'


def main():
    src = Image.open(SRC_PATH).convert('RGBA')
    arr = np.array(src).copy()
    H, W, _ = arr.shape
    print(f'src: {W}x{H} mode RGBA')

    r = arr[..., 0].astype(int)
    g = arr[..., 1].astype(int)
    b = arr[..., 2].astype(int)
    a = arr[..., 3]
    # Only consider opaque pixels — иначе transparent area попадает в felt-mask
    # (PIL P-mode конвертация в RGBA даёт случайные RGB для transparent).
    is_felt = (a > 200) & (g > r + 15) & (g > b + 15) & (g > 60) & (g < 140)

    mask = np.zeros((H, W), dtype=bool)
    for y in range(H):
        cols = np.where(is_felt[y])[0]
        if len(cols) > 30:
            x0, x1 = int(cols.min()), int(cols.max())
            if x1 - x0 > 100:
                mask[y, x0:x1+1] = True

    felt_pool = arr[mask][..., :3]
    med = np.median(felt_pool, axis=0).astype(np.uint8)
    print(f'median felt: {tuple(int(c) for c in med)}, felt pixels: {mask.sum()}')

    arr[mask, 0] = med[0]
    arr[mask, 1] = med[1]
    arr[mask, 2] = med[2]
    arr[mask, 3] = 255

    alpha = arr[..., 3]
    ys, xs = np.where(alpha > 0)
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    x0, x1 = int(xs.min()), int(xs.max()) + 1
    print(f'crop bbox: x={x0}..{x1} y={y0}..{y1} size={x1-x0}x{y1-y0}')

    cleaned = Image.fromarray(arr[y0:y1, x0:x1], 'RGBA')
    # Target 400×327: aspect 1.223 ≈ источник 1.220, raw size 130800 байт
    # ровно укладывается в 8 SPG страниц по 16K (8×16384 = 131072 байт upload,
    # последние 272 байта = padding garbage за концом полезных данных, не страшно
    # поскольку sprite reader смотрит только на первые 130800).
    target_w, target_h = 400, 327
    scaled = cleaned.resize((target_w, target_h), Image.LANCZOS)
    scaled.save(PREVIEW)
    scaled.save(DST_PATH)
    print(f'saved: {DST_PATH.name} {scaled.size} (cleaned was {cleaned.size}, raw bytes = {target_w*target_h})')


if __name__ == '__main__':
    main()
