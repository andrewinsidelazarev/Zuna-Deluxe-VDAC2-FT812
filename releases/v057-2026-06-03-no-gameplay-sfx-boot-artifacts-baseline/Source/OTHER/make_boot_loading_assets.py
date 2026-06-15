#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import struct
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Graphics" / "Converted" / "BootLoading"
INC = ROOT / "Source" / "ASM" / "boot_loading_assets.inc"
PAGE_SIZE = 0x4000

BG_DXT_SRC = ROOT / "Graphics" / "Load Screen" / "loading_canvas_hdref_source_640x480_visual_center_l4.dxt"
BAR_SRC = ROOT / "Graphics" / "Load Screen" / "progress_bar_hdref_alpha_bounds_scale_div_1_5.png"
ANIM_DIR = ROOT / "Graphics" / "Load Screen" / "ts_anim"
ANIM_FILES = [ANIM_DIR / f"Image100{i:02d}.png" for i in range(1, 12)]

BG_PAGE_BASE = 0xA8
BAR_PAGE_BASE = 0xB7
ANIM_PAGE_BASE = 0xB9


def load_zx7():
    path = Path(__file__).resolve().parent / "compress_zx7.py"
    spec = importlib.util.spec_from_file_location("compress_zx7", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def argb4_bytes(path: Path) -> tuple[bytes, int, int]:
    img = Image.open(path).convert("RGBA")
    out = bytearray()
    for r, g, b, a in img.getdata():
        word = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        out += word.to_bytes(2, "little")
    return bytes(out), img.width, img.height


def black_to_alpha(image: Image.Image) -> Image.Image:
    """Treat black background in TS animation frames as transparent."""
    src = image.convert("RGBA")
    out = []
    for r, g, b, a in src.getdata():
        if r <= 8 and g <= 8 and b <= 8:
            out.append((r, g, b, 0))
        else:
            out.append((r, g, b, a))
    src.putdata(out)
    return src


def write_chunks(stem: str, data: bytes, zx7) -> int:
    pages = (len(data) + PAGE_SIZE - 1) // PAGE_SIZE
    for index in range(pages):
        chunk = data[index * PAGE_SIZE:(index + 1) * PAGE_SIZE].ljust(PAGE_SIZE, b"\0")
        raw_path = OUT / f"{stem}_p{index:02d}.bin"
        zx7_path = OUT / f"{stem}_p{index:02d}_zx7.bin"
        raw_path.write_bytes(chunk)
        zx7_path.write_bytes(zx7.compress(chunk))
    return pages


def dxt_l4_raw(path: Path) -> tuple[bytes, dict[str, int]]:
    data = path.read_bytes()
    if data[:4] != b"D1L4":
        raise RuntimeError(f"{path}: expected D1L4 magic")
    width, height, block_count = struct.unpack_from("<III", data, 4)
    if width % 4 or height % 4:
        raise RuntimeError(f"{path}: dimensions must be 4-pixel aligned, got {width}x{height}")
    blocks_x = width // 4
    blocks_y = height // 4
    if block_count != blocks_x * blocks_y:
        raise RuntimeError(f"{path}: block_count {block_count} != {blocks_x * blocks_y}")

    c_size = block_count * 2
    mask_stride = (width + 1) // 2
    mask_size = mask_stride * height
    raw = bytearray(c_size * 2 + mask_size)

    src = 16
    for index in range(block_count):
        dst_c0 = index * 2
        dst_c1 = c_size + index * 2
        raw[dst_c0:dst_c0 + 2] = data[src:src + 2]
        raw[dst_c1:dst_c1 + 2] = data[src + 2:src + 4]

        block_x = index % blocks_x
        block_y = index // blocks_x
        selectors = src + 4
        for py in range(4):
            y = block_y * 4 + py
            dst = c_size * 2 + y * mask_stride + block_x * 2
            raw[dst:dst + 2] = data[selectors + py * 2:selectors + py * 2 + 2]
        src += 12

    meta = {
        "w": width,
        "h": height,
        "blocks_x": blocks_x,
        "blocks_y": blocks_y,
        "c0_offset": 0,
        "c1_offset": c_size,
        "mask_offset": c_size * 2,
        "c_size": c_size,
        "mask_size": mask_size,
        "raw_size": len(raw),
        "color_stride": blocks_x * 2,
        "color_height": blocks_y,
        "mask_stride": mask_stride,
    }
    return bytes(raw), meta


def write_raw_pages(stem: str, data: bytes) -> int:
    pages = (len(data) + PAGE_SIZE - 1) // PAGE_SIZE
    for index in range(pages):
        chunk = data[index * PAGE_SIZE:(index + 1) * PAGE_SIZE].ljust(PAGE_SIZE, b"\0")
        raw_path = OUT / f"{stem}_p{index:02d}.bin"
        raw_path.write_bytes(chunk)
    return pages


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    zx7 = load_zx7()

    bg_data, bg_meta = dxt_l4_raw(BG_DXT_SRC)
    bar_data, bar_w, bar_h = argb4_bytes(BAR_SRC)
    bg_pages = write_raw_pages("boot_loading_bg_dxt_l4", bg_data)
    bar_pages = write_chunks("boot_loading_bar_argb4", bar_data, zx7)

    anim_w = anim_h = None
    anim_frames: list[Image.Image] = []
    for frame, path in enumerate(ANIM_FILES):
        img = black_to_alpha(Image.open(path))
        w, h = img.size
        if anim_w is None:
            anim_w, anim_h = w, h
        elif (w, h) != (anim_w, anim_h):
            raise RuntimeError(f"{path.name}: size {w}x{h} differs from {anim_w}x{anim_h}")
        anim_frames.append(img)

    assert anim_w is not None and anim_h is not None
    atlas = Image.new("RGBA", (anim_w, anim_h * len(anim_frames)), (0, 0, 0, 0))
    for frame, img in enumerate(anim_frames):
        atlas.alpha_composite(img, (0, frame * anim_h))
    atlas_path = OUT / "boot_ts_anim_atlas_preview.png"
    atlas.save(atlas_path)
    atlas_raw = bytearray()
    for r, g, b, a in atlas.getdata():
        word = ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
        atlas_raw += word.to_bytes(2, "little")
    anim_pages = write_chunks("boot_ts_anim_atlas_argb4", bytes(atlas_raw), zx7)

    lines = [
        "; AUTO-GENERATED by Source/OTHER/make_boot_loading_assets.py, do NOT edit.",
        "",
        f"BOOT_LOADING_BG_W EQU {bg_meta['w']}",
        f"BOOT_LOADING_BG_H EQU {bg_meta['h']}",
        f"BOOT_LOADING_BG_PAGES EQU {bg_pages}",
        f"BOOT_LOADING_BG_PAGE_BASE EQU #{BG_PAGE_BASE:02X}",
        f"BOOT_LOADING_BG_C0_OFFSET EQU #{bg_meta['c0_offset']:06X}",
        f"BOOT_LOADING_BG_C1_OFFSET EQU #{bg_meta['c1_offset']:06X}",
        f"BOOT_LOADING_BG_MASK_OFFSET EQU #{bg_meta['mask_offset']:06X}",
        f"BOOT_LOADING_BG_RAW_SIZE EQU #{bg_meta['raw_size']:06X}",
        f"BOOT_LOADING_BG_COLOR_STRIDE EQU {bg_meta['color_stride']}",
        f"BOOT_LOADING_BG_COLOR_H EQU {bg_meta['color_height']}",
        f"BOOT_LOADING_BG_MASK_STRIDE EQU {bg_meta['mask_stride']}",
        f"BOOT_LOADING_BAR_W EQU {bar_w}",
        f"BOOT_LOADING_BAR_H EQU {bar_h}",
        f"BOOT_LOADING_BAR_PAGES EQU {bar_pages}",
        f"BOOT_LOADING_BAR_PAGE_BASE EQU #{BAR_PAGE_BASE:02X}",
        f"BOOT_TS_ANIM_W EQU {anim_w}",
        f"BOOT_TS_ANIM_H EQU {anim_h}",
        f"BOOT_TS_ANIM_FRAMES EQU {len(ANIM_FILES)}",
        f"BOOT_TS_ANIM_ATLAS_H EQU {anim_h * len(ANIM_FILES)}",
        f"BOOT_TS_ANIM_PAGES EQU {anim_pages}",
        f"BOOT_TS_ANIM_PAGE_BASE EQU #{ANIM_PAGE_BASE:02X}",
        "",
    ]
    INC.write_text("\n".join(lines), encoding="utf-8")

    print(f"boot loading bg DXT-L4: {bg_meta['w']}x{bg_meta['h']}, raw={bg_meta['raw_size']} bytes, {bg_pages} pages")
    print(f"boot loading bar: {bar_w}x{bar_h}, {bar_pages} pages")
    print(f"boot ts anim: {anim_w}x{anim_h}, {anim_pages} pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
