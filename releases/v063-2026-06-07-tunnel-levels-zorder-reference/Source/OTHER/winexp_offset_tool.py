#!/usr/bin/env python3
"""Interactive WinState explosion offset probe.

Controls:
  mouse drag / arrows / WASD  move the whole explosion overlay
  Shift + arrows             move by 10 px
  1/2                        previous/next animation phase
  +/-                        change explosion spacing
  C                          toggle center markers
  T                          toggle track polyline
  R                          reset offset
  Esc                        close

On close the tool prints and writes Source/OTHER/winexp_offset_result.txt:
  WINEXP_MANUAL_XOFF = dx
  WINEXP_MANUAL_YOFF = dy
"""
from __future__ import annotations

import argparse
import struct
import sys
import tkinter as tk
from pathlib import Path

from PIL import Image, ImageDraw, ImageTk


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
TRACK_BIN = ROOT / "Graphics" / "levels" / "Converted" / "track_640.bin"
DEFAULT_BG = ROOT / "Graphics" / "levels" / "Original" / "01-spiral" / "level_src_01.png"
DEFAULT_GAMEOBJECTS = ROOT / "Graphics" / "Original" / "gameobjects.png"
REF_GAMEOBJECTS = (
    Path.home()
    / "Desktop"
    / "Zuma-Deluxe-HD-release-v010-ref"
    / "content"
    / "images"
    / "gameobjects.png"
)
RESULT = HERE / "winexp_offset_result.txt"

SRC_X, SRC_Y = 528, 0
SRC_W, SRC_H = 100, 130
SRC_FRAMES = 17
CROP = 100
CROP_Y_OFF = (SRC_H - CROP) // 2
DRAW_SIZE = 80
WINDOW_W, WINDOW_H = 640, 480


def load_track(path: Path) -> list[tuple[int, int]]:
    data = path.read_bytes()
    if len(data) < 2:
        raise RuntimeError(f"bad track file: {path}")
    count = struct.unpack_from("<H", data, 0)[0]
    pos = 2
    pts: list[tuple[int, int]] = []
    for _ in range(count):
        if pos + 5 > len(data):
            break
        x, y = struct.unpack_from("<HH", data, pos)
        pts.append((int(x), int(y)))
        pos += 5
    return pts


def load_background(path: Path) -> Image.Image:
    img = Image.open(path).convert("RGBA")
    if img.size != (WINDOW_W, WINDOW_H):
        img = img.resize((WINDOW_W, WINDOW_H), Image.Resampling.LANCZOS)
    return img


def load_explosion_frames(path: Path) -> list[Image.Image]:
    sheet = Image.open(path).convert("RGBA")
    frames: list[Image.Image] = []
    for i in range(SRC_FRAMES):
        x0 = SRC_X
        y0 = SRC_Y + i * SRC_H + CROP_Y_OFF
        crop = sheet.crop((x0, y0, x0 + CROP, y0 + CROP))
        frames.append(crop.resize((DRAW_SIZE, DRAW_SIZE), Image.Resampling.LANCZOS))
    return frames


