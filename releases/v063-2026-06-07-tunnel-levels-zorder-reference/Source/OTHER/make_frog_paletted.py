#!/usr/bin/env python3
"""Frog PALETTED4444 using the same working scheme as balls.

This intentionally mirrors make_balls_atlas_paletted.py:
  - source pixels come from original PNG RGB, not intermediate ARGB4
  - alpha is binary: index 0 transparent, indices 1..255 opaque
  - one shared 256-entry ARGB4 palette, 512 bytes exactly
  - palette word = (A4<<12)|(R4<<8)|(G4<<4)|B4, little-endian
"""
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = Path.home() / "Desktop" / "Zuma Deluxe" / "graphics" / "frog.png"
OUT = ROOT / "Graphics" / "Converted"
PAGE_SIZE = 16384

W = H = 122
ALPHA_THRESHOLD = 128

PARTS = [
    ("frog", (0, 0, 162, 162), "frog_paletted.bin"),
    ("frog_plate", (162, 162, 324, 324), "frog_plate_paletted.bin"),
    ("frog_tongue", (162, 0, 324, 162), "frog_tongue_paletted.bin"),
    ("frog_overlay", (0, 162, 162, 324), "frog_overlay_paletted.bin"),
]


def main() -> int:
    sheet = Image.open(SRC).convert("RGBA")
    sprites = []
    opaque_rgb = []
    for name, crop, _ in PARTS:
        sprite = np.array(sheet.crop(crop).resize((W, H), Image.LANCZOS), dtype=np.uint8)
        sprites.append((name, sprite))
        mask = sprite[..., 3] >= ALPHA_THRESHOLD
        opaque_rgb.append(sprite[mask, :3])
        Image.fromarray(sprite, "RGBA").save(ROOT / f"_{name}_paletted_source.png")
        print(f"{name}: opaque={int(mask.sum())} / {W * H}")

    opaque_all = np.concatenate(opaque_rgb, axis=0)
    print(f"Opaque pixels for shared palette: {len(opaque_all)}")

    fake_img = Image.fromarray(opaque_all.reshape(-1, 1, 3), "RGB")
    fake_q = fake_img.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    pal_rgb_flat = fake_q.getpalette()[:255 * 3]
    pal_rgb_arr = np.array(pal_rgb_flat, dtype=np.int32).reshape(255, 3)

    palette_bytes = bytearray()
    palette_bytes += b"\x00\x00"  # index 0 = transparent ARGB4
    for i in range(255):
        r = pal_rgb_flat[i * 3]
        g = pal_rgb_flat[i * 3 + 1]
        b = pal_rgb_flat[i * 3 + 2]
        word = (0xF << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        palette_bytes += word.to_bytes(2, "little")
    assert len(palette_bytes) == 512
    (OUT / "frog_palette_argb4.bin").write_bytes(palette_bytes)

    # Keep aliases for current assembly pages; all four files are identical by design.
    for alias in [
        "frog_plate_palette_argb4.bin",
        "frog_tongue_palette_argb4.bin",
        "frog_overlay_palette_argb4.bin",
    ]:
        (OUT / alias).write_bytes(palette_bytes)
    print("Wrote shared frog palette aliases: 4 x 512 bytes")

    pal_lookup = [(0, 0, 0, 0)] + [
        (pal_rgb_flat[i * 3], pal_rgb_flat[i * 3 + 1], pal_rgb_flat[i * 3 + 2], 255)
        for i in range(255)
    ]

    for name, sprite in sprites:
        argb4_bytes = bytearray()
        for y in range(H):
            for x in range(W):
                r, g, b, a = (int(v) for v in sprite[y, x])
                word = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
                argb4_bytes += word.to_bytes(2, "little")
        assert len(argb4_bytes) == W * H * 2
        argb4_path = OUT / f"{name}_argb4.bin"
        argb4_path.write_bytes(bytes(argb4_bytes))
        chunks = (len(argb4_bytes) + PAGE_SIZE - 1) // PAGE_SIZE
        for i in range(chunks):
            chunk = argb4_bytes[i * PAGE_SIZE:(i + 1) * PAGE_SIZE]
            chunk = bytes(chunk) + b"\x00" * (PAGE_SIZE - len(chunk))
            raw_chunk = OUT / f"{name}_argb4_p{i:02d}.bin"
            zx7_chunk = OUT / f"{name}_argb4_p{i:02d}_zx7.bin"
            raw_chunk.write_bytes(chunk)
            subprocess.check_call(["python", str(HERE / "compress_zx7.py"), str(raw_chunk), str(zx7_chunk)])
        print(f"{name}_argb4.bin: {len(argb4_bytes)} bytes, {chunks} chunks")

        atlas_bytes = bytearray()
        for y in range(H):
            for x in range(W):
                r, g, b, a = sprite[y, x]
                if a < ALPHA_THRESHOLD:
                    atlas_bytes.append(0)
                else:
                    pix = np.array([r, g, b], dtype=np.int32)
                    diffs = pal_rgb_arr - pix
                    dist2 = (diffs * diffs).sum(axis=1)
                    atlas_bytes.append(int(np.argmin(dist2)) + 1)
        assert len(atlas_bytes) == W * H
        out_name = dict((p[0], p[2]) for p in PARTS)[name]
        (OUT / out_name).write_bytes(bytes(atlas_bytes))

        preview = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        for y in range(H):
            for x in range(W):
                preview.putpixel((x, y), pal_lookup[atlas_bytes[y * W + x]])
        preview.save(ROOT / f"_{name}_paletted_preview.png")
        print(f"{out_name}: {len(atlas_bytes)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
