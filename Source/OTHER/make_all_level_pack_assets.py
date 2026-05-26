#!/usr/bin/env python3
"""Generate per-level assets for the external ZUMALVL.PAK.

Outputs canonical pack-only files under Graphics/levels/Converted/pack:
  bg_lNN_paletted_p00..p07.bin
  bg_lNN_palette_argb4.bin
  track_lNN_640.bin
  text_lNN_zx7.bin
  level_select_preview_lNN_p00..p05.bin

Compiled SPG fallback assets keep their old names and are not overwritten.
"""
from __future__ import annotations

import re
import shutil
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
ORIGINAL = ROOT / "Graphics" / "levels" / "Original"
OUT = ROOT / "Graphics" / "levels" / "Converted" / "pack"
PREVIEW_SPG_INC = ROOT / "Source" / "ASM" / "level_select_preview_spg.inc"
PAGE_SZ = 0x4000
PREVIEW_SPG_FIRST_PAGE = 0xCC
PREVIEW_SPG_OFFSET = 0x0200
PREVIEW_SPG_COUNT = 0
BG_W, BG_H = 400, 300
PREVIEW_W, PREVIEW_H = 280, 170

sys.path.insert(0, str(HERE))
import compress_zx7  # noqa: E402
import make_text_atlas  # noqa: E402


def argb4_palette_bytes(palette: np.ndarray) -> bytes:
    out = bytearray()
    for i in range(256):
        r, g, b, a = (int(palette[i][k]) for k in range(4))
        word = (((a >> 4) & 0xF) << 12) | (((r >> 4) & 0xF) << 8) | (((g >> 4) & 0xF) << 4) | ((b >> 4) & 0xF)
        out += word.to_bytes(2, "little")
    return bytes(out)


def pack_argb4(rgba: np.ndarray) -> bytes:
    out = bytearray()
    for r, g, b, a in rgba.reshape((-1, 4)):
        word = (((int(a) >> 4) & 0xF) << 12) | (((int(r) >> 4) & 0xF) << 8) | (((int(g) >> 4) & 0xF) << 4) | ((int(b) >> 4) & 0xF)
        out += word.to_bytes(2, "little")
    return bytes(out)


def write_pages(stem: str, data: bytes, pages: int) -> None:
    if (len(data) + PAGE_SZ - 1) // PAGE_SZ != pages:
        raise ValueError(f"{stem}: expected {pages} pages for {len(data)} bytes")
    for i in range(pages):
        chunk = data[i * PAGE_SZ : (i + 1) * PAGE_SZ]
        if len(chunk) < PAGE_SZ:
            chunk += bytes(PAGE_SZ - len(chunk))
        (OUT / f"{stem}_p{i:02d}.bin").write_bytes(chunk)


def level_titles() -> dict[int, str]:
    inc = (ROOT / "Source" / "ASM" / "level_runtime_table.inc").read_text(encoding="utf-8")
    titles: dict[int, str] = {}
    for m in re.finditer(r";\s*(\d+):\s*([^/]+?)\s*/\s*(.+)", inc):
        titles[int(m.group(1))] = m.group(3).strip().upper()
    return titles


def canonical_track(folder: Path, level: int) -> Path:
    direct = folder / f"{folder.name}-4-3.dat"
    if direct.exists():
        return direct
    first = folder / f"{folder.name}-1-4-3.dat"
    if first.exists():
        return first
    matches = sorted(folder.glob("*-4-3.dat"))
    if matches:
        return matches[0]
    raise FileNotFoundError(f"L{level:02d}: no generated 4:3 track in {folder}")


