#!/usr/bin/env python3
"""Generate the L19 trial ball atlas: PALETTED4444, 12 spin phases, 51px cell.

Experiment target:
  - L19 only.
  - No FT812 bitmap scaling for balls: 50px ball in a 51px cell/window.
  - The subpixel transparent guard prevents hardware rotation edge clipping.
  - Hardware rotation stays active; the atlas stores only spin phases.

Layout:
  cell = color * 12 + spin12

The source is the HD reference gameobjects.png: balls are 48x48 cells with the
vertical animation frame at y = frame * 48. We keep 12 exact phases from the
48-frame cycle by taking frames 0,4,8,...,44, then resample offline as a
50px visual ball centered in a 51x51 cell.
"""
from __future__ import annotations

from collections import Counter
from pathlib import Path
import os
import sys

import numpy as np
from PIL import Image


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HD_ROOT = Path(r"C:/Users/Администратор/Desktop/Zuma-Deluxe-HD-release-v010-ref")
HD_SRC = HD_ROOT / "content" / "images" / "gameobjects.png"
FALLBACK_SRC = Path(os.path.expanduser("~/Desktop/Zuma Deluxe/graphics/Zuma Deluxe - Gameplay - Balls.png"))
OUT_DIR = ROOT / "Graphics" / "Converted"

PAGE_BYTES = 0x4000
SRC_CELL = 48
BALL_PIXELS = 50
CELL = 51
N_COLORS = 6
N_PHASES = 12
SRC_PHASE_STEP = 4
GUARD_SUPERSAMPLE = 4

# Runtime colors: 0=blue, 1=green, 2=red, 3=yellow, 4=purple, 5=white.
# HD gameobjects columns: 0=blue, 1=green, 2=yellow, 3=red, 4=purple, 5=white.
VDC_TO_HD = {
    0: 0,
    1: 1,
    2: 3,
    3: 2,
    4: 4,
    5: 5,
}
VDC_NAMES = ["BLUE", "GREEN", "RED", "YELLOW", "PURPLE", "WHITE"]


def argb4_words(image: Image.Image) -> np.ndarray:
    arr = np.asarray(image.convert("RGBA"), dtype=np.uint16)
    a = (arr[..., 3] >> 4) & 0x0F
    r = (arr[..., 0] >> 4) & 0x0F
    g = (arr[..., 1] >> 4) & 0x0F
    b = (arr[..., 2] >> 4) & 0x0F
    words = ((a << 12) | (r << 8) | (g << 4) | b).astype(np.uint16)
    words[a == 0] = 0
    return words


def word_vec(word: int) -> np.ndarray:
    a = (word >> 12) & 0x0F
    r = (word >> 8) & 0x0F
    g = (word >> 4) & 0x0F
    b = word & 0x0F
    return np.array((a * 5, r * a, g * a, b * a), dtype=np.int16)


def build_palette(word_arrays: list[np.ndarray]) -> tuple[bytes, np.ndarray, int]:
    counts: Counter[int] = Counter()
    for words in word_arrays:
        counts.update(int(v) for v in words.ravel())
    counts.pop(0, None)
    unique_count = len(counts)

    palette_words = [word for word, _count in counts.most_common(255)]
    if not palette_words:
        palette_words = [0]

    pal_bytes = bytearray()
    pal_bytes += b"\x00\x00"
    for i in range(255):
        word = palette_words[i] if i < len(palette_words) else 0
        pal_bytes += int(word).to_bytes(2, "little")
    assert len(pal_bytes) == 512

    lookup = np.zeros(65536, dtype=np.uint8)
    for idx, word in enumerate(palette_words[:255], start=1):
        lookup[word] = idx

    missing = [word for word in counts if lookup[word] == 0]
    if missing:
        pal_vecs = np.stack([word_vec(word) for word in palette_words[:255]]).astype(np.int32)
        for word in missing:
            vec = word_vec(word).astype(np.int32)
            diff = pal_vecs - vec
            dist = (diff * diff).sum(axis=1)
            lookup[word] = int(np.argmin(dist)) + 1

    return bytes(pal_bytes), lookup, unique_count


