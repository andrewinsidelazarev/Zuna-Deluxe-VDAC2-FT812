#!/usr/bin/env python3
"""Build FT812 PALETTED4444 assets for the VDAC2 main menu profile."""

from __future__ import annotations

import json
import zlib
from pathlib import Path

import numpy as np
from PIL import Image


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SRC = ROOT / "Graphics" / "Menu" / "Original to 640-480"
OUT = ROOT / "Graphics" / "Menu" / "Converted"
PAGE_SIZE = 0x4000
MAX_INFLATE_STREAM = 0xFFFF
INFLATE_RAW_CHUNK = 0xF000
TRANSPARENT_ALPHA = 4

FOREGROUND = "main_screen_background_canvas_4x3.png"
SKY = "main_screen_sky_canvas_4x3.png"
SKY_FEATHER_PX = 64
SUN_FILES = ("main_sun.png", "main_sun_light.png")
BUTTON_STEMS = (
    "main_button_options",
    "main_button_gauntlet",
    "main_button_adventure",
    "main_button_more_games",
    "main_button_quit",
)
BUTTON_STATES = ("normal", "hover", "pressed")
DISABLED_STEMS = ()
HD_MAIN_BUTTON_POSITIONS = {
    "main_button_adventure": [840, 95],
    "main_button_gauntlet": [816, 230],
    "main_button_options": [790, 354],
    "main_button_more_games": [750, 452],
    "main_button_quit": [902, 470],
}
UI_FILES = (FOREGROUND,) + SUN_FILES + tuple(
    f"{stem}_{state}.png" for stem in BUTTON_STEMS for state in BUTTON_STATES
)


def palette_argb4_bytes(palette: np.ndarray) -> bytes:
    out = bytearray()
    for rgba in palette[:256]:
        r, g, b, a = (int(value) for value in rgba)
        word = (((a >> 4) & 0xF) << 12) | (((r >> 4) & 0xF) << 8) | (((g >> 4) & 0xF) << 4) | ((b >> 4) & 0xF)
        out += word.to_bytes(2, "little")
    assert len(out) == 512
    return bytes(out)


