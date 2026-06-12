#!/usr/bin/env python3
"""Build the FT812 paletted screen used by the More Games menu room."""

from __future__ import annotations

import json
import zlib
from pathlib import Path

import numpy as np
from PIL import Image


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = ROOT / "Graphics" / "Menu" / "More games.png"
QR_SOURCE = ROOT / "Graphics" / "Menu" / "qr_prods_tslabs_info.png"
OUT = ROOT / "Graphics" / "Menu" / "Converted"
SCREEN_SIZE = (640, 480)
RAW_CHUNK = 0xF000
QR_SCREEN_RECT = (463, 215, 160)


def build_screen_image(image: Image.Image) -> Image.Image:
    resized = image.convert("RGB").resize(SCREEN_SIZE, Image.Resampling.LANCZOS)
    qr = Image.open(QR_SOURCE).convert("RGB")
    x, y, size = QR_SCREEN_RECT
    qr = qr.resize((size, size), Image.Resampling.NEAREST)
    resized.paste(qr, (x, y))
    return resized


def palette_argb4_bytes(image: Image.Image) -> tuple[bytes, bytes]:
    quantized = image.quantize(
        colors=255,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.FLOYDSTEINBERG,
    )
    indices = (np.array(quantized, dtype=np.uint16) + 1).astype(np.uint8).tobytes()
    rgb = quantized.getpalette()[: 255 * 3]
    palette = bytearray(b"\x00\x00")
    for index in range(255):
        r, g, b = rgb[index * 3:index * 3 + 3]
        word = (0xF << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        palette += word.to_bytes(2, "little")
    assert len(indices) == SCREEN_SIZE[0] * SCREEN_SIZE[1]
    assert len(palette) == 512
    return indices, bytes(palette)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    screen = build_screen_image(Image.open(SOURCE))
    screen.save(OUT / "more_games_screen_4x3_preview.png")
    raw, palette = palette_argb4_bytes(screen)
    (OUT / "more_games_screen_4x3.bin").write_bytes(raw)
    (OUT / "more_games_palette_argb4.bin").write_bytes(palette)

    streams = []
    for index, offset in enumerate(range(0, len(raw), RAW_CHUNK)):
        chunk = raw[offset:offset + RAW_CHUNK]
        compressed = zlib.compress(chunk, level=9)
        name = f"more_games_screen_4x3_z{index:02d}.zlib"
        (OUT / name).write_bytes(compressed)
        streams.append({
            "file": name,
            "raw_offset": offset,
            "raw_size_bytes": len(chunk),
            "zlib_size_bytes": len(compressed),
        })

    manifest = {
        "profile": "more_games",
        "source_png": str(SOURCE),
        "qr_png": str(QR_SOURCE),
        "qr_screen_rect": list(QR_SCREEN_RECT),
        "screen_size": list(SCREEN_SIZE),
        "format": "FT_PALETTED4444",
        "raw_size_bytes": len(raw),
        "palette_file": "more_games_palette_argb4.bin",
        "inflate_streams": streams,
    }
    (OUT / "more_games_assets.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(streams)} More Games zlib streams to {OUT}")
    for stream in streams:
        print(
            f"{stream['file']}: raw={stream['raw_size_bytes']} "
            f"zlib={stream['zlib_size_bytes']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
