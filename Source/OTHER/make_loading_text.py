#!/usr/bin/env python3
"""Pre-render loading text pieces in nativealien48 (48 px, gradient).

The loading screen is shown BEFORE any glyph-font atlas is uploaded (and the
level48 glyph font only has L/E/V/digits/'-'), so we bake the fixed string into a
small ARGB4 bitmap atlas and blit it. Same nativealien48 source + red-yellow gradient
as the LEVEL N-M / GAME OVER text, so the look is consistent.

Output:
  Graphics/Converted/loading_text.bin           — ARGB4 LE bitmap
  Graphics/Converted/loading_text_pNN_zx7.bin   — 16K chunks, ZX7
  Source/ASM/loading_text_meta.inc              — loading text slice geometry
"""
import subprocess
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
OUT_BIN = ROOT / 'Graphics' / 'Converted' / 'loading_text.bin'
OUT_INC = ROOT / 'Source' / 'ASM' / 'loading_text_meta.inc'

FONT_NAME = 'nativealien48'
FONT_DIR = ROOT / 'Graphics' / 'fonts'
PNG_PATH = FONT_DIR / f'{FONT_NAME}.png'
TXT_PATH = FONT_DIR / f'{FONT_NAME}.txt'

TARGET_H = 48
PIECES = [
    ('PREFIX', 'LOADING LEVEL '),
    ('SUFFIX', '...'),
    ('SUFFIX_LEVELS', 'S...'),
    ('DASH', '-'),
    ('DIGIT_0', '0'),
    ('DIGIT_1', '1'),
    ('DIGIT_2', '2'),
    ('DIGIT_3', '3'),
    ('DIGIT_4', '4'),
    ('DIGIT_5', '5'),
    ('DIGIT_6', '6'),
    ('DIGIT_7', '7'),
    ('DIGIT_8', '8'),
    ('DIGIT_9', '9'),
]
SPACE_WIDTH = 13   # advance for ' ' at 48 px


def parse_font_txt(path: Path):
    text = path.read_text(encoding='utf-8').strip().splitlines()
    i = 0
    sections = {}
    while i < len(text):
        line = text[i].strip()
        if line.startswith('CharList '):
            n = int(line.split()[1])
            sections['chars'] = [text[i+1+j] if len(text[i+1+j]) else ' ' for j in range(n)]
            i += 1 + n
        elif line.startswith('WidthList '):
            n = int(line.split()[1])
            sections['widths'] = [int(text[i+1+j].strip()) for j in range(n)]
            i += 1 + n
        elif line.startswith('RectList '):
            n = int(line.split()[1])
            sections['rects'] = [tuple(int(v) for v in text[i+1+j].split()) for j in range(n)]
            i += 1 + n
        elif line.startswith('OffsetList '):
            n = int(line.split()[1])
            sections['offsets'] = [tuple(int(v) for v in text[i+1+j].split()) for j in range(n)]
            i += 1 + n
        else:
            i += 1
    return sections


def rgba_to_argb4_le_bytes(arr: np.ndarray) -> bytes:
    a16 = arr.astype(np.uint16)
    a4 = (a16[..., 3] >> 4) & 0xF
    r4 = (a16[..., 0] >> 4) & 0xF
    g4 = (a16[..., 1] >> 4) & 0xF
    b4 = (a16[..., 2] >> 4) & 0xF
    word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
    return word.astype('<u2').tobytes()


