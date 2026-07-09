#!/usr/bin/env python3
"""Build FT812 PALETTED4444 assets for the VDAC2 level select profile."""

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
ASM_OUT = ROOT / "Source" / "ASM" / "level_select_assets.inc"
SPG_BLOCKS_OUT = OUT / "level_select_spg_blocks.txt"
PAGE_SIZE = 0x4000
MAX_INFLATE_STREAM = 0xFFFF
INFLATE_RAW_CHUNK = 0xF000
TRANSPARENT_ALPHA = 4
SKY_FEATHER_PX = 64

# Sequential RAM_G allocation begins at the same base as the main menu —
# main menu and level select are never resident together so they reuse the
# same RAM_G region.
LS_RAMG_BASE = 0x000000

# Reuse the main-menu palette and cursor RAM_G addresses so the menu cursor
# bitmap remains valid after the level-select asset load.
LS_SKY_PAL_RAMG = 0x0ABA60
LS_UI_PAL_RAMG = 0x0ABC60
LS_CURSOR_RAMG = 0x0AC000

# Page numbers above the main-menu allocation. Page #93 is intentionally free
# after the global cursor moved to #5A; keep level-select pages stable at #94+.
LS_SPG_FIRST_PAGE = 0x94

BACKGROUND = "level_select_screen_background_canvas_4x3.png"
SKY = "level_select_screen_sky_canvas_4x3.png"
BUTTON_STEMS = (
    "level_select_button_main_menu",
    "level_select_button_back",
    "level_select_button_play",
    "level_select_button_next",
)
BUTTON_STATES = ("normal", "hover", "pressed")
BADGE_STEMS = (
    "level_select_badge_rabbit",
    "level_select_badge_eagle",
    "level_select_badge_jaguar",
    "level_select_badge_sun_god",
)
# The original gauntlet room starts each badge at the normal sheet column.
# Runtime buttons use normal/hover/pressed; the disabled sheet column is not
# part of the level-select button state machine.
BADGE_STATES = ("normal", "hover", "pressed")

# HD screen positions (from MenuMgr.c MR_GAUNTLET room, 1280x720 canvas).
HD_BUTTON_POSITIONS = {
    "level_select_button_main_menu": [172, 632],
    "level_select_button_back": [426, 667],
    "level_select_button_play": [576, 667],
    "level_select_button_next": [745, 667],
}
HD_BADGE_POSITIONS = {
    "level_select_badge_rabbit": [470, 270],
    "level_select_badge_eagle": [504, 196],
    "level_select_badge_jaguar": [530, 124],
    "level_select_badge_sun_god": [554, 45],
}

UI_FILES = (
    (BACKGROUND,)
    + tuple(f"{stem}_{state}.png" for stem in BUTTON_STEMS for state in BUTTON_STATES)
    + tuple(f"{stem}_{state}.png" for stem in BADGE_STEMS for state in BADGE_STATES)
)

# Order in which assets are placed into RAM_G and SPG pages.
# RAM_G addresses grow sequentially in this order.
RAMG_ORDER: tuple[tuple[str, str], ...] = (
    (Path(BACKGROUND).stem, "BG"),
    (Path(SKY).stem, "SKY"),
) + tuple(
    (f"{stem}_{state}", f"{stem.replace('level_select_', '').upper()}_{state[0].upper()}")
    for stem in BUTTON_STEMS for state in BUTTON_STATES
) + tuple(
    (f"{stem}_{state}", f"{stem.replace('level_select_', '').upper()}_{state[0].upper()}")
    for stem in BADGE_STEMS for state in BADGE_STATES
)

# Short EQU prefixes per asset family.
PREFIX_MAP = {
    "level_select_button_main_menu": "LS_MM",
    "level_select_button_back": "LS_BACK",
    "level_select_button_play": "LS_PLAY",
    "level_select_button_next": "LS_NEXT",
    "level_select_badge_rabbit": "LS_RBT",
    "level_select_badge_eagle": "LS_EGL",
    "level_select_badge_jaguar": "LS_JAG",
    "level_select_badge_sun_god": "LS_SUN",
}


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


def hd_to_640(x_hd: int, y_hd: int) -> list[int]:
    return [round((x_hd - 160) * 2 / 3), round(y_hd * 2 / 3)]


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


