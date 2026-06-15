#!/usr/bin/env python3
"""Build 400x300 PALETTED4444 background for FT812.

Output:
  Graphics/levels/Converted/bg_paletted.bin          400*300 8bpp indices
  Graphics/levels/Converted/bg_paletted_p00..p07.bin 8 padded 16K pages
  Graphics/levels/Converted/bg_palette_argb4.bin     512-byte ARGB4 LE palette
  Graphics/levels/Converted/bg_paletted.zlib         zlib stream for FT812 CMD_INFLATE
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import zlib
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "Graphics" / "levels" / "Converted"
LEVELS_SRC = Path.home() / "Desktop" / "Zuma Deluxe" / "graphics" / "levels"
PAGE_SZ = 0x4000
W, H = 400, 300


def argb4_palette_bytes(palette: np.ndarray) -> bytes:
    out = bytearray()
    for i in range(256):
        r, g, b, a = (int(palette[i][k]) for k in range(4))
        word = (((a >> 4) & 0xF) << 12) | (((r >> 4) & 0xF) << 8) | (((g >> 4) & 0xF) << 4) | ((b >> 4) & 0xF)
        out += word.to_bytes(2, "little")
    return bytes(out)


def main() -> int:
    import sys

    level = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    src = LEVELS_SRC / f"level_src_{level:02d}.png"
    img = Image.open(src).convert("RGBA").resize((W, H), Image.Resampling.LANCZOS)

    # Reserve index 0 for transparency compatibility. Background is opaque, so
    # use 255 RGB colors and shift quantized indices by +1.
    rgb = img.convert("RGB")
    q = rgb.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
    raw_idx = np.array(q, dtype=np.uint8)
    indices = (raw_idx.astype(np.uint16) + 1).astype(np.uint8)

    pal_flat = q.getpalette()[: 255 * 3]
    palette = np.zeros((256, 4), dtype=np.uint8)
    palette[0] = (0, 0, 0, 0)
    for i in range(255):
        palette[i + 1] = (pal_flat[i * 3], pal_flat[i * 3 + 1], pal_flat[i * 3 + 2], 255)

    data = indices.tobytes()
    assert len(data) == W * H
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "bg_paletted.bin").write_bytes(data)
    (OUT / "bg_palette_argb4.bin").write_bytes(argb4_palette_bytes(palette))
    zdata = zlib.compress(data, 3)
    (OUT / "bg_paletted.zlib").write_bytes(zdata)

    n_pages = (len(data) + PAGE_SZ - 1) // PAGE_SZ
    assert n_pages == 8
    for i in range(n_pages):
        chunk = data[i * PAGE_SZ : (i + 1) * PAGE_SZ]
        if len(chunk) < PAGE_SZ:
            chunk += bytes(PAGE_SZ - len(chunk))
        (OUT / f"bg_paletted_p{i:02d}.bin").write_bytes(chunk)

    preview = Image.fromarray(palette[indices].reshape(H, W, 4), "RGBA")
    preview.save(ROOT / "_bg_paletted_preview.png")
    print(f"level {level}: {src.name}")
    print(f"wrote bg_paletted.bin: {len(data)} bytes ({W}x{H} PALETTED4444), {n_pages} pages")
    print("wrote bg_palette_argb4.bin: 512 bytes")
    print(f"wrote bg_paletted.zlib: {len(zdata)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
