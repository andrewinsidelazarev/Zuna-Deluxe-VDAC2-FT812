#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Diagnostics" / "boot_sfx_preview"

BG_SRC = ROOT / "Graphics" / "Load Screen" / "loading_canvas_hdref_source_640x480_visual_center.png"
BAR_SRC = ROOT / "Graphics" / "Load Screen" / "progress_bar_hdref_alpha_bounds_scale_div_1_5.png"
TS_ANIM_DIR = ROOT / "Graphics" / "Load Screen" / "ts_anim"
LOGO_LEFT_SRC = ROOT / "Graphics" / "Logo" / "Claude.png"
LOGO_RIGHT_SRC = ROOT / "Graphics" / "Logo" / "codex-color.png"

SCREEN_W = 640
SCREEN_H = 480

BAR_X = 122
BAR_Y = 356
BAR_W = 395
BAR_H = 37
LOGICAL_BAR_W = 255

TS_X = 226
TS_Y = 272
TS_SHADOW_DX = 4
TS_SHADOW_DY = 5
TS_SHADOW_A = 96
TS_START_DELAY = 8
TS_FRAME_DELAY = 5

SFX_LOGO_W = 48
SFX_LOGO_H = 48
SFX_ROW_CENTER_X = 320
SFX_ROW_CENTER_Y = TS_Y + 18
SFX_ITEM_GAP = 8

REVEAL_FIRST_LOGO = 60
REVEAL_SECOND_LOGO = 64
REVEAL_NAME = 68
REVEAL_ALIAS = 72
REVEAL_PRESENT = 76

FRAME_PROGRESS = list(range(0, 96, 4)) + list(range(100, 256, 8))


def black_to_alpha(image: Image.Image) -> Image.Image:
    src = image.convert("RGBA")
    out = []
    for r, g, b, a in src.getdata():
        if r <= 8 and g <= 8 and b <= 8:
            out.append((r, g, b, 0))
        else:
            out.append((r, g, b, a))
    src.putdata(out)
    return src


