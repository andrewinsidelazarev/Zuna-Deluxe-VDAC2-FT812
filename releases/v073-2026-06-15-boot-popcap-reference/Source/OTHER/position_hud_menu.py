#!/usr/bin/env python3
"""position_hud_menu.py — интерактивная подгонка позиции кнопки MENU (HUD).

Собирает игровой экран 1024×768 (фон L01 + рамки; idle-кнопка запечена в
верхней рамке — ориентир) и кладёт поверх спрайт hover-кнопки (cell 1).
Стрелки = ±1px, Shift+стрелки = ±8px, Esc/закрытие окна = выход.
Финальные координаты печатаются в консоль и в Diagnostics/hud_menu_position.txt.
"""
import tkinter as tk
from pathlib import Path

from PIL import Image, ImageTk

ROOT = Path(__file__).resolve().parents[2]
CONV = ROOT / "Graphics" / "Converted"
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
OUT_TXT = ROOT / "Diagnostics" / "hud_menu_position.txt"

START_X, START_Y = 862, 5          # текущие HUD_MENU_X/Y (main.asm)
BTN_W, BTN_H = 79, 26              # atlas cell
DRAW_W, DRAW_H = 126, 42           # ×1.6


def load_palette(path: Path):
    raw = path.read_bytes()
    pal = []
    for i in range(0, 512, 2):
        v = raw[i] | (raw[i + 1] << 8)
        pal.append((((v >> 8) & 0xF) * 17, ((v >> 4) & 0xF) * 17,
                    (v & 0xF) * 17, ((v >> 12) & 0xF) * 17))
    return pal


def paletted_image(pix_path: Path, pal_path: Path, w: int, h: int,
                   offset: int = 0) -> Image.Image:
    pix = pix_path.read_bytes()[offset:offset + w * h]
    pal = load_palette(pal_path)
    img = Image.new("RGBA", (w, h))
    img.putdata([pal[p] for p in pix])
    return img


def nearest(img: Image.Image, w: int, h: int) -> Image.Image:
    return img.resize((w, h), Image.Resampling.NEAREST)


def compose_screen() -> Image.Image:
    scr = Image.new("RGBA", (1024, 768))
    bg = paletted_image(PACK / "bg_l01_paletted.bin",
                        PACK / "bg_l01_palette_argb4.bin", 400, 300)
    scr.alpha_composite(nearest(bg, 1024, 768).convert("RGBA"), (0, 0))
    fp = CONV / "frame_palette_argb4.bin"
    top = paletted_image(CONV / "frame_top.bin", fp, 640, 44)
    bot = paletted_image(CONV / "frame_bot.bin", fp, 640, 24)
    left = paletted_image(CONV / "frame_left.bin", fp, 24, 412)
    right = paletted_image(CONV / "frame_right.bin", fp, 24, 412)
    scr.alpha_composite(nearest(top, 1024, 70), (0, 0))
    scr.alpha_composite(nearest(bot, 1024, 38), (0, 768 - 38))
    scr.alpha_composite(nearest(left, 38, 659), (0, 70))
    scr.alpha_composite(nearest(right, 38, 659), (1024 - 38, 70))
    return scr


def load_button() -> Image.Image:
    # cell 1 = hover (cell 0 idle запечён в рамке)
    img = paletted_image(CONV / "hud_menu_atlas.bin", CONV / "hud_palette_argb4.bin",
                         BTN_W, BTN_H, offset=BTN_W * BTN_H * 1)
    return nearest(img, DRAW_W, DRAW_H)


class App:
    def __init__(self):
        self.x, self.y = START_X, START_Y
        self.root = tk.Tk()
        self.root.resizable(False, False)
        self.screen = compose_screen()
        self.button = load_button()
        self.canvas = tk.Canvas(self.root, width=1024, height=768,
                                highlightthickness=0)
        self.canvas.pack()
        self.bg_tk = ImageTk.PhotoImage(self.screen)
        self.btn_tk = ImageTk.PhotoImage(self.button)
        self.canvas.create_image(0, 0, image=self.bg_tk, anchor="nw")
        self.btn_id = self.canvas.create_image(self.x, self.y,
                                               image=self.btn_tk, anchor="nw")
        self.root.bind("<Left>", lambda e: self.move(-self.step(e), 0))
        self.root.bind("<Right>", lambda e: self.move(self.step(e), 0))
        self.root.bind("<Up>", lambda e: self.move(0, -self.step(e)))
        self.root.bind("<Down>", lambda e: self.move(0, self.step(e)))
        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.update_title()

    @staticmethod
    def step(event) -> int:
        return 8 if event.state & 0x0001 else 1    # Shift = 8px

    def move(self, dx: int, dy: int):
        self.x += dx
        self.y += dy
        self.canvas.coords(self.btn_id, self.x, self.y)
        self.update_title()

    def update_title(self):
        self.root.title(f"MENU: 1024-XY=({self.x},{self.y})  "
                        f"640-XY=({self.x / 1.6:.1f},{self.y / 1.6:.1f})  "
                        f"стрелки=1px Shift=8px Esc=выход")

    def run(self):
        self.root.mainloop()
        lines = [
            f"HUD_MENU_X EQU {self.x}",
            f"HUD_MENU_Y EQU {self.y}",
            f"; 640-эквивалент: ({self.x / 1.6:.2f}, {self.y / 1.6:.2f})",
        ]
        text = "\n".join(lines)
        OUT_TXT.parent.mkdir(exist_ok=True)
        OUT_TXT.write_text(text + "\n", encoding="utf-8")
        print(text)
        print(f"(сохранено в {OUT_TXT})")


if __name__ == "__main__":
    App().run()
