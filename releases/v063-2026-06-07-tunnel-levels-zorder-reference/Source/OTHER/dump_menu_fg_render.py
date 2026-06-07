#!/usr/bin/env python3
"""Render MENU_FG bitmap with both palettes to PNG. Compare against expected."""
import zlib
from pathlib import Path
from PIL import Image

ROOT = Path(r"C:\Users\Администратор\Desktop\Zuma Deluxe VDAC2")
MENU = ROOT / "Graphics" / "Menu" / "Converted"


def load_fg_bytes() -> bytes:
    """Decompress all 5 FG chunks and concatenate (640×480 = 307200)."""
    out = bytearray()
    for i in range(5):
        path = MENU / f"main_screen_background_canvas_4x3_z0{i}.zlib"
        out.extend(zlib.decompress(path.read_bytes()))
    return bytes(out)


def load_sky_bytes() -> bytes:
    return zlib.decompress((MENU / "main_screen_sky_canvas_4x3.zlib").read_bytes())


def argb4_palette_to_rgba(pal: bytes) -> list[tuple[int, int, int, int]]:
    """256 entries × 2 bytes little-endian ARGB4 → list of (R,G,B,A)."""
    out = []
    for i in range(256):
        lo = pal[i * 2]
        hi = pal[i * 2 + 1]
        word = lo | (hi << 8)
        a = (word >> 12) & 0xF
        r = (word >> 8) & 0xF
        g = (word >> 4) & 0xF
        b = word & 0xF
        out.append((r * 17, g * 17, b * 17, a * 17))
    return out


def render(pixels: bytes, w: int, h: int, palette: list, out_path: Path):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            idx = pixels[y * w + x]
            px[x, y] = palette[idx]
    img.save(out_path)
    print(f"  wrote {out_path.name}  ({out_path.stat().st_size} bytes)")


def main():
    fg = load_fg_bytes()
    sky = load_sky_bytes()
    print(f"FG decompressed: {len(fg)} bytes (expect 307200)")
    print(f"SKY decompressed: {len(sky)} bytes (expect 106880)")

    pal_sky = (MENU / "main_menu_sky_palette_argb4.bin").read_bytes()
    pal_ui = (MENU / "main_menu_ui_palette_argb4.bin").read_bytes()
    print(f"sky palette: {len(pal_sky)} bytes (expect 512)")
    print(f"ui palette: {len(pal_ui)} bytes (expect 512)")

    rgba_sky = argb4_palette_to_rgba(pal_sky)
    rgba_ui = argb4_palette_to_rgba(pal_ui)

    out_dir = ROOT / "Diagnostics" / "Scratch" / "MenuRender"
    out_dir.mkdir(parents=True, exist_ok=True)
    print()
    print("Rendering FG with UI palette (current code uses this):")
    render(fg, 640, 480, rgba_ui, out_dir / "_menu_fg_with_ui_pal.png")
    print("Rendering FG with SKY palette (alternative):")
    render(fg, 640, 480, rgba_sky, out_dir / "_menu_fg_with_sky_pal.png")
    print()
    print("Rendering SKY with SKY palette (current code uses this):")
    render(sky, 640, 167, rgba_sky, out_dir / "_menu_sky_with_sky_pal.png")
    print("Rendering SKY with UI palette (alternative):")
    render(sky, 640, 167, rgba_ui, out_dir / "_menu_sky_with_ui_pal.png")


if __name__ == "__main__":
    main()