class OffsetTool:
    def __init__(
        self,
        root: tk.Tk,
        bg: Image.Image,
        track: list[tuple[int, int]],
        frames: list[Image.Image],
        spacing: int,
        phase: int,
    ) -> None:
        self.root = root
        self.bg = bg
        self.track = track
        self.frames = frames
        self.spacing = spacing
        self.phase = phase
        self.dx = 0
        self.dy = 0
        self.show_centers = True
        self.show_track = True
        self.drag_start: tuple[int, int, int, int] | None = None

        root.title("WinState explosion offset probe")
        self.canvas = tk.Canvas(root, width=WINDOW_W, height=WINDOW_H, highlightthickness=0)
        self.canvas.pack()
        self.status = tk.Label(root, anchor="w")
        self.status.pack(fill="x")

        root.bind("<Key>", self.on_key)
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.canvas.bind("<ButtonPress-1>", self.on_mouse_down)
        self.canvas.bind("<B1-Motion>", self.on_mouse_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_mouse_up)

        self.photo: ImageTk.PhotoImage | None = None
        self.render()

    def chain_samples(self) -> list[tuple[int, int, int]]:
        out: list[tuple[int, int, int]] = []
        if not self.track:
            return out
        for idx, sample in enumerate(range(0, len(self.track), max(1, self.spacing))):
            x, y = self.track[sample]
            out.append((sample, x, y))
        return out

    def render(self) -> None:
        img = self.bg.copy()
        draw = ImageDraw.Draw(img, "RGBA")

        if self.show_track and len(self.track) > 1:
            draw.line(self.track, fill=(0, 220, 255, 150), width=2)

        chain = self.chain_samples()
        half = DRAW_SIZE // 2
        for i, (_sample, x, y) in enumerate(chain):
            frame = self.frames[(i + self.phase) % len(self.frames)]
            img.alpha_composite(frame, (x + self.dx - half, y + self.dy - half))

        if self.show_centers:
            for _sample, x, y in chain:
                cx = x + self.dx
                cy = y + self.dy
                draw.line((cx - 5, cy, cx + 5, cy), fill=(255, 0, 0, 230), width=1)
                draw.line((cx, cy - 5, cx, cy + 5), fill=(255, 0, 0, 230), width=1)

        self.photo = ImageTk.PhotoImage(img)
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        self.status.config(
            text=(
                f"dx={self.dx:+d} dy={self.dy:+d}  "
                f"spacing={self.spacing} phase={self.phase}  "
                "drag/arrows move, Shift=10, +/- spacing, 1/2 phase, C centers, T track, Esc close"
            )
        )

    def move(self, x: int, y: int) -> None:
        self.dx += x
        self.dy += y
        self.render()

    def on_key(self, event: tk.Event) -> None:
        step = 10 if (event.state & 0x0001) else 1
        key = event.keysym.lower()
        if key in ("left", "a"):
            self.move(-step, 0)
        elif key in ("right", "d"):
            self.move(step, 0)
        elif key in ("up", "w"):
            self.move(0, -step)
        elif key in ("down", "s"):
            self.move(0, step)
        elif key in ("plus", "equal", "kp_add"):
            self.spacing += 1
            self.render()
        elif key in ("minus", "kp_subtract"):
            self.spacing = max(1, self.spacing - 1)
            self.render()
        elif key == "1":
            self.phase = (self.phase - 1) % len(self.frames)
            self.render()
        elif key == "2":
            self.phase = (self.phase + 1) % len(self.frames)
            self.render()
        elif key == "c":
            self.show_centers = not self.show_centers
            self.render()
        elif key == "t":
            self.show_track = not self.show_track
            self.render()
        elif key == "r":
            self.dx = 0
            self.dy = 0
            self.render()
        elif key == "escape":
            self.close()

    def on_mouse_down(self, event: tk.Event) -> None:
        self.drag_start = (event.x, event.y, self.dx, self.dy)

    def on_mouse_drag(self, event: tk.Event) -> None:
        if self.drag_start is None:
            return
        x0, y0, dx0, dy0 = self.drag_start
        self.dx = dx0 + event.x - x0
        self.dy = dy0 + event.y - y0
        self.render()

    def on_mouse_up(self, _event: tk.Event) -> None:
        self.drag_start = None

    def close(self) -> None:
        text = (
            f"WINEXP_MANUAL_XOFF = {self.dx}\n"
            f"WINEXP_MANUAL_YOFF = {self.dy}\n"
            f"spacing = {self.spacing}\n"
            f"phase = {self.phase}\n"
        )
        RESULT.write_text(text, encoding="utf-8")
        print(text, end="")
        self.root.destroy()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bg", type=Path, default=DEFAULT_BG)
    ap.add_argument("--track", type=Path, default=TRACK_BIN)
    ap.add_argument("--gameobjects", type=Path, default=DEFAULT_GAMEOBJECTS)
    ap.add_argument("--spacing", type=int, default=30)
    ap.add_argument("--phase", type=int, default=0)
    args = ap.parse_args()

    if args.gameobjects == DEFAULT_GAMEOBJECTS and not args.gameobjects.exists():
        args.gameobjects = REF_GAMEOBJECTS

    for p in (args.bg, args.track, args.gameobjects):
        if not p.exists():
            print(f"missing file: {p}", file=sys.stderr)
            return 2

    bg = load_background(args.bg)
    track = load_track(args.track)
    frames = load_explosion_frames(args.gameobjects)

    root = tk.Tk()
    OffsetTool(root, bg, track, frames, max(1, args.spacing), args.phase % SRC_FRAMES)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
