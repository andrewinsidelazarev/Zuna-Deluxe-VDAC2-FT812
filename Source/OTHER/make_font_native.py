#!/usr/bin/env python3
"""Generate native alien font atlas + asm metadata tables.

Source: HD-ref nativealien48.png + .txt (charlist + widths + rects).
Output:
  Graphics/Converted/font_native_atlas.bin   — ARGB4 LE bitmap (compact, only used chars)
  Source/ASM/font_native_meta.inc            — asm constants + LUT tables

We extract only the characters we'll use (A-Z, 0-9, ':', ' '), repack horizontally
into a tight atlas, and emit per-ASCII lookup tables for glyph rect + advance.
"""
import os
import subprocess
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(r'C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2')
HD = Path(r'C:\Users\Администратор\Desktop\Zuma-Deluxe-HD-ref\content\fonts')
OUT_BIN = ROOT / 'Graphics' / 'Converted' / 'font_native_atlas.bin'
OUT_INC = ROOT / 'Source' / 'ASM' / 'font_native_meta.inc'

FONT_NAME = 'nativealien48'
PNG_PATH = HD / f'{FONT_NAME}.png'
TXT_PATH = HD / f'{FONT_NAME}.txt'

# Target render height. HD-ref uses nativealien48 for level titles, but the
# FT812 dialog cannot afford a 48 px full charset atlas in RAM_G.
TARGET_H = 30

# nativealien48 has the real uppercase set used by HD-ref for level titles.
USED_CHARS = list('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:.')
SPACE_WIDTH = 8   # synthesized — used for ' '


def parse_font_txt(path: Path):
    text = path.read_text(encoding='utf-8').strip().splitlines()
    i = 0
    sections = {}
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
            widths = [int(text[i+1+j].strip()) for j in range(n)]
            sections['widths'] = widths
            i += 1 + n
        elif line.startswith('RectList '):
            n = int(line.split()[1])
            rects = []
            for j in range(n):
                x, y, w, h = (int(v) for v in text[i+1+j].split())
                rects.append((x, y, w, h))
            sections['rects'] = rects
            i += 1 + n
        elif line.startswith('OffsetList '):
            n = int(line.split()[1])
            offs = []
            for j in range(n):
                ox, oy = (int(v) for v in text[i+1+j].split())
                offs.append((ox, oy))
            sections['offsets'] = offs
            i += 1 + n
        else:
            i += 1
    return sections


def rgba_to_argb4_le_bytes(arr: np.ndarray) -> bytes:
    """arr = HxWx4 uint8 → bytes ARGB4 LE 16bpp."""
    a16 = arr.astype(np.uint16)
    a4 = (a16[..., 3] >> 4) & 0xF
    r4 = (a16[..., 0] >> 4) & 0xF
    g4 = (a16[..., 1] >> 4) & 0xF
    b4 = (a16[..., 2] >> 4) & 0xF
    word = (a4 << 12) | (r4 << 8) | (g4 << 4) | b4
    return word.astype('<u2').tobytes()