def generate_layout(assets: dict[str, dict[str, object]]) -> dict[str, dict[str, object]]:
    """Assign RAM_G addresses and SPG pages sequentially per asset/zlib chunk."""
    layout: dict[str, dict[str, object]] = {}
    ramg = LS_RAMG_BASE
    page = LS_SPG_FIRST_PAGE
    for stem, _short in RAMG_ORDER:
        entry = assets[stem]
        size = int(entry["size_bytes"])
        # spgbld auto-spans each Block through following 16K pages. Reserve
        # every page touched by the compressed stream so the next Block does
        # not overwrite the tail of a >16K zlib stream.
        zlib_pages = []
        for stream in entry["inflate_streams"]:
            zlib_pages.append({
                "page": page,
                "file": stream["file"],
                "zlib_size_bytes": stream["zlib_size_bytes"],
                "raw_offset": stream["raw_offset"],
                "raw_size_bytes": stream["raw_size_bytes"],
            })
            page += (int(stream["zlib_size_bytes"]) + PAGE_SIZE - 1) // PAGE_SIZE
        layout[stem] = {
            "ramg_address": ramg,
            "raw_size_bytes": size,
            "zlib_pages": zlib_pages,
        }
        ramg += size
    return layout


def emit_inc(assets: dict[str, dict[str, object]],
             layout: dict[str, dict[str, object]],
             sky_pal_page: int, ui_pal_page: int) -> str:
    lines: list[str] = []
    lines.append("; ============================================================================")
    lines.append("; Auto-generated by Source/OTHER/make_level_select_paletted.py — DO NOT EDIT.")
    lines.append("; Rerun the converter to regenerate this file after assets change.")
    lines.append("; ============================================================================")
    lines.append("")
    lines.append(f"LS_RAMG_END         EQU #{(LS_RAMG_BASE + sum(int(assets[s]['size_bytes']) for s, _ in RAMG_ORDER)):06X}")
    lines.append("")

    # --- Background (chunked zlib) ---
    bg_stem = Path(BACKGROUND).stem
    bg_layout = layout[bg_stem]
    bg_entry = assets[bg_stem]
    lines.append("; --- Background canvas (PALETTED4444, 5 zlib chunks) ---")
    lines.append(f"LS_BG_RAMG          EQU #{bg_layout['ramg_address']:06X}")
    lines.append(f"LS_BG_W             EQU {bg_entry['width']}")
    lines.append(f"LS_BG_H             EQU {bg_entry['height']}")
    lines.append(f"LS_BG_Z_CHUNK       EQU #{INFLATE_RAW_CHUNK:06X}")
    for i, zp in enumerate(bg_layout["zlib_pages"]):
        lines.append(f"LS_BG_Z{i}_PAGE       EQU #{zp['page']:02X}")
        lines.append(f"LS_BG_Z{i}_SIZE       EQU {zp['zlib_size_bytes']}")
    lines.append("")

    # --- Sky (single zlib) ---
    sky_stem = Path(SKY).stem
    sky_layout = layout[sky_stem]
    sky_entry = assets[sky_stem]
    lines.append("; --- Sky strip (PALETTED4444, single zlib, horizontal feathered seam) ---")
    lines.append(f"LS_SKY_RAMG         EQU #{sky_layout['ramg_address']:06X}")
    lines.append(f"LS_SKY_W            EQU {sky_entry['width']}")
    lines.append(f"LS_SKY_H            EQU {sky_entry['height']}")
    lines.append(f"LS_SKY_Z_PAGE       EQU #{sky_layout['zlib_pages'][0]['page']:02X}")
    lines.append(f"LS_SKY_Z_SIZE       EQU {sky_layout['zlib_pages'][0]['zlib_size_bytes']}")
    lines.append("")

    # --- Buttons ---
    for stem in BUTTON_STEMS:
        prefix = PREFIX_MAP[stem]
        normal_entry = assets[f"{stem}_normal"]
        x_hd, y_hd = HD_BUTTON_POSITIONS[stem]
        x_640, y_640 = hd_to_640(x_hd, y_hd)
        lines.append(f"; --- Button {stem} ---")
        lines.append(f"{prefix}_W             EQU {normal_entry['width']}")
        lines.append(f"{prefix}_H             EQU {normal_entry['height']}")
        lines.append(f"{prefix}_X             EQU {x_640}")
        lines.append(f"{prefix}_Y             EQU {y_640}")
        for state in BUTTON_STATES:
            asset_stem = f"{stem}_{state}"
            layout_entry = layout[asset_stem]
            short = state[0].upper()
            lines.append(f"{prefix}_{short}_RAMG       EQU #{layout_entry['ramg_address']:06X}")
            lines.append(f"{prefix}_{short}_Z_PAGE     EQU #{layout_entry['zlib_pages'][0]['page']:02X}")
            lines.append(f"{prefix}_{short}_Z_SIZE     EQU {layout_entry['zlib_pages'][0]['zlib_size_bytes']}")
        lines.append("")

    # --- Badges ---
    for stem in BADGE_STEMS:
        prefix = PREFIX_MAP[stem]
        normal_entry = assets[f"{stem}_normal"]
        x_hd, y_hd = HD_BADGE_POSITIONS[stem]
        x_640, y_640 = hd_to_640(x_hd, y_hd)
        lines.append(f"; --- Badge {stem} ---")
        lines.append(f"{prefix}_W             EQU {normal_entry['width']}")
        lines.append(f"{prefix}_H             EQU {normal_entry['height']}")
        lines.append(f"{prefix}_X             EQU {x_640}")
        lines.append(f"{prefix}_Y             EQU {y_640}")
        for state in BADGE_STATES:
            asset_stem = f"{stem}_{state}"
            layout_entry = layout[asset_stem]
            short = state[0].upper()
            lines.append(f"{prefix}_{short}_RAMG       EQU #{layout_entry['ramg_address']:06X}")
            lines.append(f"{prefix}_{short}_Z_PAGE     EQU #{layout_entry['zlib_pages'][0]['page']:02X}")
            lines.append(f"{prefix}_{short}_Z_SIZE     EQU {layout_entry['zlib_pages'][0]['zlib_size_bytes']}")
        lines.append("")

    # --- Palettes (shared addresses with main menu) ---
    lines.append("; --- Palettes (RAM_G addresses shared with main menu so cursor stays valid) ---")
    lines.append(f"LS_SKY_PAL_RAMG     EQU #{LS_SKY_PAL_RAMG:06X}")
    lines.append(f"LS_UI_PAL_RAMG      EQU #{LS_UI_PAL_RAMG:06X}")
    lines.append(f"LS_SKY_PAL_PAGE     EQU #{sky_pal_page:02X}")
    lines.append(f"LS_UI_PAL_PAGE      EQU #{ui_pal_page:02X}")
    lines.append("")
    lines.append("; --- Cursor (reuses main-menu cursor — already in RAM_G after menu init) ---")
    lines.append(f"LS_CURSOR_RAMG      EQU #{LS_CURSOR_RAMG:06X}")
    lines.append("")
    return "\n".join(lines) + "\n"


