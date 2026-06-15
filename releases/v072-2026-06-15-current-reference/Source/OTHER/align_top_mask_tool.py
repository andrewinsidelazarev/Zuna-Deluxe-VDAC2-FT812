#!/usr/bin/env python3
"""Interactive tunnel top-mask alignment helper.

Shows the runtime 640x480 level background and a top-mask overlay.

Default mask source is HD-ref geometry:
  1280x720/16:9 image-top -> center crop to 960x720/4:3 -> scale /1.5 to 640x480.

Drag the mask with the mouse or use arrow keys. On close, writes dx/dy to
Diagnostics/tunnel_frames/lNN_mask_offset.json and prints it.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from tkinter import BOTH, NW, Canvas, Tk

from PIL import Image, ImageTk

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT_DIR = ROOT / "Diagnostics" / "tunnel_frames"

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

LEVEL_NUMS = {name: i + 1 for i, name in enumerate(RUNTIME_LEVELS)}
NATIVE = (400, 300)
SCREEN = (640, 480)
REF = Path.home() / "Desktop" / "Zuma-Deluxe-HD-release-v010-ref" / "content" / "levels"


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


def decode_bg(level_num: int) -> Image.Image:
    pack = ROOT / "Graphics" / "levels" / "Converted" / "pack"
    pixels = (pack / f"bg_l{level_num:02d}_paletted.bin").read_bytes()
    pal = read_argb4_palette(pack / f"bg_l{level_num:02d}_palette_argb4.bin")
    img = Image.new("RGBA", NATIVE)
    img.putdata([pal[p] if p < len(pal) else (0, 0, 0, 255) for p in pixels[: NATIVE[0] * NATIVE[1]]])
    return img.resize(SCREEN, Image.Resampling.NEAREST)


def crop_16x9_to_4x3(img: Image.Image) -> Image.Image:
    w, h = img.size
    crop_w = h * 4 // 3
    if crop_w > w:
        crop_h = w * 3 // 4
        y0 = (h - crop_h) // 2
        return img.crop((0, y0, w, y0 + crop_h))
    x0 = (w - crop_w) // 2
    return img.crop((x0, 0, x0 + crop_w, h))


def alpha_from_hdcrop(level_name: str, tint: tuple[int, int, int], alpha_scale: float) -> Image.Image:
    src = REF / level_name / f"{level_name}.png"
    if not src.exists():
        raise FileNotFoundError(src)
    img = Image.open(src).convert("RGBA")
    cropped = crop_16x9_to_4x3(img)
    scaled = cropped.resize(SCREEN, Image.Resampling.LANCZOS)
    alpha = scaled.getchannel("A")
    if alpha.getextrema() == (255, 255):
        # Some viewers show the PNG as opaque even if it visually represents
        # a top image. In that case use RGB luminance as an alignment overlay.
        alpha = scaled.convert("L")
    if alpha_scale != 1.0:
        alpha = alpha.point(lambda v: max(0, min(255, round(v * alpha_scale))))
    mask = Image.new("RGBA", SCREEN, (*tint, 0))
    mask.putalpha(alpha)
    return mask


def sx(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def parse_level_records(level_num: int, level_name: str) -> list[dict[str, int]]:
    meta = (ROOT / "Source" / "ASM" / "top_mask_overlay_meta.inc").read_text(encoding="utf-8")
    start = f"TopMaskL{level_num:02d}: ; {level_name}"
    m = re.search(re.escape(start) + r"\n(?P<body>.*?)(?=\nTopMaskL\d\d:|\Z)", meta, re.S)
    if not m:
        raise RuntimeError(f"{start} not found in top_mask_overlay_meta.inc")
    lines = [line.strip() for line in m.group("body").splitlines() if line.strip()]
    if not lines or not lines[0].startswith("DB "):
        return []
    records: list[dict[str, int]] = []
    i = 1
    while i + 1 < len(lines):
        head = lines[i]
        words_line = lines[i + 1]
        if not head.startswith("DB #"):
            i += 1
            continue
        nums = re.findall(r"#([0-9A-Fa-f]+)|\b(\d+)\b", head)
        vals = [int(a or b, 16 if a else 10) for a, b in nums]
        if len(vals) < 5:
            raise RuntimeError(f"bad record header: {head}")
        page, src_offset, ram_lo, ram_hi, size = vals[:5]
        words = [int(x, 16) for x in re.findall(r"#([0-9A-Fa-f]+)", words_line)]
        cmds = [words[j] | (words[j + 1] << 16) for j in range(0, len(words), 2)]
        if len(cmds) != 7:
            raise RuntimeError(f"expected 7 DL commands, got {len(cmds)} in {words_line}")
        _color, _source, layout_h, layout, size_h, bsize, vertex = cmds
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
                "stride": stride,
                "height": height,
                "draw_w": draw_w,
                "draw_h": draw_h,
                "x": round(x16 / 16),
                "y": round(y16 / 16),
            }
        )
        i += 2
    return records


def l4_alpha(raw: bytes, stride: int, height: int) -> Image.Image:
    width = stride * 2
    out = bytearray(width * height)
    for y in range(height):
        row = y * stride
        dst = y * width
        for xb in range(stride):
            value = raw[row + xb]
            out[dst + xb * 2] = ((value >> 4) & 0xF) * 17
            out[dst + xb * 2 + 1] = (value & 0xF) * 17
    img = Image.new("L", (width, height))
    img.frombytes(bytes(out))
    return img


def build_generated_mask(level_num: int, level_name: str, tint: tuple[int, int, int], alpha_scale: float) -> Image.Image:
    records = parse_level_records(level_num, level_name)
    mask_dir = ROOT / "Graphics" / "levels" / "Converted" / "top_masks"
    mask = Image.new("RGBA", SCREEN, (0, 0, 0, 0))
    for rec in records:
        path = mask_dir / f"top_mask_page_{rec['page']:02x}.bin"
        raw = path.read_bytes()[rec["src_offset"] : rec["src_offset"] + rec["size"]]
        a = l4_alpha(raw, rec["stride"], rec["height"])
        if alpha_scale != 1.0:
            a = a.point(lambda v: max(0, min(255, round(v * alpha_scale))))
        comp = Image.new("RGBA", a.size, (*tint, 0))
        comp.putalpha(a)
        comp = comp.resize((rec["draw_w"], rec["draw_h"]), Image.Resampling.NEAREST)
        mask.alpha_composite(comp, (rec["x"], rec["y"]))
    return mask


class AlignApp:
    def __init__(self, bg: Image.Image, mask: Image.Image, level_num: int, alpha: int) -> None:
        self.bg = bg
        self.mask = mask
        self.level_num = level_num
        self.alpha = alpha
        self.dx = 0
        self.dy = 0
        self.drag_start: tuple[int, int, int, int] | None = None

        self.root = Tk()
        self.root.title("")
        self.canvas = Canvas(self.root, width=SCREEN[0], height=SCREEN[1], highlightthickness=0)
        self.canvas.pack(fill=BOTH, expand=False)
        self.bg_tk = ImageTk.PhotoImage(self.bg)
        self.mask_tk = ImageTk.PhotoImage(self.mask)
        self.canvas.create_image(0, 0, anchor=NW, image=self.bg_tk)
        self.mask_item = self.canvas.create_image(0, 0, anchor=NW, image=self.mask_tk)

        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.root.bind("<Left>", lambda _e: self.move(-1, 0))
        self.root.bind("<Right>", lambda _e: self.move(1, 0))
        self.root.bind("<Up>", lambda _e: self.move(0, -1))
        self.root.bind("<Down>", lambda _e: self.move(0, 1))
        self.root.bind("<Shift-Left>", lambda _e: self.move(-10, 0))
        self.root.bind("<Shift-Right>", lambda _e: self.move(10, 0))
        self.root.bind("<Shift-Up>", lambda _e: self.move(0, -10))
        self.root.bind("<Shift-Down>", lambda _e: self.move(0, 10))
        self.root.bind("r", lambda _e: self.set_offset(0, 0))
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.update_title()

    def on_press(self, event) -> None:
        self.drag_start = (event.x, event.y, self.dx, self.dy)

    def on_drag(self, event) -> None:
        if self.drag_start is None:
            return
        x0, y0, dx0, dy0 = self.drag_start
        self.set_offset(dx0 + event.x - x0, dy0 + event.y - y0)

    def move(self, dx: int, dy: int) -> None:
        self.set_offset(self.dx + dx, self.dy + dy)

    def set_offset(self, dx: int, dy: int) -> None:
        self.dx = dx
        self.dy = dy
        self.canvas.coords(self.mask_item, self.dx, self.dy)
        self.update_title()

    def update_title(self) -> None:
        self.root.title(f"L{self.level_num:02d} top-mask align  dx={self.dx} dy={self.dy}  drag/arrows, Shift=10px, r=reset")

    def close(self) -> None:
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        overlay = self.bg.copy()
        overlay.alpha_composite(self.mask, (self.dx, self.dy))
        result = {
            "level": self.level_num,
            "dx": self.dx,
            "dy": self.dy,
            "units": "screen pixels at 640x480",
        }
        json_path = OUT_DIR / f"l{self.level_num:02d}_mask_offset.json"
        overlay_path = OUT_DIR / f"l{self.level_num:02d}_mask_overlay_dx{self.dx}_dy{self.dy}.png"
        json_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
        overlay.convert("RGB").save(overlay_path)
        print(json.dumps(result, ensure_ascii=False))
        print(f"wrote {json_path}")
        print(f"wrote {overlay_path}")
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--level", type=int, default=9, help="runtime level number, default L09")
    ap.add_argument("--alpha", type=int, default=160, help="overlay alpha multiplier 0..255")
    ap.add_argument("--tint", default="255,0,255", help="mask tint r,g,b")
    ap.add_argument(
        "--source",
        choices=("hdcrop", "generated"),
        default="hdcrop",
        help="mask source: hdcrop uses 16:9->4:3 crop then /1.5 scale; generated uses current packed L4 files",
    )
    args = ap.parse_args()

    if not 1 <= args.level <= len(RUNTIME_LEVELS):
        raise SystemExit(f"bad --level {args.level}")
    level_name = RUNTIME_LEVELS[args.level - 1]
    tint = tuple(int(x.strip()) for x in args.tint.split(","))
    if len(tint) != 3:
        raise SystemExit("--tint must be r,g,b")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    bg = decode_bg(args.level)
    alpha_scale = max(0, min(255, args.alpha)) / 255.0
    if args.source == "hdcrop":
        mask = alpha_from_hdcrop(level_name, tint, alpha_scale)
    else:
        mask = build_generated_mask(args.level, level_name, tint, alpha_scale)
    bg_path = OUT_DIR / f"l{args.level:02d}_background.png"
    mask_path = OUT_DIR / f"l{args.level:02d}_{args.source}_mask.png"
    bg.convert("RGB").save(bg_path)
    mask.save(mask_path)
    print(f"wrote {bg_path}")
    print(f"wrote {mask_path}")
    AlignApp(bg, mask, args.level, args.alpha).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