def main():
    print(f'Loading {PNG_PATH.name}...')
    src_img = Image.open(PNG_PATH).convert('RGBA')
    print(f'  source size: {src_img.size}')
    src_arr = np.array(src_img)
    src_h = src_arr.shape[0]

    meta = parse_font_txt(TXT_PATH)
    chars = meta['chars']
    widths = meta['widths']
    rects = meta['rects']
    offsets = meta['offsets']
    assert len(chars) == len(widths) == len(rects) == len(offsets)
    print(f'  parsed {len(chars)} glyphs, source atlas height {src_h}')

    # Downscale source to TARGET_H using PIL Lanczos. Adjust rects+widths accordingly.
    scale = TARGET_H / src_h
    new_w = round(src_img.size[0] * scale)
    src_img_scaled = src_img.resize((new_w, TARGET_H), Image.LANCZOS)
    src_arr = np.array(src_img_scaled)
    font_h = TARGET_H
    print(f'  scaled to {src_img_scaled.size}, ratio={scale:.3f}')
    # Scale rect/width arrays
    rects = [(round(rx*scale), round(ry*scale), round(rw*scale), round(rh*scale)) for rx,ry,rw,rh in rects]
    widths = [max(1, round(w*scale)) for w in widths]

    # Build map from char → (rect, advance_width, offset)
    char_index = {c: i for i, c in enumerate(chars)}

    # Verify all USED_CHARS exist in font
    missing = [c for c in USED_CHARS if c not in char_index]
    if missing:
        print(f'  WARNING: missing in font: {missing}')

    # Build compact atlas: paste each USED_CHAR's rect side-by-side.
    # Atlas width = sum of (rect_w per used char).
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
    atlas_w = cursor_x
    atlas_h = font_h
    print(f'  compact atlas: {atlas_w}×{atlas_h}')

    # Compose compact atlas image
    atlas = np.zeros((atlas_h, atlas_w, 4), dtype=np.uint8)
    for ch, dst_x, rx, ry, rw, rh, adv in used_rects:
        atlas[:rh, dst_x:dst_x+rw] = src_arr[ry:ry+rh, rx:rx+rw]

    # Save preview PNG
    Image.fromarray(atlas, 'RGBA').save(ROOT / '_font_native_atlas_preview.png')

    # Save ARGB4 LE binary
    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    atlas_bytes = rgba_to_argb4_le_bytes(atlas)
    assert len(atlas_bytes) == atlas_w * atlas_h * 2
    OUT_BIN.write_bytes(atlas_bytes)
    print(f'  saved {OUT_BIN.name}: {len(atlas_bytes)} bytes')

    # Split raw into 16K chunks + ZX7 compress each (each chunk on its own SPG page).
    PAGE_BYTES = 16384
    num_chunks = (len(atlas_bytes) + PAGE_BYTES - 1) // PAGE_BYTES
    print(f'  splitting into {num_chunks} × 16K chunks for SPG upload')
    here = Path(__file__).parent
    for i in range(num_chunks):
        chunk = atlas_bytes[i*PAGE_BYTES:(i+1)*PAGE_BYTES]
        if len(chunk) < PAGE_BYTES:
            chunk = chunk + b'\x00' * (PAGE_BYTES - len(chunk))
        raw_chunk = OUT_BIN.parent / f'font_native_atlas_p{i:02d}.bin'
        raw_chunk.write_bytes(chunk)
        zx7_chunk = OUT_BIN.parent / f'font_native_atlas_p{i:02d}_zx7.bin'
        subprocess.check_call(['python', str(here / 'compress_zx7.py'), str(raw_chunk), str(zx7_chunk)])
        print(f'    chunk {i}: zx7={zx7_chunk.stat().st_size}')

    # Generate asm inc with:
    #   FONT_NATIVE_W, FONT_NATIVE_H, FONT_NATIVE_BYTES
    #   FONT_NATIVE_STRIDE (= W*2)
    #   font_native_glyph_x: DEFW per ASCII char (0..127), x offset in atlas (0 if missing)
    #   font_native_glyph_w: DEFB per ASCII char, width in atlas (0 = skip glyph emit)
    #   font_native_advance: DEFB per ASCII char, cursor advance after glyph
    glyph_x = [0] * 128
    glyph_w = [0] * 128
    advance = [0] * 128
    for ch, dst_x, rx, ry, rw, rh, adv in used_rects:
        c = ord(ch)
        glyph_x[c] = dst_x
        glyph_w[c] = rw
        advance[c] = adv
    # Space: synthesized
    advance[ord(' ')] = SPACE_WIDTH

    with open(OUT_INC, 'w', encoding='utf-8') as f:
        f.write(f'; AUTO-GENERATED by make_font_native.py, do NOT edit.\n')
        f.write(f'; Source font: {FONT_NAME}.png + .txt (HD-ref)\n')
        f.write(f'\n')
        f.write(f'FONT_NATIVE_W       EQU {atlas_w}\n')
        f.write(f'FONT_NATIVE_H       EQU {atlas_h}\n')
        f.write(f'FONT_NATIVE_STRIDE  EQU {atlas_w * 2}    ; bytes per row (ARGB4 = 2 bytes/pixel)\n')
        f.write(f'FONT_NATIVE_BYTES   EQU {atlas_w * atlas_h * 2}\n')
        f.write(f'\n')
        # font_native_glyph_x: word table indexed by ASCII code
        f.write(f'font_native_glyph_x:\n')
        for c in range(0, 128, 8):
            row = ', '.join(str(glyph_x[c+i]) for i in range(8))
            f.write(f'    DEFW {row}     ; chars {c:3d}..{c+7}\n')
        f.write(f'\n')
        f.write(f'font_native_glyph_w:\n')
        for c in range(0, 128, 16):
            row = ', '.join(str(glyph_w[c+i]) for i in range(16))
            f.write(f'    DEFB {row}     ; chars {c:3d}..{c+15}\n')
        f.write(f'\n')
        f.write(f'font_native_advance:\n')
        for c in range(0, 128, 16):
            row = ', '.join(str(advance[c+i]) for i in range(16))
            f.write(f'    DEFB {row}     ; chars {c:3d}..{c+15}\n')
    print(f'  saved {OUT_INC.name}')


if __name__ == '__main__':
    main()