def emit_spg_blocks(layout: dict[str, dict[str, object]],
                    sky_pal_page: int, ui_pal_page: int) -> str:
    lines: list[str] = []
    lines.append("; --- Level select SPG blocks (append to spgbld_vdac2.ini) ---")
    for stem, _short in RAMG_ORDER:
        for zp in layout[stem]["zlib_pages"]:
            lines.append(f"Block = #0000, #{zp['page']:02X}, Graphics/Menu/Converted/{zp['file']}")
    lines.append(f"Block = #0000, #{sky_pal_page:02X}, Graphics/Menu/Converted/level_select_sky_palette_argb4.bin")
    lines.append(f"Block = #0000, #{ui_pal_page:02X}, Graphics/Menu/Converted/level_select_ui_palette_argb4.bin")
    return "\n".join(lines) + "\n"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)

    ui_rgba = {
        name: np.array(Image.open(SRC / name).convert("RGBA"), dtype=np.uint8)
        for name in UI_FILES
    }
    ui_palette = make_alpha_palette(ui_rgba)
    (OUT / "level_select_ui_palette_argb4.bin").write_bytes(palette_argb4_bytes(ui_palette))

    assets: dict[str, dict[str, object]] = {}
    for file_name, rgba in ui_rgba.items():
        stem = Path(file_name).stem
        entry = write_indices(stem, map_alpha_image(rgba, ui_palette))
        entry["source_png"] = file_name
        entry["palette"] = "level_select_ui_palette_argb4.bin"
        entry["alpha_bbox"] = alpha_bbox(rgba)
        assets[stem] = entry

    sky_image = Image.open(SRC / SKY).convert("RGBA")
    sky_image = feather_horizontal_seam(sky_image, SKY_FEATHER_PX)
    sky_palette, sky_indices = make_opaque_palette(sky_image)
    (OUT / "level_select_sky_palette_argb4.bin").write_bytes(palette_argb4_bytes(sky_palette))
    sky_entry = write_indices(Path(SKY).stem, sky_indices)
    sky_entry["source_png"] = SKY
    sky_entry["palette"] = "level_select_sky_palette_argb4.bin"
    sky_entry["screen_rect"] = [0, 0, sky_image.width, sky_image.height]
    assets[Path(SKY).stem] = sky_entry

    button_screen_rects = {}
    for stem, (x_hd, y_hd) in HD_BUTTON_POSITIONS.items():
        normal = assets[f"{stem}_normal"]
        x_640, y_640 = hd_to_640(x_hd, y_hd)
        button_screen_rects[stem] = {
            "hd_top_left": [x_hd, y_hd],
            "screen_xy_640x480": [x_640, y_640],
            "size_640x480": [int(normal["width"]), int(normal["height"])],
            "hit_dead_border_hd": 16,
            "hit_dead_border_640x480": round(16 * 2 / 3),
        }

    badge_screen_rects = {}
    for stem, (x_hd, y_hd) in HD_BADGE_POSITIONS.items():
        normal = assets[f"{stem}_normal"]
        x_640, y_640 = hd_to_640(x_hd, y_hd)
        badge_screen_rects[stem] = {
            "hd_top_left": [x_hd, y_hd],
            "screen_xy_640x480": [x_640, y_640],
            "size_640x480": [int(normal["width"]), int(normal["height"])],
        }

    raw_size = sum(int(entry["size_bytes"]) for entry in assets.values()) + 1024
    manifest = {
        "profile": "level_select",
        "draw_order": [
            Path(SKY).stem,
            Path(BACKGROUND).stem,
            "badges (rabbit, eagle, jaguar, sun_god)",
            "buttons (main_menu, back, play, next)",
        ],
        "coordinate_format": {
            "rect": ["x", "y", "width", "height"],
            "origin": "top-left",
            "units": "pixels",
        },
        "format_notes": [
            "Sky is opaque PALETTED4444 with own palette, horizontally feathered so wrap is seamless.",
            "Background, buttons, and badges share an alpha-preserving PALETTED4444 UI palette.",
            "Palette index 0 is transparent for the UI palette.",
            "Each raw bitmap has zlib output intended for the menu FT812 load path via CMD_INFLATE.",
            "Assets whose single zlib stream exceeds 64K also have chunked inflate_streams.",
            "Difficulty badges use the original interactive states: normal, hover, pressed.",
        ],
        "hd_release_reference": {
            "source_file": "C:/Users/Администратор/Desktop/Zuma-Deluxe-HD-release-v010-ref/src/menu/MenuMgr.c",
            "room": "MR_GAUNTLET",
            "sky_animation": {
                "hd_speed_pixels_per_update": 1,
                "wrap_width_hd": 1280,
                "vdac2_640x480_note": "Identical fixed-point 2/3 px/update wrap to the main menu sky.",
            },
            "behavior": {
                "main_menu_button": "Return to main menu (room MR_MAIN).",
                "back_button": "curLevel--.",
                "next_button": "curLevel++.",
                "play_button": "Enter game with (curLevel, curDifficulty).",
                "badges": "Set difficulty: rabbit=0, eagle=1, jaguar=2, sun_god=3. Selected badge stays green/hover; pointer hover uses red/pressed.",
            },
            "level_select_button_screen_rects": button_screen_rects,
            "level_select_badge_screen_rects": badge_screen_rects,
        },
        "assets": assets,
        "memory_bytes": {
            "raw_asset_pixels": sum(int(entry["size_bytes"]) for entry in assets.values()),
            "zlib_asset_streams": sum(int(entry["inflate_streams_size_bytes"]) for entry in assets.values()),
            "palettes": 1024,
            "total_without_alignment_padding": raw_size,
        },
    }
    layout = generate_layout(assets)
    # Palette pages get the next sequential SPG slots after the asset zlib pages.
    last_page = max(zp["page"] for entry in layout.values() for zp in entry["zlib_pages"])
    sky_pal_page = last_page + 1
    ui_pal_page = last_page + 2
    manifest["spg_layout"] = {
        "first_page": LS_SPG_FIRST_PAGE,
        "asset_pages": layout,
        "sky_palette_page": sky_pal_page,
        "ui_palette_page": ui_pal_page,
    }
    ASM_OUT.parent.mkdir(parents=True, exist_ok=True)
    ASM_OUT.write_text(emit_inc(assets, layout, sky_pal_page, ui_pal_page), encoding="utf-8")
    SPG_BLOCKS_OUT.write_text(emit_spg_blocks(layout, sky_pal_page, ui_pal_page), encoding="utf-8")

    (OUT / "level_select_assets.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    Image.fromarray(ui_palette[map_alpha_image(ui_rgba[BACKGROUND], ui_palette)], "RGBA").save(
        OUT / "level_select_screen_background_canvas_4x3_paletted_preview.png"
    )
    Image.fromarray(sky_palette[sky_indices], "RGBA").save(
        OUT / "level_select_screen_sky_canvas_4x3_paletted_preview.png"
    )

    print(f"Wrote level-select converted assets to {OUT}")
    print(f"Wrote ASM include to {ASM_OUT}")
    print(f"Wrote SPG block fragment to {SPG_BLOCKS_OUT}")
    print(f"Level-select raw RAM_G payload without alignment: {raw_size} bytes")
    print(f"SPG pages: #{LS_SPG_FIRST_PAGE:02X}..#{ui_pal_page:02X} ({ui_pal_page - LS_SPG_FIRST_PAGE + 1} pages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