def main():
    src_img = Image.open(PNG_PATH).convert('RGBA')
    src_h = src_img.size[1]
    meta = parse_font_txt(TXT_PATH)
    chars, widths, rects = meta['chars'], meta['widths'], meta['rects']

    scale = TARGET_H / src_h
    src_img_scaled = src_img.resize((round(src_img.size[0]*scale), TARGET_H), Image.LANCZOS)
    src_arr = np.array(src_img_scaled)
    rects = [(round(rx*scale), round(ry*scale), round(rw*scale), round(rh*scale)) for rx, ry, rw, rh in rects]
    widths = [max(1, round(w*scale)) for w in widths]
    char_index = {c: i for i, c in enumerate(chars)}

    def text_width(text: str) -> int:
        total = 0
        for ch in text:
            if ch == ' ':
                total += SPACE_WIDTH
            elif ch in char_index:
                total += widths[char_index[ch]]
            else:
                print(f'  WARNING: char {ch!r} missing in font')
                total += SPACE_WIDTH
        return total

    piece_rects = []
    total_w = 0
    for name, text in PIECES:
        w = text_width(text)
        piece_rects.append((name, text, total_w, w))
        total_w += w
    print(f'  loading atlas -> {total_w}x{TARGET_H}')

    atlas = np.zeros((TARGET_H, total_w, 4), dtype=np.uint8)

    # Blit each piece at its atlas x.
    for name, text, base_x, piece_w in piece_rects:
        cx = base_x
        print(f'  {name}: "{text}" x={base_x} w={piece_w}')
        for ch in text:
            if ch == ' ':
                cx += SPACE_WIDTH
                continue
            if ch not in char_index:
                cx += SPACE_WIDTH
                continue
            idx = char_index[ch]
            rx, ry, rw, rh = rects[idx]
            adv = widths[idx]
            h = min(rh, TARGET_H)
            w = min(rw, total_w - cx)
            atlas[:h, cx:cx+w] = src_arr[ry:ry+h, rx:rx+w]
            cx += adv

    # Compatibility string dimensions: old menu loading draws PREFIX + SUFFIX_LEVELS.
    levels_w = next(w for name, text, x, w in piece_rects if name == 'PREFIX') + \
        next(w for name, text, x, w in piece_rects if name == 'SUFFIX_LEVELS')

    Image.fromarray(atlas, 'RGBA').save(ROOT / '_loading_text_preview.png')
    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    atlas_bytes = rgba_to_argb4_le_bytes(atlas)
    OUT_BIN.write_bytes(atlas_bytes)
    print(f'  saved {OUT_BIN.name}: {len(atlas_bytes)} bytes')

    PAGE_BYTES = 16384
    num_chunks = (len(atlas_bytes) + PAGE_BYTES - 1) // PAGE_BYTES
    here = Path(__file__).parent
    for i in range(num_chunks):
        chunk = atlas_bytes[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        if len(chunk) < PAGE_BYTES:
            chunk = chunk + b'\x00' * (PAGE_BYTES - len(chunk))
        raw_chunk = OUT_BIN.parent / f'loading_text_p{i:02d}.bin'
        raw_chunk.write_bytes(chunk)
        zx7_chunk = OUT_BIN.parent / f'loading_text_p{i:02d}_zx7.bin'
        subprocess.check_call(['python', str(here / 'compress_zx7.py'), str(raw_chunk), str(zx7_chunk)])
        print(f'    chunk {i}: zx7={zx7_chunk.stat().st_size}')

    with open(OUT_INC, 'w', encoding='utf-8') as f:
        f.write('; AUTO-GENERATED by make_loading_text.py, do NOT edit.\n')
        f.write(f'; Pre-rendered nativealien48 {TARGET_H}px ARGB4 loading text pieces.\n\n')
        f.write(f'LOADING_TEXT_W   EQU {total_w}\n')
        f.write(f'LOADING_TEXT_H   EQU {TARGET_H}\n')
        f.write(f'LOADING_TEXT_NUM_PAGES EQU {num_chunks}\n')
        f.write(f'LOADING_LEVELS_W EQU {levels_w}\n')
        for name, text, x, w in piece_rects:
            f.write(f'LOADING_TEXT_{name}_X EQU {x}\n')
            f.write(f'LOADING_TEXT_{name}_W EQU {w}\n')
    print(f'  saved {OUT_INC.name}: {num_chunks} pages')


if __name__ == '__main__':
    main()
