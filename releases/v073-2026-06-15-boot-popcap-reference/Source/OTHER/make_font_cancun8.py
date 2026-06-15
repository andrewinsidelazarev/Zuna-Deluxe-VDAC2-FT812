#!/usr/bin/env python3
"""Generate the compact Cancun8 HUD font atlas + asm metadata.

Only glyphs used in the top in-game HUD are packed: SCORE, digits, colon.
The source 640-space font is pre-scaled to 1024-space size at build time, so
runtime DrawString can render it with an identity bitmap transform.
"""
import subprocess
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
HD = Path(r'C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\content\fonts')
OUT_BIN = ROOT / 'Graphics' / 'Converted' / 'font_cancun8_atlas.bin'
OUT_INC = ROOT / 'Source' / 'ASM' / 'font_cancun8_meta.inc'

FONT_NAME = 'cancun8'   # source: cancun8.png 1227x21, full alphabet + digits + symbols
TARGET_H = 34           # 21 * 1.6, pre-rendered for 1024x768

# HUD uses "SCORE", HH:MM:SS and an 8-slot decimal score buffer.
USED_CHARS = list('SCORE0123456789:')
SPACE_WIDTH_SRC = 5
PREFIX = 'FONT_CANCUN8'
TABLE_PREFIX = 'font_cancun8'


def parse_font_txt(path: Path):
    text = path.read_text(encoding='utf-8').strip().splitlines()
    i = 0; sections = {}
    while i < len(text):
        line = text[i].strip()
        if line.startswith('CharList '):
            n = int(line.split()[1])
            chars = []
            for j in range(n):
                ch = text[i+1+j]
                chars.append(ch if len(ch) > 0 else ' ')
            sections['chars'] = chars
            i += 1 + n
        elif line.startswith('WidthList '):
            n = int(line.split()[1])
            sections['widths'] = [int(text[i+1+j]) for j in range(n)]
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


def rgba_to_argb4_le_bytes(arr):
    a16 = arr.astype(np.uint16)
    a4 = (a16[..., 3] >> 4) & 0xF
    r4 = (a16[..., 0] >> 4) & 0xF
    g4 = (a16[..., 1] >> 4) & 0xF
    b4 = (a16[..., 2] >> 4) & 0xF
    word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
    return word.astype('<u2').tobytes()


def main():
    src = Image.open(HD / f'{FONT_NAME}.png').convert('RGBA')
    print(f'source: {src.size}')
    src_h = src.size[1]

    meta = parse_font_txt(HD / f'{FONT_NAME}.txt')
    chars = meta['chars']; widths = meta['widths']
    rects = meta['rects']; offsets = meta['offsets']
    char_index = {c: i for i, c in enumerate(chars)}

    scale = TARGET_H / src_h
    src = src.resize((round(src.size[0] * scale), TARGET_H), Image.Resampling.LANCZOS)
    src_arr = np.array(src)
    rects = [
        (round(rx * scale), round(ry * scale), max(1, round(rw * scale)), max(1, round(rh * scale)))
        for rx, ry, rw, rh in rects
    ]
    widths = [max(1, round(w * scale)) for w in widths]
    space_width = max(1, round(SPACE_WIDTH_SRC * scale))

    missing = [c for c in USED_CHARS if c not in char_index]
    if missing:
        print(f'  WARNING: missing in font: {missing}')

    # Build compact atlas
    used_rects = []
    cursor_x = 0
    for ch in USED_CHARS:
        if ch not in char_index:
            continue
        idx = char_index[ch]
        rx, ry, rw, rh = rects[idx]
        adv = widths[idx]
        used_rects.append((ch, cursor_x, rx, ry, rw, rh, adv))
        cursor_x += rw
    atlas_w, atlas_h = cursor_x, TARGET_H

    atlas = np.zeros((atlas_h, atlas_w, 4), dtype=np.uint8)
    for ch, dst_x, rx, ry, rw, rh, adv in used_rects:
        atlas[:rh, dst_x:dst_x+rw] = src_arr[ry:ry+rh, rx:rx+rw]

    Image.fromarray(atlas, 'RGBA').save(ROOT / '_font_cancun8_atlas_preview.png')
    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    atlas_bytes = rgba_to_argb4_le_bytes(atlas)
    OUT_BIN.write_bytes(atlas_bytes)
    print(f'  atlas: {atlas_w}×{atlas_h}, saved {OUT_BIN.name}: {len(atlas_bytes)} bytes')

    # Split into 16K chunks + ZX7
    PAGE = 16384
    n_chunks = (len(atlas_bytes) + PAGE - 1) // PAGE
    here = Path(__file__).parent
    for stale in OUT_BIN.parent.glob('font_cancun8_atlas_p*.bin'):
        stale.unlink()
    for stale in OUT_BIN.parent.glob('font_cancun8_atlas_p*_zx7.bin'):
        stale.unlink()

    for i in range(n_chunks):
        chunk = atlas_bytes[i*PAGE:(i+1)*PAGE]
        if len(chunk) < PAGE:
            chunk = chunk + b'\x00' * (PAGE - len(chunk))
        rp = OUT_BIN.parent / f'font_cancun8_atlas_p{i:02d}.bin'
        zp = OUT_BIN.parent / f'font_cancun8_atlas_p{i:02d}_zx7.bin'
        rp.write_bytes(chunk)
        subprocess.check_call(['python', str(here / 'compress_zx7.py'), str(rp), str(zp)])

    # Generate asm tables
    glyph_x = [0]*128; glyph_w = [0]*128; advance = [0]*128
    for ch, dst_x, rx, ry, rw, rh, adv in used_rects:
        c = ord(ch)
        glyph_x[c] = dst_x; glyph_w[c] = rw; advance[c] = adv
    advance[ord(' ')] = space_width

    with open(OUT_INC, 'w', encoding='utf-8') as f:
        f.write(f'; AUTO-GENERATED by make_font_cancun8.py, do NOT edit.\n')
        f.write(f'; Compact 1024-native top HUD font. Charset: SCORE, 0-9, colon, space advance.\n')
        f.write(f'{PREFIX}_W       EQU {atlas_w}\n')
        f.write(f'{PREFIX}_H       EQU {atlas_h}\n')
        f.write(f'{PREFIX}_STRIDE  EQU {atlas_w * 2}\n')
        f.write(f'{PREFIX}_BYTES   EQU {atlas_w * atlas_h * 2}\n')
        f.write(f'{PREFIX}_NUM_PAGES EQU {n_chunks}\n\n')
        f.write(f'{TABLE_PREFIX}_glyph_x:\n')
        for c in range(0, 128, 8):
            f.write(f'    DEFW ' + ', '.join(str(glyph_x[c+i]) for i in range(8)) + '\n')
        f.write(f'\n{TABLE_PREFIX}_glyph_w:\n')
        for c in range(0, 128, 16):
            f.write(f'    DEFB ' + ', '.join(str(glyph_w[c+i]) for i in range(16)) + '\n')
        f.write(f'\n{TABLE_PREFIX}_advance:\n')
        for c in range(0, 128, 16):
            f.write(f'    DEFB ' + ', '.join(str(advance[c+i]) for i in range(16)) + '\n')

    print(f'  saved {OUT_INC.name}, {n_chunks} chunks')


if __name__ == '__main__':
    main()