def load_source() -> tuple[Image.Image, int, dict[int, int]]:
    if HD_SRC.exists():
        return Image.open(HD_SRC).convert("RGBA"), SRC_CELL, VDC_TO_HD

    # Fallback keeps the script runnable on machines without the HD checkout.
    # It is not the preferred experiment source.
    sheet = Image.open(FALLBACK_SRC).convert("RGBA")
    fallback_map = {0: 0, 1: 1, 2: 3, 3: 5, 4: 2, 5: 4}
    return sheet, 32, fallback_map


def resample_centered_cell(cell: Image.Image, src_cell: int) -> Image.Image:
    canvas_px = CELL * GUARD_SUPERSAMPLE
    ball_px = BALL_PIXELS * GUARD_SUPERSAMPLE
    guard_px = ((CELL - BALL_PIXELS) * GUARD_SUPERSAMPLE) // 2
    canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
    ball = cell.resize((ball_px, ball_px), Image.Resampling.LANCZOS)
    canvas.alpha_composite(ball, (guard_px, guard_px))
    return canvas.resize((CELL, CELL), Image.Resampling.LANCZOS)


def main() -> int:
    sys.path.insert(0, str(HERE))
    import compress_zx7  # noqa: WPS433

    sheet, src_cell, color_map = load_source()
    if sheet.size[0] < N_COLORS * src_cell:
        raise RuntimeError(f"unexpected source width {sheet.size[0]}")
    if sheet.size[1] < (N_PHASES - 1) * SRC_PHASE_STEP * src_cell + src_cell:
        raise RuntimeError(f"unexpected source height {sheet.size[1]}")

    word_arrays: list[np.ndarray] = []
    preview = Image.new("RGBA", (N_COLORS * CELL, CELL), (0, 0, 0, 0))

    for color in range(N_COLORS):
        src_col = color_map[color]
        for phase in range(N_PHASES):
            src_frame = phase * SRC_PHASE_STEP
            x0 = src_col * src_cell
            y0 = src_frame * src_cell
            cell = sheet.crop((x0, y0, x0 + src_cell, y0 + src_cell))
            cell = resample_centered_cell(cell, src_cell)
            word_arrays.append(argb4_words(cell))
            if phase == 0:
                preview.alpha_composite(cell, (color * CELL, 0))
        print(f"  VDC color {color} ({VDC_NAMES[color]:<6}) <- source col {src_col}")

    palette, lookup, unique_count = build_palette(word_arrays)

    atlas = bytearray()
    for words in word_arrays:
        atlas += lookup[words].astype(np.uint8).tobytes()

    expected = N_COLORS * N_PHASES * CELL * CELL
    if len(atlas) != expected:
        raise RuntimeError(f"atlas size {len(atlas)} != {expected}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "balls_l19_palette_argb4.bin").write_bytes(palette)
    (OUT_DIR / "balls_l19_pal4444.bin").write_bytes(atlas)

    pages = (len(atlas) + PAGE_BYTES - 1) // PAGE_BYTES
    if pages != 12:
        raise RuntimeError(f"expected 12 atlas pages, got {pages}")

    for i in range(pages):
        chunk = atlas[i * PAGE_BYTES : (i + 1) * PAGE_BYTES]
        chunk += bytes(PAGE_BYTES - len(chunk))
        raw_path = OUT_DIR / f"balls_l19_pal4444_p{i:02d}.bin"
        zx7_path = OUT_DIR / f"balls_l19_pal4444_p{i:02d}_zx7.bin"
        raw_path.write_bytes(chunk)
        zx7_path.write_bytes(compress_zx7.compress(chunk))

    preview.resize((preview.width * 3, preview.height * 3), Image.Resampling.NEAREST).save(
        ROOT / "_balls_l19_pal4444_preview.png"
    )
    print(
        f"balls_l19_pal4444: {len(atlas)} bytes, pages={pages}, cell={CELL}, "
        f"phases={N_PHASES}, unique_argb4={unique_count}, palette=512 bytes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
