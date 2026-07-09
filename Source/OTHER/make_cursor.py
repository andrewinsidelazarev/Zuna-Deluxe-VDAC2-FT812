#!/usr/bin/env python3
"""Build the native 38x38 global cursor from Graphics/Original/arrow1.png."""
from __future__ import annotations

import struct
import zlib
from collections import deque
from pathlib import Path

from PIL import Image


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ORIGINAL = ROOT / "Graphics" / "Original"
CONVERTED = ROOT / "Graphics" / "Converted"
BUILD = ROOT / "Build"

SRC = ORIGINAL / "arrow1.png"
CURSOR_PNG = ORIGINAL / "cursor.png"
CURSOR_BIN = CONVERTED / "cursor_p00.bin"
CURSOR_ZLIB = CONVERTED / "cursor_p00.zlib"
DEBUG_PNG = BUILD / "cursor_debug.png"

CURSOR_W = 38
CURSOR_H = 38
PAGE_SZ = 16384
OUTLINE_ALPHA = 32

def to_argb4_le(im: Image.Image) -> bytes:
    out = bytearray()
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            v = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            out += struct.pack("<H", v)
    return bytes(out)


def find_tip(im: Image.Image) -> tuple[int, int]:
    px = im.load()
    best: tuple[int, int] | None = None
    best_score: int | None = None
    for y in range(im.height):
        for x in range(im.width):
            if px[x, y][3] >= 128:
                score = x * x + y * y
                if best_score is None or score < best_score:
                    best_score = score
                    best = (x, y)
    if best is None:
        raise RuntimeError("cursor source has no opaque pixels")
    return best


def fill_inside_white(im: Image.Image) -> Image.Image:
    out = im.copy()
    px = out.load()
    w, h = out.size
    outside = [[False] * w for _ in range(h)]
    q: deque[tuple[int, int]] = deque()

    def is_open(x: int, y: int) -> bool:
        return px[x, y][3] < OUTLINE_ALPHA

    for x in range(w):
        for y in (0, h - 1):
            if is_open(x, y) and not outside[y][x]:
                outside[y][x] = True
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if is_open(x, y) and not outside[y][x]:
                outside[y][x] = True
                q.append((x, y))

    while q:
        x, y = q.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h and is_open(nx, ny) and not outside[ny][nx]:
                outside[ny][nx] = True
                q.append((nx, ny))

    filled = 0
    for y in range(h):
        for x in range(w):
            if is_open(x, y) and not outside[y][x]:
                px[x, y] = (255, 255, 255, 255)
                filled += 1
    print(f"filled inside white: {filled} source pixels")
    return out


def main() -> int:
    sheet = Image.open(SRC).convert("RGBA")
    bbox = sheet.getbbox()
    if bbox is None:
        raise RuntimeError("cursor source is fully transparent")
    crop = fill_inside_white(sheet.crop(bbox))
    tip_src = find_tip(crop)
    cursor = crop.resize((CURSOR_W, CURSOR_H), Image.Resampling.LANCZOS)
    tip_x = round(tip_src[0] * CURSOR_W / crop.width)
    tip_y = round(tip_src[1] * CURSOR_H / crop.height)
    tip_x = min(tip_x, CURSOR_W - 1)
    tip_y = min(tip_y, CURSOR_H - 1)

    CURSOR_PNG.parent.mkdir(parents=True, exist_ok=True)
    CONVERTED.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(parents=True, exist_ok=True)

    cursor.save(CURSOR_PNG)
    cursor.save(DEBUG_PNG)

    blob = to_argb4_le(cursor)
    assert len(blob) == CURSOR_W * CURSOR_H * 2
    zblob = zlib.compress(blob, 9)
    CURSOR_BIN.write_bytes(blob + b"\x00" * (PAGE_SZ - len(blob)))
    CURSOR_ZLIB.write_bytes(zblob)

    print(f"source: {SRC}")
    print(f"source bbox: {bbox}")
    print(f"source crop: {crop.width}x{crop.height} -> 38x38")
    print(f"source tip: {tip_src}")
    print(f"cursor.png: {cursor.size[0]}x{cursor.size[1]}")
    print(f"cursor_p00.bin: {len(blob)} real + {PAGE_SZ - len(blob)} padding = {PAGE_SZ}")
    print(f"cursor_p00.zlib: {CURSOR_ZLIB.stat().st_size} bytes")
    print(f"CURSOR_W = {CURSOR_W}, CURSOR_H = {CURSOR_H}")
    print(f"CURSOR_TIP_X = {tip_x}, CURSOR_TIP_Y = {tip_y}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
