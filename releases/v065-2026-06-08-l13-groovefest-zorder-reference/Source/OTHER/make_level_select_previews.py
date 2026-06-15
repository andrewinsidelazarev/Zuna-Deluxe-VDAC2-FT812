#!/usr/bin/env python3
"""Build fixed-size level-select preview bitmaps.

Runtime downscale of PALETTED4444 through the FT812 bitmap transform can render
as palette-index noise in the emulator/hardware path. Small PALETTED preview
bitmaps still showed palette artifacts, so these thumbnails are stored as ARGB4
and drawn 1:1 without a palette source.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Graphics" / "levels" / "Converted"
PAGE_SZ = 0x4000
SRC_W, SRC_H = 400, 300
PREVIEW_W, PREVIEW_H = 306, 196


def read_argb4_palette(path: Path) -> np.ndarray:
    raw = path.read_bytes()
    if len(raw) != 512:
        raise ValueError(f"{path} must be exactly 512 bytes")
    pal = np.zeros((256, 4), dtype=np.uint8)
    for i in range(256):
        word = int.from_bytes(raw[i * 2 : i * 2 + 2], "little")
        a = ((word >> 12) & 0xF) * 17
        r = ((word >> 8) & 0xF) * 17
        g = ((word >> 4) & 0xF) * 17
        b = (word & 0xF) * 17
        pal[i] = (r, g, b, a)
    return pal


def pack_argb4(rgba: np.ndarray) -> bytes:
    out = bytearray()
    flat = rgba.reshape((-1, 4))
    for r, g, b, a in flat:
        word = (((int(a) >> 4) & 0xF) << 12) | (((int(r) >> 4) & 0xF) << 8) | (((int(g) >> 4) & 0xF) << 4) | ((int(b) >> 4) & 0xF)
        out += word.to_bytes(2, "little")
    return bytes(out)


def crop_to_aspect(image: Image.Image, width: int, height: int) -> Image.Image:
    target = width / height
    src_w, src_h = image.size
    crop_w = src_w
    crop_h = round(crop_w / target)
    if crop_h > src_h:
        crop_h = src_h
        crop_w = round(crop_h * target)
    x0 = (src_w - crop_w) // 2
    y0 = (src_h - crop_h) // 2
    return image.crop((x0, y0, x0 + crop_w, y0 + crop_h))


def write_pages(stem: str, data: bytes) -> None:
    pages = (len(data) + PAGE_SZ - 1) // PAGE_SZ
    if pages != 8:
        raise ValueError(f"{stem}: expected 8 pages, got {pages}")
    for i in range(pages):
        chunk = data[i * PAGE_SZ : (i + 1) * PAGE_SZ]
        if len(chunk) < PAGE_SZ:
            chunk += bytes(PAGE_SZ - len(chunk))
        (OUT / f"{stem}_p{i:02d}.bin").write_bytes(chunk)


def build(stem: str, bg_name: str, pal_name: str) -> None:
    bg = OUT / bg_name
    pal_path = OUT / pal_name
    raw = bg.read_bytes()
    if len(raw) != SRC_W * SRC_H:
        raise ValueError(f"{bg} must be {SRC_W * SRC_H} bytes")
    palette = read_argb4_palette(pal_path)
    indices = np.frombuffer(raw, dtype=np.uint8).reshape((SRC_H, SRC_W))
    rgba = palette[indices]
    img = crop_to_aspect(Image.fromarray(rgba, "RGBA"), PREVIEW_W, PREVIEW_H).resize((PREVIEW_W, PREVIEW_H), Image.Resampling.LANCZOS)
    preview_rgba = np.asarray(img, dtype=np.uint8)
    data = pack_argb4(preview_rgba)
    (OUT / f"{stem}.bin").write_bytes(data)
    write_pages(stem, data)
    img.save(ROOT / f"_{stem}.png")
    print(f"{stem}: {len(data)} bytes ({PREVIEW_W}x{PREVIEW_H} ARGB4), 8 pages")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    build("level_select_preview_l01", "bg_paletted.bin", "bg_palette_argb4.bin")
    build("level_select_preview_l02", "bg_l02_paletted.bin", "bg_l02_palette_argb4.bin")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
