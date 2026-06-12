#!/usr/bin/env python3
"""Render strings in nativealien48 font → ARGB4 bitmap for FT812.

Font format (HD project content/fonts/nativealien48.{png,txt}):
  CharList N : N лиц characters (A..Z, a..z, 0..9, !$%...)
  WidthList N : per-char advance width
  RectList N  : per-char rect in PNG = x y w h
  OffsetList N: per-char xoffset yoffset relative to baseline

Output bitmap:
  - Single horizontal strip, height = font height (clamped to 64 px), width = sum widths
  - ARGB4 (16 bpp, alpha + R/G/B 4-bit each)
  - Red→yellow gradient: lighter pixels in source PNG = yellow, darker = red
  - Transparent background

Usage:
  python make_text_atlas.py "GAME OVER" gameobjects/text_gameover.bin
"""
import argparse
import os
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FONT_PNG = ROOT / "_fonts" / "nativealien48.png"
FONT_TXT = ROOT / "_fonts" / "nativealien48.txt"

# Render-time scale (90 px native → ~48 px target). 1 = native, 0.5 = half-size.
DEFAULT_SCALE = 0.5

def parse_font_txt(path):
    """Parse BMFont-like text file → list of dicts {char, w, rect=(x,y,w,h), off=(x,y)}."""
    text = Path(path).read_text(encoding='utf-8').splitlines()
    sections = {}
    i = 0
    while i < len(text):
        line = text[i].strip()
        if line.startswith(('CharList', 'WidthList', 'RectList', 'OffsetList')):
            name, count = line.split()
            count = int(count)
            sections[name] = [text[i + 1 + j].strip() for j in range(count)]
            i += 1 + count
        else:
            i += 1
    chars = []
    for j, ch in enumerate(sections['CharList']):
        w = int(sections['WidthList'][j])
        rect = tuple(int(x) for x in sections['RectList'][j].split())
        off = tuple(int(x) for x in sections['OffsetList'][j].split())
        chars.append({'char': ch, 'w': w, 'rect': rect, 'off': off})
    return chars

def find_char(chars, c):
    for d in chars:
        if d['char'] == c:
            return d
    return None

def render_string(text, scale=DEFAULT_SCALE):
    """Return PIL RGBA Image with text in nativealien48.
    Цвета берутся НАПРЯМУЮ из font PNG (там уже нарисован красно-жёлтый градиент
    с дитерингом — top dark-red, middle yellow, bottom dark-red, как в оригинале
    Zuma Deluxe). Никаких перекрасок не делаем.
    """
    chars = parse_font_txt(FONT_TXT)
    font_img = Image.open(FONT_PNG).convert('RGBA')
    font_arr = np.array(font_img)  # H × W × 4

    H_native = font_img.height
    H_render = int(H_native * scale)

    # Compute total width
    total_w = 0
    layout = []
    for ch in text:
        d = find_char(chars, ch)
        if d is None:
            if ch == ' ':
                total_w += int(20 * scale)
                layout.append(None)
                continue
            raise ValueError(f"Char {ch!r} not in font")
        layout.append((d, total_w + int(d['off'][0] * scale)))
        total_w += int(d['w'] * scale) + int(1 * scale)

    canvas_img = Image.new('RGBA', (total_w, H_render), (0, 0, 0, 0))
    for ch, item in zip(text, layout):
        if item is None:
            continue
        d, draw_x = item
        x, y, w, h = d['rect']
        # Extract char (full native font height — gradient на всю glyph)
        char_rgba = font_arr[y:y+h, x:x+w]
        char_img = Image.fromarray(char_rgba, 'RGBA')
        if scale != 1.0:
            char_img = char_img.resize(
                (max(1, int(w * scale)), max(1, int(h * scale))),
                Image.LANCZOS,
            )
        canvas_img.paste(char_img, (draw_x, 0), char_img)
    return canvas_img

def to_argb4(img):
    """Convert RGBA PIL image → ARGB4 bytes (little-endian per pixel: A R G B 4-bit each → 2 bytes).
    ВАЖНО: каждый компонент cast в uint16 ДО сдвига, иначе `uint8 << 12` = overflow → 0.
    """
    arr = np.array(img).astype(np.uint16)  # H × W × 4, теперь uint16
    a = (arr[..., 3] >> 4) & 0xF
    r = (arr[..., 0] >> 4) & 0xF
    g = (arr[..., 1] >> 4) & 0xF
    b = (arr[..., 2] >> 4) & 0xF
    out = (a << 12) | (r << 8) | (g << 4) | b
    return out.astype('<u2').tobytes()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('text')
    ap.add_argument('out_bin')
    ap.add_argument('--scale', type=float, default=DEFAULT_SCALE)
    ap.add_argument('--preview-png', default=None)
    args = ap.parse_args()

    img = render_string(args.text, scale=args.scale)
    print(f'Rendered "{args.text}" → {img.width}×{img.height} ARGB4')

    bin_data = to_argb4(img)
    Path(args.out_bin).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_bin, 'wb') as f:
        f.write(bin_data)
    print(f'Wrote {args.out_bin}: {len(bin_data)} bytes ({img.width}*{img.height}*2)')

    if args.preview_png:
        img.save(args.preview_png)
        print(f'Preview: {args.preview_png}')

    # Also write a .info text file with dimensions (for asm EQUs)
    info_path = Path(args.out_bin).with_suffix('.info')
    with open(info_path, 'w') as f:
        f.write(f'W={img.width}\nH={img.height}\n')

if __name__ == '__main__':
    main()
