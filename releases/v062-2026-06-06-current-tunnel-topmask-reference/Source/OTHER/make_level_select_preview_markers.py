#!/usr/bin/env python3
"""Build flat ARGB4 frog/kill-zone markers for the level-select thumbnail."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

from PIL import Image


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CONVERTED = ROOT / "Graphics" / "Converted"
OUT = ROOT / "Graphics" / "Menu" / "Converted"

FROG_SOURCE_SIZE = 122
FROG_PREVIEW_SIZE = 54
KZ_SOURCE_SIZE = 88
KZ_FRAMES = 12
KZ_CLOSED_CELL = 1
KZ_PREVIEW_SIZE = 39


def argb4_to_image(blob: bytes, size: tuple[int, int]) -> Image.Image:
    pixels = []
    for (word,) in struct.iter_unpack("<H", blob[: size[0] * size[1] * 2]):
        a = ((word >> 12) & 0xF) * 17
        r = ((word >> 8) & 0xF) * 17
        g = ((word >> 4) & 0xF) * 17
        b = (word & 0xF) * 17
        pixels.append((r, g, b, a))
    image = Image.new("RGBA", size)
    image.putdata(pixels)
    return image


def image_to_argb4(image: Image.Image) -> bytes:
    out = bytearray()
    for r, g, b, a in image.convert("RGBA").get_flattened_data():
        word = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        out += struct.pack("<H", word)
    return bytes(out)


def write_zlib(name: str, image: Image.Image) -> None:
    raw = image_to_argb4(image)
    compressed = zlib.compress(raw, level=9)
    (OUT / f"{name}.bin").write_bytes(raw)
    (OUT / f"{name}.zlib").write_bytes(compressed)
    image.save(OUT / f"{name}_preview.png")
    print(f"{name}: {image.width}x{image.height}, raw={len(raw)}, zlib={len(compressed)}")


def build_frog() -> Image.Image:
    # Runtime frog order without animated ball sprites: plate -> body -> tongue -> face.
    layers = [
        argb4_to_image((CONVERTED / "frog_plate_argb4.bin").read_bytes(), (FROG_SOURCE_SIZE, FROG_SOURCE_SIZE)),
        argb4_to_image((CONVERTED / "frog_argb4.bin").read_bytes(), (FROG_SOURCE_SIZE, FROG_SOURCE_SIZE)),
        argb4_to_image((CONVERTED / "frog_tongue_argb4.bin").read_bytes(), (FROG_SOURCE_SIZE, FROG_SOURCE_SIZE)),
        argb4_to_image((CONVERTED / "frog_overlay_argb4.bin").read_bytes(), (FROG_SOURCE_SIZE, FROG_SOURCE_SIZE)),
    ]
    flat = Image.new("RGBA", layers[0].size, (0, 0, 0, 0))
    for layer in layers:
        flat.alpha_composite(layer)
    return flat.resize((FROG_PREVIEW_SIZE, FROG_PREVIEW_SIZE), Image.Resampling.LANCZOS)


def build_killzone() -> Image.Image:
    blob = (CONVERTED / "killzone.bin").read_bytes()
    pixel_bytes = KZ_SOURCE_SIZE * KZ_SOURCE_SIZE * KZ_FRAMES
    indices = blob[:pixel_bytes]
    palette_blob = blob[pixel_bytes:pixel_bytes + 512]
    palette = []
    for (word,) in struct.iter_unpack("<H", palette_blob):
        a = ((word >> 12) & 0xF) * 17
        r = ((word >> 8) & 0xF) * 17
        g = ((word >> 4) & 0xF) * 17
        b = (word & 0xF) * 17
        palette.append((r, g, b, a))

    def cell(index: int) -> Image.Image:
        start = index * KZ_SOURCE_SIZE * KZ_SOURCE_SIZE
        image = Image.new("RGBA", (KZ_SOURCE_SIZE, KZ_SOURCE_SIZE))
        image.putdata([palette[value] for value in indices[start:start + KZ_SOURCE_SIZE * KZ_SOURCE_SIZE]])
        return image

    # Match normal gameplay: black-hole base under the closed skull cell.
    flat = cell(0)
    flat.alpha_composite(cell(KZ_CLOSED_CELL))
    return flat.resize((KZ_PREVIEW_SIZE, KZ_PREVIEW_SIZE), Image.Resampling.LANCZOS)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    write_zlib("level_select_preview_frog_argb4", build_frog())
    write_zlib("level_select_preview_killzone_argb4", build_killzone())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