def build_bg_and_preview(level: int, src_png: Path) -> None:
    img = Image.open(src_png).convert("RGBA").resize((BG_W, BG_H), Image.Resampling.LANCZOS)
    rgb = img.convert("RGB")
    q = rgb.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
    raw_idx = np.array(q, dtype=np.uint8)
    indices = (raw_idx.astype(np.uint16) + 1).astype(np.uint8)

    pal_flat = q.getpalette()[: 255 * 3]
    palette = np.zeros((256, 4), dtype=np.uint8)
    palette[0] = (0, 0, 0, 0)
    for i in range(255):
        palette[i + 1] = (pal_flat[i * 3], pal_flat[i * 3 + 1], pal_flat[i * 3 + 2], 255)

    bg_data = indices.tobytes()
    (OUT / f"bg_l{level:02d}_paletted.bin").write_bytes(bg_data)
    (OUT / f"bg_l{level:02d}_palette_argb4.bin").write_bytes(argb4_palette_bytes(palette))
    write_pages(f"bg_l{level:02d}_paletted", bg_data, 8)

    rgba = palette[indices].reshape((BG_H, BG_W, 4))
    preview = Image.fromarray(rgba, "RGBA").resize((PREVIEW_W, PREVIEW_H), Image.Resampling.LANCZOS)
    preview_data = pack_argb4(np.asarray(preview, dtype=np.uint8))
    (OUT / f"level_select_preview_l{level:02d}.bin").write_bytes(preview_data)
    (OUT / f"level_select_preview_l{level:02d}.zlib").write_bytes(zlib.compress(preview_data, 9))
    write_pages(f"level_select_preview_l{level:02d}", preview_data, 6)


def build_title(level: int, title: str) -> None:
    img = make_text_atlas.render_string(title, scale=0.5)
    raw = make_text_atlas.to_argb4(img)
    raw_path = OUT / f"text_l{level:02d}.bin"
    zx7_path = OUT / f"text_l{level:02d}_zx7.bin"
    raw_path.write_bytes(raw)
    zx7_path.write_bytes(compress_zx7.compress(raw))
    (OUT / f"text_l{level:02d}.info").write_text(f"W={img.width}\nH={img.height}\nTITLE={title}\n", encoding="utf-8")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    titles = level_titles()
    folders = sorted(p for p in ORIGINAL.iterdir() if p.is_dir())
    if len(folders) != 22:
        raise RuntimeError(f"expected 22 original folders, got {len(folders)}")

    for folder in folders:
        level = int(folder.name[:2])
        src_png = folder / f"level_src_{level:02d}.png"
        track = canonical_track(folder, level)
        if not src_png.exists():
            raise FileNotFoundError(src_png)
        title = titles.get(level)
        if not title:
            raise RuntimeError(f"L{level:02d}: no title in level_runtime_table.inc")

        build_bg_and_preview(level, src_png)
        shutil.copy2(track, OUT / f"track_l{level:02d}_640.bin")
        build_title(level, title)
        print(f"L{level:02d}: {folder.name}  track={track.name}  title={title}")

    page = PREVIEW_SPG_FIRST_PAGE
    table_rows: list[tuple[int, int, int]] = []
    for level in range(1, PREVIEW_SPG_COUNT + 1):
        zpath = OUT / f"level_select_preview_l{level:02d}.zlib"
        size = zpath.stat().st_size
        table_rows.append((level, page, size))
        page += (PREVIEW_SPG_OFFSET + size + PAGE_SZ - 1) // PAGE_SZ
    if page > 0x100:
        raise RuntimeError(f"preview zlib streams need pages through #{page - 1:02X}, beyond #FF")
    lines = [
        "; Auto-generated by Source/OTHER/make_all_level_pack_assets.py.",
        "; SPG-resident zlib thumbnails for level select.",
        "; Empty on purpose: thumbnails are loaded raw from ZUMALVL.PAK.",
        "",
        "LEVEL_SELECT_PREVIEW_ZLIB_FIRST_PAGE EQU #CC",
        f"LEVEL_SELECT_PREVIEW_ZLIB_OFFSET     EQU #{PREVIEW_SPG_OFFSET:04X}",
        f"LEVEL_SELECT_PREVIEW_ZLIB_COUNT      EQU {PREVIEW_SPG_COUNT}",
        "",
        "LevelSelectPreviewZlibTable:",
    ]
    for level, pg, size in table_rows:
        lines.append(f"                DEFB #{pg:02X} : DEFW {size}    ; L{level:02d}")
    lines.append("")
    PREVIEW_SPG_INC.write_text("\n".join(lines), encoding="utf-8")
    print(f"preview zlib pages: #{PREVIEW_SPG_FIRST_PAGE:02X}..#{page - 1:02X}")
    print(f"wrote {PREVIEW_SPG_INC}")
    print(f"wrote pack assets: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