def kmeans_rgba(pool: np.ndarray, k: int = 255, sample_limit: int = 60000) -> np.ndarray:
    rng = np.random.default_rng(42)
    sample = pool
    if len(sample) > sample_limit:
        sample = sample[rng.choice(len(sample), sample_limit, replace=False)]
    x = sample.astype(np.float32)
    centers = x[rng.choice(len(x), k, replace=False)].copy()
    for _ in range(28):
        labels = np.empty(len(x), dtype=np.int32)
        for start in range(0, len(x), 4096):
            batch = x[start:start + 4096]
            dists = ((batch[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
            labels[start:start + len(batch)] = np.argmin(dists, axis=1)
        updated = centers.copy()
        for index in range(k):
            pixels = x[labels == index]
            if len(pixels):
                updated[index] = pixels.mean(axis=0)
        if np.linalg.norm(updated - centers) < 1.0:
            centers = updated
            break
        centers = updated
    return np.clip(centers, 0, 255).astype(np.uint8)


def make_alpha_palette(images: dict[str, np.ndarray]) -> np.ndarray:
    pool = np.concatenate(
        [image[image[..., 3] >= TRANSPARENT_ALPHA] for image in images.values()],
        axis=0,
    )
    palette = np.zeros((256, 4), dtype=np.uint8)
    palette[1:] = kmeans_rgba(pool)
    return palette


def map_alpha_image(image: np.ndarray, palette: np.ndarray) -> np.ndarray:
    h, w = image.shape[:2]
    flat = image.reshape(-1, 4).astype(np.float32)
    indices = np.zeros(len(flat), dtype=np.uint8)
    visible = flat[:, 3] >= TRANSPARENT_ALPHA
    candidates = palette[1:].astype(np.float32)
    pixels = flat[visible]
    for start in range(0, len(pixels), 4096):
        batch = pixels[start:start + 4096]
        dists = ((batch[:, None, :] - candidates[None, :, :]) ** 2).sum(axis=2)
        indices[np.flatnonzero(visible)[start:start + len(batch)]] = np.argmin(dists, axis=1).astype(np.uint8) + 1
    return indices.reshape(h, w)


def desaturate_disabled(rgba: np.ndarray) -> np.ndarray:
    arr = rgba.astype(np.float32)
    lum = 0.299 * arr[..., 0] + 0.587 * arr[..., 1] + 0.114 * arr[..., 2]
    tint = np.array([170.0, 125.0, 90.0], dtype=np.float32)
    norm = float(tint.mean())
    out = np.empty_like(arr)
    out[..., 0] = lum * (tint[0] / norm)
    out[..., 1] = lum * (tint[1] / norm)
    out[..., 2] = lum * (tint[2] / norm)
    out[..., :3] *= 0.9
    out[..., 3] = arr[..., 3]
    return out.clip(0, 255).astype(np.uint8)


def feather_horizontal_seam(image: Image.Image, fade_w: int) -> Image.Image:
    arr = np.array(image.convert("RGBA"), dtype=np.float32)
    w = arr.shape[1]
    if fade_w <= 0 or fade_w * 2 >= w:
        return image
    seam = (arr[:, 0:1, :3] + arr[:, w - 1:w, :3]) * 0.5
    x = np.arange(fade_w, dtype=np.float32)
    weight = 0.5 + 0.5 * np.cos(np.pi * x / fade_w)
    w_left = weight[None, :, None]
    arr[:, :fade_w, :3] = (1.0 - w_left) * arr[:, :fade_w, :3] + w_left * seam
    w_right = weight[None, ::-1, None]
    arr[:, w - fade_w:, :3] = (1.0 - w_right) * arr[:, w - fade_w:, :3] + w_right * seam
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def make_opaque_palette(image: Image.Image) -> tuple[np.ndarray, np.ndarray]:
    q = image.convert("RGB").quantize(
        colors=255,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.FLOYDSTEINBERG,
    )
    palette = np.zeros((256, 4), dtype=np.uint8)
    colors = q.getpalette()[:255 * 3]
    for index in range(255):
        palette[index + 1] = (colors[index * 3], colors[index * 3 + 1], colors[index * 3 + 2], 255)
    indices = (np.array(q, dtype=np.uint16) + 1).astype(np.uint8)
    return palette, indices


def alpha_bbox(image: np.ndarray) -> list[int] | None:
    ys, xs = np.nonzero(image[..., 3] >= TRANSPARENT_ALPHA)
    if not len(xs):
        return None
    x0, y0 = int(xs.min()), int(ys.min())
    x1, y1 = int(xs.max()) + 1, int(ys.max()) + 1
    return [x0, y0, x1 - x0, y1 - y0]


def hd_to_640_rect(x: int, y: int, width: int, height: int) -> list[int]:
    return [
        round((x - 160) * 2 / 3),
        round(y * 2 / 3),
        round(width * 2 / 3),
        round(height * 2 / 3),
    ]


def split_pages(name: str, data: bytes) -> list[str]:
    pages = []
    for page_index in range((len(data) + PAGE_SIZE - 1) // PAGE_SIZE):
        page_name = f"{name}_p{page_index:02d}.bin"
        chunk = data[page_index * PAGE_SIZE:(page_index + 1) * PAGE_SIZE]
        (OUT / page_name).write_bytes(chunk + bytes(PAGE_SIZE - len(chunk)))
        pages.append(page_name)
    return pages


def write_zlib_streams(name: str, data: bytes, whole_stream: bytes) -> list[dict[str, object]]:
    if len(whole_stream) <= MAX_INFLATE_STREAM:
        return [{
            "file": f"{name}.zlib",
            "raw_offset": 0,
            "raw_size_bytes": len(data),
            "zlib_size_bytes": len(whole_stream),
        }]

    streams = []
    for index, offset in enumerate(range(0, len(data), INFLATE_RAW_CHUNK)):
        chunk = data[offset:offset + INFLATE_RAW_CHUNK]
        stream = zlib.compress(chunk, 3)
        if len(stream) > MAX_INFLATE_STREAM:
            raise ValueError(f"{name} zlib chunk {index} is still too large: {len(stream)} bytes")
        file_name = f"{name}_z{index:02d}.zlib"
        (OUT / file_name).write_bytes(stream)
        streams.append({
            "file": file_name,
            "raw_offset": offset,
            "raw_size_bytes": len(chunk),
            "zlib_size_bytes": len(stream),
        })
    return streams


def write_indices(name: str, indices: np.ndarray) -> dict[str, object]:
    data = indices.tobytes()
    path = OUT / f"{name}.bin"
    path.write_bytes(data)
    zlib_path = OUT / f"{name}.zlib"
    whole_stream = zlib.compress(data, 3)
    zlib_path.write_bytes(whole_stream)
    inflate_streams = write_zlib_streams(name, data, whole_stream)
    return {
        "file": path.name,
        "zlib_file": zlib_path.name,
        "zlib_size_bytes": zlib_path.stat().st_size,
        "inflate_streams": inflate_streams,
        "inflate_streams_size_bytes": sum(int(stream["zlib_size_bytes"]) for stream in inflate_streams),
        "pages": split_pages(name, data) if len(data) > PAGE_SIZE else [],
        "size_bytes": len(data),
        "width": int(indices.shape[1]),
        "height": int(indices.shape[0]),
        "format": "FT_PALETTED4444",
        "stride_bytes": int(indices.shape[1]),
    }


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    ui_rgba = {
        name: np.array(Image.open(SRC / name).convert("RGBA"), dtype=np.uint8)
        for name in UI_FILES
    }
    for stem in DISABLED_STEMS:
        disabled = desaturate_disabled(ui_rgba[f"{stem}_normal.png"])
        for state in BUTTON_STATES:
            ui_rgba[f"{stem}_{state}.png"] = disabled
    ui_palette = make_alpha_palette(ui_rgba)
    (OUT / "main_menu_ui_palette_argb4.bin").write_bytes(palette_argb4_bytes(ui_palette))

    assets: dict[str, dict[str, object]] = {}
    for file_name, rgba in ui_rgba.items():
        stem = Path(file_name).stem
        entry = write_indices(stem, map_alpha_image(rgba, ui_palette))
        entry["source_png"] = file_name
        entry["palette"] = "main_menu_ui_palette_argb4.bin"
        entry["alpha_bbox"] = alpha_bbox(rgba)
        assets[stem] = entry

    sky_image = Image.open(SRC / SKY).convert("RGBA")
    sky_image = feather_horizontal_seam(sky_image, SKY_FEATHER_PX)
    sky_palette, sky_indices = make_opaque_palette(sky_image)
    (OUT / "main_menu_sky_palette_argb4.bin").write_bytes(palette_argb4_bytes(sky_palette))
    sky_entry = write_indices(Path(SKY).stem, sky_indices)
    sky_entry["source_png"] = SKY
    sky_entry["palette"] = "main_menu_sky_palette_argb4.bin"
    sky_entry["screen_rect"] = [0, 0, sky_image.width, sky_image.height]
    assets[Path(SKY).stem] = sky_entry

    button_screen_rects = {}
    for stem, (x, y) in HD_MAIN_BUTTON_POSITIONS.items():
        normal = assets[f"{stem}_normal"]
        button_screen_rects[stem] = {
            "hd_16x9_top_left": [x, y],
            "screen_rect_640x480": hd_to_640_rect(
                x,
                y,
                int(normal["width"]) * 3 // 2,
                int(normal["height"]) * 3 // 2,
            ),
            "hit_dead_border_hd": 16,
            "hit_dead_border_640x480": round(16 * 2 / 3),
        }

    raw_size = sum(int(entry["size_bytes"]) for entry in assets.values()) + 1024
    manifest = {
        "profile": "main_menu",
        "draw_order": [
            Path(SKY).stem,
            Path(FOREGROUND).stem,
            "main menu buttons",
            "main_sun",
            "main_sun_light",
        ],
        "coordinate_format": {
            "rect": ["x", "y", "width", "height"],
            "origin": "top-left",
            "units": "pixels",
        },
        "format_notes": [
            "Sky is opaque PALETTED4444 and uses its own palette.",
            "Foreground and button states share an alpha-preserving PALETTED4444 palette.",
            "Palette index 0 is transparent for the foreground/button palette.",
            "Each raw bitmap has zlib output intended for the menu FT812 load path via CMD_INFLATE.",
            "Assets whose single zlib stream exceeds the current TSLib 64K inflate path also have chunked inflate_streams.",
        ],
        "hd_release_reference": {
            "source_file": "C:/Users/Администратор/Desktop/Zuma-Deluxe-HD-release-v010-ref/src/menu/MenuMgr.c",
            "sky_animation": {
                "hd_source_rect": [0, 720, 1280, 250],
                "hd_speed_pixels_per_update": 1,
                "wrap_width_hd": 1280,
                "algorithm": [
                    "Increment skyPos by 1 each update and wrap modulo 1280.",
                    "Draw first sky copy at x=skyPos, y=0.",
                    "Draw second sky copy at x=skyPos-1279, y=0.",
                    "Draw foreground canvas after the two sky copies."
                ],
                "vdac2_640x480_note": "For exact speed scaling use 2/3 pixel per HD update, or accumulate fixed-point sky offset and draw the 640px strip wrapped twice."
            },
            "main_sun_draw": {
                "sun_hd_rect": [158, 16, 130, 138],
                "sun_rect_640x480_after_center_crop": hd_to_640_rect(158, 16, 130, 138),
                "glow_hd_rect": [68, -68, 315, 315],
                "glow_rect_640x480_after_center_crop": hd_to_640_rect(68, -68, 315, 315),
                "glow_alpha": 152,
                "glow_color_mod_rgb": [255, 192, 0],
                "draw_order": "HD draws sky, foreground and menu buttons first; then sun, then tinted glow."
            },
            "main_button_screen_rects": button_screen_rects
        },
        "assets": assets,
        "memory_bytes": {
            "raw_asset_pixels": sum(int(entry["size_bytes"]) for entry in assets.values()),
            "zlib_asset_streams": sum(int(entry["inflate_streams_size_bytes"]) for entry in assets.values()),
            "palettes": 1024,
            "total_without_alignment_padding": raw_size,
            "foreground_full_argb4_comparison": 640 * 480 * 2,
        },
    }
    (OUT / "main_menu_assets.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    Image.fromarray(ui_palette[map_alpha_image(ui_rgba[FOREGROUND], ui_palette)], "RGBA").save(
        OUT / "main_screen_background_canvas_4x3_paletted_preview.png"
    )
    Image.fromarray(sky_palette[sky_indices], "RGBA").save(OUT / "main_screen_sky_canvas_4x3_paletted_preview.png")

    print(f"Wrote main-menu converted assets to {OUT}")
    print(f"Main-menu raw RAM_G payload without alignment: {raw_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
