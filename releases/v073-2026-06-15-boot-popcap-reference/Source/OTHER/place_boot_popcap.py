#!/usr/bin/env python3
from __future__ import annotations

import re
import tkinter as tk
from pathlib import Path

from PIL import Image, ImageTk


ROOT = Path(__file__).resolve().parents[2]
SCREENSHOT = ROOT / "Безымянный.png"
LOGO = ROOT / "Graphics" / "Converted" / "BootLoading" / "boot_popcap_logo_argb4_preview.png"
MAIN_ASM = ROOT / "Source" / "ASM" / "main.asm"
OUT = ROOT / "Diagnostics" / "boot_popcap_position.txt"
VIEW_W = 1024
VIEW_H = 768


def read_equ(name: str, default: int) -> int:
    text = MAIN_ASM.read_text(encoding="utf-8", errors="replace")
    match = re.search(rf"^{re.escape(name)}\s+EQU\s+(-?\d+)", text, re.MULTILINE)
    return int(match.group(1)) if match else default


def load_canvas() -> Image.Image:
    image = Image.open(SCREENSHOT).convert("RGB")
    if image.width >= VIEW_W and image.height >= VIEW_H:
        left = 0
        top = image.height - VIEW_H
        return image.crop((left, top, left + VIEW_W, top + VIEW_H))
    out = Image.new("RGB", (VIEW_W, VIEW_H), "white")
    out.paste(image, (0, 0))
    return out


class Placer:
    def __init__(self) -> None:
        self.root = tk.Tk()
        self.root.title("Place PopCap logo - drag, arrows fine tune, close to save")
        self.bg_img = load_canvas()
        self.logo_img = Image.open(LOGO).convert("RGBA")
        self.bg = ImageTk.PhotoImage(self.bg_img)
        self.logo = ImageTk.PhotoImage(self.logo_img)
        self.x = read_equ("BOOT_POPCAP_X", 882)
        self.y = read_equ("BOOT_POPCAP_Y", 640)
        self.drag_dx = 0
        self.drag_dy = 0

        self.canvas = tk.Canvas(self.root, width=VIEW_W, height=VIEW_H, highlightthickness=0)
        self.canvas.pack()
        self.canvas.create_image(0, 0, image=self.bg, anchor="nw")
        self.logo_id = self.canvas.create_image(self.x, self.y, image=self.logo, anchor="nw")
        self.status = self.canvas.create_text(
            8,
            8,
            anchor="nw",
            fill="white",
            font=("Consolas", 16, "bold"),
            text="",
        )
        self.canvas.tag_raise(self.status)
        self.update_status()

        self.canvas.tag_bind(self.logo_id, "<ButtonPress-1>", self.start_drag)
        self.canvas.tag_bind(self.logo_id, "<B1-Motion>", self.drag)
        self.canvas.bind("<ButtonPress-1>", self.click_place)
        self.root.bind("<Left>", lambda _e: self.move(-1, 0))
        self.root.bind("<Right>", lambda _e: self.move(1, 0))
        self.root.bind("<Up>", lambda _e: self.move(0, -1))
        self.root.bind("<Down>", lambda _e: self.move(0, 1))
        self.root.protocol("WM_DELETE_WINDOW", self.close)

    def clamp(self) -> None:
        self.x = max(0, min(VIEW_W - self.logo_img.width, self.x))
        self.y = max(0, min(VIEW_H - self.logo_img.height, self.y))

    def update_status(self) -> None:
        self.canvas.coords(self.logo_id, self.x, self.y)
        self.canvas.itemconfigure(self.status, text=f"BOOT_POPCAP_X={self.x}  BOOT_POPCAP_Y={self.y}")

    def start_drag(self, event: tk.Event) -> None:
        self.drag_dx = int(event.x) - self.x
        self.drag_dy = int(event.y) - self.y

    def drag(self, event: tk.Event) -> None:
        self.x = int(event.x) - self.drag_dx
        self.y = int(event.y) - self.drag_dy
        self.clamp()
        self.update_status()

    def click_place(self, event: tk.Event) -> None:
        if self.canvas.find_withtag("current") == (self.logo_id,):
            return
        self.x = int(event.x) - self.logo_img.width // 2
        self.y = int(event.y) - self.logo_img.height // 2
        self.clamp()
        self.update_status()

    def move(self, dx: int, dy: int) -> None:
        self.x += dx
        self.y += dy
        self.clamp()
        self.update_status()

    def close(self) -> None:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(f"BOOT_POPCAP_X={self.x}\nBOOT_POPCAP_Y={self.y}\n", encoding="ascii")
        print(f"BOOT_POPCAP_X={self.x}")
        print(f"BOOT_POPCAP_Y={self.y}")
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


if __name__ == "__main__":
    Placer().run()
