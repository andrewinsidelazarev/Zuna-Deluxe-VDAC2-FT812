#!/usr/bin/env python3
"""Build 400x300 FT_ARGB4 tunnel top-cover tiles from the HD reference image-top PNGs."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path
import sys

from PIL import Image, ImageChops

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
REF = Path.home() / "Desktop" / "Zuma-Deluxe-HD-release-v010-ref" / "content" / "levels"
OUT = ROOT / "Graphics" / "levels" / "Converted" / "top_masks"
ASM_OUT = ROOT / "Source" / "ASM" / "top_mask_overlay_meta.inc"
SPGBLD_OUT = ROOT / "Source" / "ASM" / "top_mask_spgbld_blocks.inc"

NATIVE_SIZE = (400, 300)
META_PAGE = 0xCC
FIRST_PAGE = 0xCD
PAGE_SIZE = 0x4000
TILE_W = 64
TILE_H = 64
MIN_TILE_BYTES = 256
MIN_COMPONENT_PIXELS = 64
ALPHA_THRESHOLD = 8
DIFF_THRESHOLD = 48

WINDOWS = [
    (0x080400, 0x084000),
    (0x0FC000, 0x100000),
    (0x0AC000, 0x0CC000),
]

RUNTIME_LEVELS = [
    "spiral",
    "claw",
    "riverbed",
    "targetglyph",
    "blackswirley",
    "turnaround",
    "longrange",
    "tiltspiral",
    "underover",
    "warshak",
    "loopy",
    "snakepit",
    "groovefest",
    "spaceinvaders",
    "triangle",
    "coaster",
    "squaresville",
    "tunnellevel",
    "serpents",
    "overunder",
    "inversespiral",
    "space",
]

TOP_IMAGE_LEVELS = {
    "underover",
    "loopy",
    "groovefest",
    "spaceinvaders",
    "coaster",
    "tunnellevel",
    "overunder",
    "inversespiral",
}

FT_ARGB4 = 6
FT_NEAREST = 0
FT_BORDER = 0
TOP_MASK_HANDLE = 8
TOP_MASK_REC_SIZE = 36
TOP_MASK_CMD_BYTES = 28


@dataclass
class Component:
    level: str
    index: int
    page: int
    src_offset: int
    ramg: int
    x: int
    y: int
    w: int
    h: int
    stride: int
    size: int
    draw_w: int
    draw_h: int
    commands: list[int]
    file: Path


def align4(value: int) -> int:
    return (value + 3) & ~3


def fit_native(img: Image.Image) -> Image.Image:
    w, h = img.size
    target_w, target_h = 4, 3
    if w * target_h > h * target_w:
        crop_w = h * target_w // target_h
        x0 = (w - crop_w) // 2
        img = img.crop((x0, 0, x0 + crop_w, h))
    elif w * target_h < h * target_w:
        crop_h = w * target_h // target_w
        y0 = (h - crop_h) // 2
        img = img.crop((0, y0, w, y0 + crop_h))
    return img.resize(NATIVE_SIZE, Image.Resampling.LANCZOS)


def alpha_components(alpha: Image.Image) -> list[tuple[int, int, int, int, int]]:
    w, h = alpha.size
    pix = alpha.load()
    seen = bytearray(w * h)
    comps: list[tuple[int, int, int, int, int]] = []
    for y in range(h):
        for x in range(w):
            pos = y * w + x
            if seen[pos] or pix[x, y] <= ALPHA_THRESHOLD:
                continue
            q = deque([(x, y)])
            seen[pos] = 1
            xmin = xmax = x
            ymin = ymax = y
            count = 0
            while q:
                cx, cy = q.popleft()
                count += 1
                if cx < xmin:
                    xmin = cx
                if cx > xmax:
                    xmax = cx
                if cy < ymin:
                    ymin = cy
                if cy > ymax:
                    ymax = cy
                for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                    if nx < 0 or ny < 0 or nx >= w or ny >= h:
                        continue
                    ni = ny * w + nx
                    if seen[ni] or pix[nx, ny] <= ALPHA_THRESHOLD:
                        continue
                    seen[ni] = 1
                    q.append((nx, ny))
            if count >= MIN_COMPONENT_PIXELS:
                comps.append((xmin, ymin, xmax + 1, ymax + 1, count))
    comps.sort(key=lambda c: (c[1], c[0]))
    return comps


def pack_argb4(tile: Image.Image, alpha: Image.Image) -> tuple[bytes, int]:
    w, h = tile.size
    rgba = tile.convert("RGBA")
    rgba.putalpha(alpha)
    pix = rgba.load()
    out = bytearray(w * h * 2)
    p = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = pix[x, y]
            word = (((a >> 4) & 0xF) << 12) | (((r >> 4) & 0xF) << 8) | (((g >> 4) & 0xF) << 4) | ((b >> 4) & 0xF)
            out[p] = word & 0xFF
            out[p + 1] = (word >> 8) & 0xFF
            p += 2
    return bytes(out), w * 2


def level_top_alpha(level: str, top: Image.Image) -> Image.Image:
    """Return the actual top-cover mask for a level.

    The HD-ref PNGs are not guaranteed to carry useful transparency. For the
    tunnel levels the PNG is the "with top" image and the JPG is the base layer;
    the top mask is their RGB difference.
    """
    alpha = top.getchannel("A")
    amin, amax = alpha.getextrema()
    if amin <= ALPHA_THRESHOLD and amax > ALPHA_THRESHOLD:
        return alpha

    jpg = REF / level / f"{level}.jpg"
    if jpg.exists():
        base = fit_native(Image.open(jpg).convert("RGB"))
        diff = ImageChops.difference(top.convert("RGB"), base).convert("L")
        return diff.point(lambda v: 255 if v > DIFF_THRESHOLD else 0, mode="L")

    return alpha


def cmd_bitmap_source(addr: int) -> int:
    return 0x01000000 | (addr & 0x3FFFFF)


def cmd_color_rgb(rgb: tuple[int, int, int]) -> int:
    r, g, b = rgb
    return 0x04000000 | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)


def cmd_bitmap_layout(fmt: int, stride: int, height: int) -> list[int]:
    return [
        0x28000000 | (((stride >> 10) & 0x03) << 2) | ((height >> 9) & 0x03),
        0x07000000 | ((fmt & 0x1F) << 19) | ((stride & 0x03FF) << 9) | (height & 0x01FF),
    ]


def cmd_bitmap_size(width: int, height: int) -> list[int]:
    return [
        0x29000000 | (((width >> 9) & 0x03) << 2) | ((height >> 9) & 0x03),
        0x08000000
        | ((FT_NEAREST & 0x01) << 20)
        | ((FT_BORDER & 0x01) << 19)
        | ((FT_BORDER & 0x01) << 18)
        | ((width & 0x01FF) << 9)
        | (height & 0x01FF),
    ]


def cmd_vertex2f_scaled(x: int, y: int) -> int:
    # 1024×768: тайлы в 400×300-пространстве, экран = ×2.56 (= ×64/25).
    # (×8/5 был для 640-эпохи: 400→640.) Матрица overlay = ZL_BG_SCALE 2.56.
    sx = (x * 16 * 64 + 12) // 25
    sy = (y * 16 * 64 + 12) // 25
    return 0x40000000 | ((sx & 0x7FFF) << 15) | (sy & 0x7FFF)


def average_rgb(img: Image.Image, bbox: tuple[int, int, int, int]) -> tuple[int, int, int]:
    crop = img.crop(bbox)
    pixels = crop.getdata()
    total_a = 0
    sums = [0, 0, 0]
    for r, g, b, a in pixels:
        if a <= ALPHA_THRESHOLD:
            continue
        total_a += a
        sums[0] += r * a
        sums[1] += g * a
        sums[2] += b * a
    if total_a == 0:
        return (128, 96, 64)
    return tuple(max(0, min(255, (value + total_a // 2) // total_a)) for value in sums)


def allocate(size: int, cursors: list[int]) -> int:
    size4 = align4(size)
    for i, (start, end) in enumerate(WINDOWS):
        pos = cursors[i]
        if pos + size4 <= end:
            cursors[i] = pos + size4
            return pos
    used = sum(cur - start for cur, (start, _end) in zip(cursors, WINDOWS))
    cap = sum(end - start for start, end in WINDOWS)
    raise RuntimeError(f"top masks do not fit RAM_G windows; component={size4} used={used} cap={cap}")


def build() -> list[Component]:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("top_mask_*.bin"):
        old.unlink()

    page = FIRST_PAGE
    page_data = bytearray()
    page_files: list[tuple[int, Path, bytes]] = []
    components: list[Component] = []

    def flush_page() -> None:
        nonlocal page, page_data
        if not page_data:
            return
        name = f"top_mask_page_{page:02x}.bin"
        path = OUT / name
        payload = bytes(page_data)
        path.write_bytes(payload)
        page_files.append((page, path.relative_to(ROOT), payload))
        page += 1
        if page > 0xFF:
            raise RuntimeError("top mask SPG pages exceeded #FF")
        page_data = bytearray()

    def pack_page(data: bytes) -> tuple[int, int, Path]:
        nonlocal page_data
        if len(data) > PAGE_SIZE:
            raise RuntimeError(f"single top-mask tile is too large for one SPG page: {len(data)} bytes")
        if page_data and len(page_data) + len(data) > PAGE_SIZE:
            flush_page()
        src_offset = len(page_data)
        page_data.extend(data)
        return page, src_offset, OUT / f"top_mask_page_{page:02x}.bin"

    for level in RUNTIME_LEVELS:
        if level not in TOP_IMAGE_LEVELS:
            continue
        cursors = [w[0] for w in WINDOWS]
        src = REF / level / f"{level}.png"
        if not src.exists():
            raise FileNotFoundError(src)
        img = fit_native(Image.open(src).convert("RGBA"))
        alpha = level_top_alpha(level, img)
        thresholded = alpha.point(lambda v: v if v > ALPHA_THRESHOLD else 0, mode="L")
        idx = 0
        for ty in range(0, NATIVE_SIZE[1], TILE_H):
            for tx in range(0, NATIVE_SIZE[0], TILE_W):
                tile = thresholded.crop((tx, ty, min(tx + TILE_W, NATIVE_SIZE[0]), min(ty + TILE_H, NATIVE_SIZE[1])))
                bbox = tile.getbbox()
                if not bbox:
                    continue
                bx0, by0, bx1, by1 = bbox
                x0, y0 = tx + bx0, ty + by0
                x1, y1 = tx + bx1, ty + by1
                alpha_crop = thresholded.crop((x0, y0, x1, y1))
                if not alpha_crop.getbbox():
                    continue
                color_crop = img.crop((x0, y0, x1, y1))
                data, stride = pack_argb4(color_crop, alpha_crop)
                if len(data) < MIN_TILE_BYTES:
                    continue
                ramg = allocate(len(data), cursors)
                src_page, src_offset, path = pack_page(data)
                # 1024×768: окно тайла = native×2.56 (UV-матрица ZL_BG_SCALE)
                draw_w = ((x1 - x0) * 64 + 12) // 25
                draw_h = ((y1 - y0) * 64 + 12) // 25
                commands = [cmd_color_rgb((255, 255, 255)), cmd_bitmap_source(ramg)]
                commands += cmd_bitmap_layout(FT_ARGB4, stride, y1 - y0)
                commands += cmd_bitmap_size(draw_w, draw_h)
                commands.append(cmd_vertex2f_scaled(x0, y0))
                components.append(
                    Component(
                        level=level,
                        index=idx,
                        page=src_page,
                        src_offset=src_offset,
                        ramg=ramg,
                        x=x0,
                        y=y0,
                        w=x1 - x0,
                        h=y1 - y0,
                        stride=stride,
                        size=len(data),
                        draw_w=draw_w,
                        draw_h=draw_h,
                        commands=commands,
                        file=path.relative_to(ROOT),
                    )
                )
                idx += 1

    flush_page()
    build.page_files = page_files  # type: ignore[attr-defined]
    return components


def write_meta(components: list[Component]) -> None:
    by_level: dict[str, list[Component]] = {name: [] for name in RUNTIME_LEVELS}
    for comp in components:
        by_level[comp.level].append(comp)

    lines: list[str] = [
        "; Auto-generated by Source/OTHER/make_top_mask_overlays.py.",
        "TOP_MASK_ENABLED EQU 1",
        "TOP_MASK_HANDLE EQU 8",
        f"TOP_MASK_META_PAGE EQU #{META_PAGE:02X}",
        f"TOP_MASK_FIRST_PAGE EQU #{FIRST_PAGE:02X}",
        "TOP_MASK_RAMG_A EQU #080400",
        "TOP_MASK_RAMG_A_END EQU #084000",
        "TOP_MASK_RAMG_B EQU #0FC000",
        "TOP_MASK_RAMG_B_END EQU #100000",
        "TOP_MASK_RAMG_SWAP EQU #0AC000",
        "TOP_MASK_RAMG_SWAP_END EQU #0CC000",
        f"TOP_MASK_REC_SIZE EQU {TOP_MASK_REC_SIZE}",
        f"TOP_MASK_CMD_OFFSET EQU 8",
        f"TOP_MASK_CMD_BYTES EQU {TOP_MASK_CMD_BYTES}",
        "TopMaskLevelTable:",
    ]
    for idx, level in enumerate(RUNTIME_LEVELS, start=1):
        lines.append(f"                DW TopMaskL{idx:02d} ; {level}")
    lines.append("")

    meta = bytearray()
    for idx, level in enumerate(RUNTIME_LEVELS, start=1):
        comps = by_level[level]
        offset = len(meta)
        lines.append(f"TopMaskL{idx:02d}: ; {level}")
        lines.append(f"                DB {len(comps)} : DW #{offset:04X}")
        for comp in comps:
            meta.append(comp.page)
            meta.extend(comp.src_offset.to_bytes(2, "little"))
            meta.extend((comp.ramg & 0xFFFF).to_bytes(2, "little"))
            meta.append((comp.ramg >> 16) & 0xFF)
            meta.extend(comp.size.to_bytes(2, "little"))
            for cmd in comp.commands:
                meta.extend((cmd & 0xFFFFFFFF).to_bytes(4, "little"))
        lines.append("")
    if len(meta) > PAGE_SIZE:
        raise RuntimeError(f"top-mask meta page overflow: {len(meta)} bytes")
    meta_path = OUT / "top_mask_meta.bin"
    meta_path.write_bytes(bytes(meta))
    ASM_OUT.write_text("\n".join(lines), encoding="ascii")

    spg = ["; Auto-generated by Source/OTHER/make_top_mask_overlays.py."]
    spg.append(f"Block = #0000, #{META_PAGE:02X}, {meta_path.relative_to(ROOT).as_posix()}")
    for page_num, rel, _payload in getattr(build, "page_files", []):
        spg.append(f"Block = #0000, #{page_num:02X}, {rel.as_posix()}")
    SPGBLD_OUT.write_text("\n".join(spg) + "\n", encoding="ascii")


def main() -> int:
    comps = build()
    write_meta(comps)
    by_level: dict[str, int] = {}
    for comp in comps:
        by_level[comp.level] = by_level.get(comp.level, 0) + comp.size
    for level, total in by_level.items():
        print(f"{level}: {total} bytes")
    packed = getattr(build, "page_files", [])
    if packed:
        first = packed[0][0]
        last = packed[-1][0]
        print(f"components={len(comps)} packed_pages={len(packed)} pages=#{first:02X}..#{last:02X}")
    else:
        print(f"components={len(comps)} packed_pages=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
