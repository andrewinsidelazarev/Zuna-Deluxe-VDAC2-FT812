#!/usr/bin/env python3
"""diag_hud_menu_socket.py — что лежит в frame_top.bin в зоне кнопки MENU.
Вопрос: запечён ли там idle-спрайт, или прозрачная дыра (сквозь неё видна
зелень фона). Рендерит кропы: сокет рамки, ячейки атласа, наложение."""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
CONV = ROOT / "Graphics" / "Converted"
OUT = ROOT / "Diagnostics"


def load_palette(path):
    raw = path.read_bytes()
    return [(((v := raw[i] | (raw[i + 1] << 8)) >> 8 & 0xF) * 17,
             (v >> 4 & 0xF) * 17, (v & 0xF) * 17, (v >> 12 & 0xF) * 17)
            for i in range(0, 512, 2)]


def paletted(pix_path, pal, w, h, offset=0):
    pix = pix_path.read_bytes()[offset:offset + w * h]
    img = Image.new("RGBA", (w, h))
    img.putdata([pal[p] for p in pix])
    return img


def main():
    fpal = load_palette(CONV / "frame_palette_argb4.bin")
    hpal = load_palette(CONV / "hud_palette_argb4.bin")
    top = paletted(CONV / "frame_top.bin", fpal, 640, 44)

    # зона кнопки: strip-координаты (539,3) 79×26 (+ запас)
    x0, y0, x1, y1 = 525, 0, 640, 44
    crop = top.crop((x0, y0, x1, y1))
    alpha = crop.getchannel("A")
    hist = alpha.histogram()
    transparent = sum(hist[:128])
    total = (x1 - x0) * (y1 - y0)
    print(f"строб рамки [{x0}..{x1})x[{y0}..{y1}): "
          f"прозрачных(α<128)={transparent}/{total}")

    # точечно зона ровно под кнопкой
    btn = top.crop((539, 3, 539 + 79, 3 + 26))
    bh = btn.getchannel("A").histogram()
    btr = sum(bh[:128])
    print(f"ровно под кнопкой 79×26: прозрачных={btr}/{79 * 26}")

    OUT.mkdir(exist_ok=True)
    big = crop.resize(((x1 - x0) * 4, (y1 - y0) * 4), Image.Resampling.NEAREST)
    bg = Image.new("RGBA", big.size, (0, 200, 0, 255))     # зелёная подложка
    bg.alpha_composite(big)
    bg.convert("RGB").save(OUT / "hud_socket_strip.png")

    cells = Image.new("RGBA", (79 * 3, 26))
    for c in range(3):
        cells.alpha_composite(
            paletted(CONV / "hud_menu_atlas.bin", hpal, 79, 26, offset=79 * 26 * c),
            (79 * c, 0))
    big2 = cells.resize((79 * 3 * 4, 26 * 4), Image.Resampling.NEAREST)
    bg2 = Image.new("RGBA", big2.size, (0, 200, 0, 255))
    bg2.alpha_composite(big2)
    bg2.convert("RGB").save(OUT / "hud_menu_cells.png")
    print("saved Diagnostics/hud_socket_strip.png, hud_menu_cells.png")


if __name__ == "__main__":
    main()
