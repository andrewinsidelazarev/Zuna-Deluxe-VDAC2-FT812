#!/usr/bin/env python3
"""Build 400x300 FT_L4 tunnel top masks from the HD reference image-top PNGs."""
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
FIRST_PAGE = 0xCC
MIN_COMPONENT_PIXELS = 64
ALPHA_THRESHOLD = 8
DIFF_THRESHOLD = 48

WINDOWS = [
    (0x080400, 0x084000),
    (0x0FC000, 0x100000),
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

FT_L4 = 2
FT_NEAREST = 0
FT_BORDER = 0
TOP_MASK_HANDLE = 8
TOP_MASK_REC_SIZE = 34
TOP_MASK_CMD_BYTES = 28


@dataclass
class Component:
    level: str
    index: int
    page: int
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


def pack_l4(alpha: Image.Image) -> tuple[bytes, int]:
    w, h = alpha.size
    stride = (w + 1) // 2
    pix = alpha.load()
    out = bytearray(stride * h)
    for y in range(h):
        row = y * stride
        for x in range(w):
            nib = min(15, max(0, (pix[x, y] + 8) // 17))
            if x & 1:
                out[row + x // 2] |= nib
            else:
                out[row + x // 2] |= nib << 4
    return bytes(out), stride


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
    sx = (x * 16 * 8 + 2) // 5
    sy = (y * 16 * 8 + 2) // 5
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
    components: list[Component] = []

    for level in RUNTIME_LEVELS:
        if level not in TOP_IMAGE_LEVELS:
            continue
        cursors = [w[0] for w in WINDOWS]
        src = REF / level / f"{level}.png"
        if not src.exists():
            raise FileNotFoundError(src)
        img = fit_native(Image.open(src).convert("RGBA"))
        alpha = level_top_alpha(level, img)
        for idx, (x0, y0, x1, y1, _count) in enumerate(alpha_components(alpha)):
            crop = alpha.crop((x0, y0, x1, y1))
            data, stride = pack_l4(crop)
            ramg = allocate(len(data), cursors)
            name = f"top_mask_l{RUNTIME_LEVELS.index(level) + 1:02d}_{level}_{idx:02d}.bin"
            path = OUT / name
            path.write_bytes(data)
            draw_w = ((x1 - x0) * 8 + 4) // 5
            draw_h = ((y1 - y0) * 8 + 4) // 5
            commands = [cmd_color_rgb(average_rgb(img, (x0, y0, x1, y1))), cmd_bitmap_source(ramg)]
            commands += cmd_bitmap_layout(FT_L4, stride, y1 - y0)
            commands += cmd_bitmap_size(draw_w, draw_h)
            commands.append(cmd_vertex2f_scaled(x0, y0))
            components.append(
                Component(
                    level=level,
                    index=idx,
                    page=page,
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
            page += 1
            if page > 0xFF:
                raise RuntimeError("top mask SPG pages exceeded #FF")

    return components


def write_meta(components: list[Component]) -> None:
    by_level: dict[str, list[Component]] = {name: [] for name in RUNTIME_LEVELS}
    for comp in components:
        by_level[comp.level].append(comp)

    lines: list[str] = [
        "; Auto-generated by Source/OTHER/make_top_mask_overlays.py.",
        "TOP_MASK_ENABLED EQU 1",
        "TOP_MASK_HANDLE EQU 8",
        "TOP_MASK_FIRST_PAGE EQU #CC",
        "TOP_MASK_RAMG_A EQU #080400",
        "TOP_MASK_RAMG_A_END EQU #084000",
        "TOP_MASK_RAMG_B EQU #0FC000",
        "TOP_MASK_RAMG_B_END EQU #100000",
        f"TOP_MASK_REC_SIZE EQU {TOP_MASK_REC_SIZE}",
        f"TOP_MASK_CMD_OFFSET EQU 6",
        f"TOP_MASK_CMD_BYTES EQU {TOP_MASK_CMD_BYTES}",
        "TopMaskLevelTable:",
    ]
    for idx, level in enumerate(RUNTIME_LEVELS, start=1):
        lines.append(f"                DW TopMaskL{idx:02d} ; {level}")
    lines.append("")

    for idx, level in enumerate(RUNTIME_LEVELS, start=1):
        comps = by_level[level]
        lines.append(f"TopMaskL{idx:02d}: ; {level}")
        lines.append(f"                DB {len(comps)}")
        for comp in comps:
            lines.append(
                "                DB #{page:02X} : DW #{raml:04X} : DB #{ramh:02X} : DW {size}".format(
                    page=comp.page,
                    raml=comp.ramg & 0xFFFF,
                    ramh=(comp.ramg >> 16) & 0xFF,
                    size=comp.size,
                )
            )
            words = []
            for cmd in comp.commands:
                words.append(f"#{cmd & 0xFFFF:04X}, #{(cmd >> 16) & 0xFFFF:04X}")
            lines.append(f"                DW {', '.join(words)}")
        lines.append("")
    ASM_OUT.write_text("\n".join(lines), encoding="ascii")

    spg = ["; Auto-generated by Source/OTHER/make_top_mask_overlays.py."]
    for comp in components:
        spg.append(f"Block = #0000, #{comp.page:02X}, {comp.file.as_posix()}")
    SPGBLD_OUT.write_text("\n".join(spg) + "\n", encoding="ascii")


def main() -> int:
    comps = build()
    write_meta(comps)
    by_level: dict[str, int] = {}
    for comp in comps:
        by_level[comp.level] = by_level.get(comp.level, 0) + comp.size
    for level, total in by_level.items():
        print(f"{level}: {total} bytes")
    print(f"components={len(comps)} pages=#{FIRST_PAGE:02X}..#{FIRST_PAGE + len(comps) - 1:02X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
