#!/usr/bin/env python3
"""Render a diagnostic L09 tunnel frame from the full-stack shadow FT812 run.

The repository FT812 emulator captures RAM_G/RAM_DL and display-list commands;
it does not rasterize pixels. This script uses that real run for state/DL order
and writes a host-side PNG so tunnel coverage can be inspected.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from audit_level5_ft812_budget import cmd_frame  # noqa: E402
from profile_dual_chain_perf import Harness  # noqa: E402
from shadow_ft812 import disasm_dl, format_dl  # noqa: E402

LEVEL_NUM = 9
LEVEL_INDEX = LEVEL_NUM - 1
LEVEL_DIR = "09-underover"
REF_LEVEL_DIR = "underover"
WARM_FRAMES = 150
OUT_DIR = ROOT / "Diagnostics" / "tunnel_frames"
OUT_PNG = OUT_DIR / "l09_eve_shadow_tunnel_frame.png"
OUT_DL = OUT_DIR / "l09_eve_shadow_tunnel_frame.dl.txt"

TRACKF_TUNNEL = 0x01
BALL_SIZE = 32
CELL_SIZE = 32
BALL_SRC = Path.home() / "Desktop" / "Zuma Deluxe" / "graphics" / "Zuma Deluxe - Gameplay - Balls.png"


def read_argb4_palette(path: Path) -> list[tuple[int, int, int, int]]:
    raw = path.read_bytes()
    out: list[tuple[int, int, int, int]] = []
    for i in range(0, min(len(raw), 512), 2):
        value = raw[i] | (raw[i + 1] << 8)
        a = ((value >> 12) & 0xF) * 17
        r = ((value >> 8) & 0xF) * 17
        g = ((value >> 4) & 0xF) * 17
        b = (value & 0xF) * 17
        out.append((r, g, b, a))
    return out


def decode_bg() -> Image.Image:
    pixels = (ROOT / "Graphics" / "levels" / "Converted" / "pack" / "bg_l09_paletted.bin").read_bytes()
    pal = read_argb4_palette(ROOT / "Graphics" / "levels" / "Converted" / "pack" / "bg_l09_palette_argb4.bin")
    img = Image.new("RGBA", (400, 300))
    data = [pal[p] if p < len(pal) else (0, 0, 0, 255) for p in pixels[: 400 * 300]]
    img.putdata(data)
    return img.resize((640, 480), Image.Resampling.NEAREST)


def load_track() -> list[tuple[int, int, int, int]]:
    raw = (ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l09_640.bin").read_bytes()
    count = struct.unpack_from("<H", raw, 0)[0]
    rows = []
    for i in range(count):
        rows.append(struct.unpack_from("<hhBB", raw, 2 + i * 6))
    return rows


def load_ball_sprites() -> list[Image.Image]:
    sheet = Image.open(BALL_SRC).convert("RGBA")
    sprites: list[Image.Image] = []
    for color in range(6):
        # Classic source sheet stores color rows as 32x32 cells.
        sprite = sheet.crop((0, color * BALL_SIZE, BALL_SIZE, color * BALL_SIZE + BALL_SIZE))
        sprites.append(sprite)
    return sprites


def sx(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def parse_l09_top_records() -> list[dict[str, int]]:
    text = (ROOT / "Source" / "ASM" / "top_mask_overlay_meta.inc").read_text(encoding="utf-8")
    block = text.split("TopMaskL09: ; underover", 1)[1].split("TopMaskL10:", 1)[0]
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    head = lines[0].replace(":", " ").split()
    count = int(head[1])
    offset = int(head[3].lstrip("#"), 16)
    meta = (ROOT / "Graphics" / "levels" / "Converted" / "top_masks" / "top_mask_meta.bin").read_bytes()
    records: list[dict[str, int]] = []
    for i in range(count):
        rec = meta[offset + i * 36 : offset + (i + 1) * 36]
        page = rec[0]
        src_offset = int.from_bytes(rec[1:3], "little")
        ram_lo = int.from_bytes(rec[3:5], "little")
        ram_hi = rec[5]
        size = int.from_bytes(rec[6:8], "little")
        cmds = [int.from_bytes(rec[8 + j * 4 : 12 + j * 4], "little") for j in range(7)]
        color, source, layout_h, layout, size_h, bsize, vertex = cmds
        stride = (((layout_h >> 2) & 3) << 10) | ((layout >> 9) & 0x3FF)
        height = ((layout_h & 3) << 9) | (layout & 0x1FF)
        draw_w = (((size_h >> 2) & 3) << 9) | ((bsize >> 9) & 0x1FF)
        draw_h = ((size_h & 3) << 9) | (bsize & 0x1FF)
        x16 = sx((vertex >> 15) & 0x7FFF, 15)
        y16 = sx(vertex & 0x7FFF, 15)
        records.append(
            {
                "page": page,
                "src_offset": src_offset,
                "ramg": (ram_hi << 16) | ram_lo,
                "size": size,
                "r": (color >> 16) & 0xFF,
                "g": (color >> 8) & 0xFF,
                "b": color & 0xFF,
                "source": source & 0x3FFFFF,
                "stride": stride,
                "height": height,
                "draw_w": draw_w,
                "draw_h": draw_h,
                "x": round(x16 / 16),
                "y": round(y16 / 16),
            }
        )
    return records


def argb4_image(raw: bytes, stride: int, height: int) -> Image.Image:
    width = stride // 2
    pixels: list[tuple[int, int, int, int]] = []
    for y in range(height):
        row = y * stride
        for x in range(width):
            value = raw[row + x * 2] | (raw[row + x * 2 + 1] << 8)
            a = ((value >> 12) & 0xF) * 17
            r = ((value >> 8) & 0xF) * 17
            g = ((value >> 4) & 0xF) * 17
            b = (value & 0xF) * 17
            pixels.append((r, g, b, a))
    img = Image.new("RGBA", (width, height))
    img.putdata(pixels)
    return img


def render_top_masks(frame: Image.Image) -> None:
    mask_dir = ROOT / "Graphics" / "levels" / "Converted" / "top_masks"
    records = parse_l09_top_records()
    for rec in records:
        path = mask_dir / f"top_mask_page_{rec['page']:02x}.bin"
        raw = path.read_bytes()[rec["src_offset"] : rec["src_offset"] + rec["size"]]
        color = argb4_image(raw, rec["stride"], rec["height"])
        color = color.resize((rec["draw_w"], rec["draw_h"]), Image.Resampling.NEAREST)
        frame.alpha_composite(color, (rec["x"], rec["y"]))


def render_chain(h: Harness, frame: Image.Image) -> tuple[int, int]:
    track = load_track()
    balls = load_ball_sprites()
    e = h.e
    S = h.S
    hsa = e.get_word(S["Core.VDC_HSA"])
    hsub = e.get_byte(S["Core.VDC_HSub"])
    length = e.get_byte(S["Core.VDC_SlotsLen"])
    drawn = tunnel = 0
    for i in range(length):
        color = e.get_byte(S["Core.VDC_Slots"] + i)
        if color >= len(balls):
            continue
        off = e.get_byte(S["Core.VDC_Offsets"] + i)
        off = off - 256 if off >= 128 else off
        sample = hsa * CELL_SIZE + hsub - i * CELL_SIZE + off
        if sample < 0 or sample >= len(track):
            continue
        x, y, _tan, flags = track[sample]
        frame.alpha_composite(balls[color], (x - BALL_SIZE // 2, y - BALL_SIZE // 2))
        drawn += 1
        if flags & TRACKF_TUNNEL:
            tunnel += 1
    return drawn, tunnel


def field_addr(op) -> int | None:
    value = op.fields.get("addr")
    if isinstance(value, str) and value.startswith("#"):
        return int(value[1:], 16)
    return None


def is_top_mask_addr(addr: int | None) -> bool:
    if addr is None:
        return False
    return (
        0x080400 <= addr < 0x084000
        or 0x0AC000 <= addr < 0x0CC000
        or 0x0FC000 <= addr < 0x100000
    )


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    h = Harness(LEVEL_INDEX)
    h.setup()
    h.run_play_frames(WARM_FRAMES)
    data = cmd_frame(h)
    ops = disasm_dl(data, max_ops=4096, stop_at_display=False)
    OUT_DL.write_text(format_dl(ops), encoding="utf-8")

    ball_sources = [i for i, op in enumerate(ops) if op.name == "BITMAP_SOURCE" and field_addr(op) == 0x050000]
    top_sources = [i for i, op in enumerate(ops) if op.name == "BITMAP_SOURCE" and is_top_mask_addr(field_addr(op))]
    if not ball_sources:
        print("FAIL: no balls BITMAP_SOURCE #050000 in captured FT812 DL")
        return 1
    if not top_sources:
        print("FAIL: no top-mask BITMAP_SOURCE inside #080400..#084000/#0AC000..#0CC000/#0FC000..#100000 in captured FT812 DL")
        return 1
    if min(top_sources) <= min(ball_sources):
        print(f"FAIL: top mask is not after chain balls in DL: balls={ball_sources[:4]} top={top_sources[:4]}")
        return 1

    frame = decode_bg()
    drawn, tunnel = render_chain(h, frame)
    render_top_masks(frame)

    draw = ImageDraw.Draw(frame, "RGBA")
    draw.rectangle((0, 0, 639, 479), outline=(255, 255, 255, 180), width=1)
    frame.convert("RGB").save(OUT_PNG)

    print(f"PASS: shadow FT812 DL captured for L09 after {WARM_FRAMES} warm frames")
    print(f"DL: balls source last index={max(ball_sources)}, top-mask source last index={max(top_sources)}")
    print(f"chain: drawn={drawn}, tunnel_samples={tunnel}")
    print(f"wrote {OUT_PNG}")
    print(f"wrote {OUT_DL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