def fit_icon(path: Path, size: tuple[int, int]) -> Image.Image:
    img = Image.open(path).convert("RGBA")
    img.thumbnail(size, Image.Resampling.LANCZOS)
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.alpha_composite(img, ((size[0] - img.width) // 2, (size[1] - img.height) // 2))
    return out


def shadowed_sprite(dst: Image.Image, sprite: Image.Image, xy: tuple[int, int]) -> None:
    x, y = xy
    shadow = Image.new("RGBA", sprite.size, (0, 0, 0, 0))
    _, _, _, alpha = sprite.split()
    shadow.putalpha(alpha.point(lambda value: value * TS_SHADOW_A // 255))
    dst.alpha_composite(shadow, (x + 3, y + 4))
    dst.alpha_composite(sprite, (x, y))


def load_ts_frames() -> list[Image.Image]:
    frames = []
    for index in range(1, 12):
        frames.append(black_to_alpha(Image.open(TS_ANIM_DIR / f"Image100{index:02d}.png")))
    return frames


def ts_frame_index(draw_tick: int, frame_count: int) -> int:
    if draw_tick <= TS_START_DELAY:
        return 0
    tick = draw_tick - TS_START_DELAY - 1
    return min(frame_count - 1, tick // (TS_FRAME_DELAY + 1))


def bar_pixels(progress: int) -> int:
    if progress >= LOGICAL_BAR_W:
        return BAR_W
    return min(BAR_W, progress + progress // 2)


def choose_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        Path("C:/Windows/Fonts/arialbd.ttf"),
        Path("C:/Windows/Fonts/arial.ttf"),
    ]
    for path in candidates:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def draw_text_at(draw: ImageDraw.ImageDraw, xy: tuple[int, int], text: str, font: ImageFont.ImageFont) -> None:
    x, y = xy
    for dx, dy in ((2, 2), (1, 2), (2, 1)):
        draw.text((x + dx, y + dy), text, font=font, fill=(0, 0, 0, 160))
    draw.text((x, y), text, font=font, fill=(255, 255, 255, 255))


def text_size(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def draw_sfx_overlay(frame: Image.Image, progress: int, tick: int, logo_a: Image.Image, logo_b: Image.Image) -> None:
    draw = ImageDraw.Draw(frame)
    font = choose_font(16)
    comma_w, comma_h = text_size(draw, ",", font)
    label = "Andrew Lazarev AKA INSiDE present" if progress >= REVEAL_PRESENT else "Andrew Lazarev AKA INSiDE"
    label_w, label_h = text_size(draw, label, font)
    row_w = (
        SFX_LOGO_W
        + SFX_ITEM_GAP + comma_w
        + SFX_ITEM_GAP + SFX_LOGO_W
        + SFX_ITEM_GAP + comma_w
        + SFX_ITEM_GAP + label_w
    )
    x = SFX_ROW_CENTER_X - row_w // 2
    logo_y = SFX_ROW_CENTER_Y - SFX_LOGO_H // 2
    text_y = SFX_ROW_CENTER_Y - label_h // 2 - 2
    comma_y = SFX_ROW_CENTER_Y - comma_h // 2 - 2

    if progress >= REVEAL_FIRST_LOGO:
        shadowed_sprite(frame, logo_a, (x, logo_y))
        draw_text_at(draw, (x + SFX_LOGO_W + SFX_ITEM_GAP, comma_y), ",", font)
    if progress >= REVEAL_SECOND_LOGO:
        second_logo_x = x + SFX_LOGO_W + SFX_ITEM_GAP + comma_w + SFX_ITEM_GAP
        shadowed_sprite(frame, logo_b, (second_logo_x, logo_y))
        draw_text_at(
            draw,
            (second_logo_x + SFX_LOGO_W + SFX_ITEM_GAP, comma_y),
            ",",
            font,
        )
    if progress >= REVEAL_PRESENT:
        draw_text_at(draw, (x + row_w - label_w, text_y), label, font)
    elif progress >= REVEAL_NAME:
        draw_text_at(draw, (x + row_w - label_w, text_y), label, font)


def render_frame(
    bg: Image.Image,
    bar: Image.Image,
    ts_frames: list[Image.Image],
    logo_a: Image.Image,
    logo_b: Image.Image,
    progress: int,
    tick: int,
) -> Image.Image:
    frame = bg.copy()

    if progress < REVEAL_FIRST_LOGO:
        ts = ts_frames[ts_frame_index(tick, len(ts_frames))]
        shadow = Image.new("RGBA", ts.size, (0, 0, 0, 0))
        _, _, _, alpha = ts.split()
        shadow.putalpha(alpha.point(lambda value: value * TS_SHADOW_A // 255))
        frame.alpha_composite(shadow, (TS_X + TS_SHADOW_DX, TS_Y + TS_SHADOW_DY))
        frame.alpha_composite(ts, (TS_X, TS_Y))

    fill = bar_pixels(progress)
    if fill:
        frame.alpha_composite(bar.crop((0, 0, fill, BAR_H)), (BAR_X, BAR_Y))

    draw_sfx_overlay(frame, progress, tick, logo_a, logo_b)
    return frame


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    bg = Image.open(BG_SRC).convert("RGBA")
    bar = Image.open(BAR_SRC).convert("RGBA")
    ts_frames = load_ts_frames()
    logo_a = fit_icon(LOGO_LEFT_SRC, (SFX_LOGO_W, SFX_LOGO_H))
    logo_b = fit_icon(LOGO_RIGHT_SRC, (SFX_LOGO_W, SFX_LOGO_H))

    frames = []
    key_progress = [0, 60, 64, 68, 72, 76, 96, 160, 255]
    for tick, progress in enumerate(FRAME_PROGRESS):
        frame = render_frame(bg, bar, ts_frames, logo_a, logo_b, progress, tick)
        frames.append(frame)
        if progress in key_progress:
            frame.save(OUT / f"boot_sfx_preview_p{progress:03d}.png")

    frames[0].save(
        OUT / "boot_sfx_preview.gif",
        save_all=True,
        append_images=frames[1:],
        duration=90,
        loop=0,
        disposal=2,
    )
    frames[-1].save(OUT / "boot_sfx_preview_final.png")
    print(f"wrote {len(frames)} frames to {OUT}")
    print(f"gif: {OUT / 'boot_sfx_preview.gif'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
