#!/usr/bin/env python3
"""Slice Zuma Deluxe HD menu assets from the original menu atlas."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
ATLAS = Path.home() / "Desktop" / "Zuma-Deluxe-HD-ref" / "content" / "images" / "menu.png"
OUT = ROOT / "Graphics" / "Menu" / "Original HD"


def rect(x: int, y: int, width: int, height: int) -> tuple[int, int, int, int]:
    return x, y, x + width, y + height


SLICES = {
    "main_screen_background_16x9.png": rect(1282, 720, 1280, 720),
    "level_select_screen_background_16x9.png": rect(1282, 1440, 1280, 720),
    "main_screen_sky_16x9.png": rect(10, 720, 1280, 250),
    "level_select_screen_sky_16x9.png": rect(0, 1442, 1280, 250),
    "main_sun.png": rect(2563, 315, 130, 138),
    "main_sun_light.png": rect(2563, 0, 315, 315),
}


def add_states(
    name: str,
    x: int,
    y: int,
    width: int,
    height: int,
    states: tuple[str, ...],
) -> None:
    for index, state in enumerate(states):
        SLICES[f"{name}_{state}.png"] = rect(x + width * index, y, width, height)


def add_relevant_buttons() -> None:
    main_states = ("normal", "hover", "pressed")
    level_states = ("normal", "hover", "pressed")
    level_badge_states = ("disabled", "normal", "hover", "pressed")

    add_states("main_button_options", 2563, 647, 299, 129, main_states)
    add_states("main_button_gauntlet", 2648, 776, 270, 125, main_states)
    add_states("main_button_adventure", 2724, 901, 245, 138, main_states)
    add_states("main_button_more_games", 2924, 1038, 177, 190, main_states)
    add_states("main_button_quit", 2917, 1226, 180, 211, main_states)

    add_states("level_select_button_main_menu", 1280, 2160, 211, 84, level_states)
    add_states("level_select_button_next", 1922, 2161, 141, 48, level_states)
    add_states("level_select_button_play", 1922, 2210, 157, 49, level_states)
    add_states("level_select_button_back", 1924, 2260, 139, 48, level_states)

    add_states("level_select_badge_rabbit", 1280, 2336, 328, 63, level_badge_states)
    add_states("level_select_badge_eagle", 1280, 2399, 258, 49, level_badge_states)
    add_states("level_select_badge_jaguar", 1280, 2448, 205, 43, level_badge_states)
    add_states("level_select_badge_sun_god", 1280, 2491, 159, 54, level_badge_states)


def save_canvas_crops(atlas: Image.Image) -> None:
    # Source canvases are 1280x720. A centered 4:3 crop keeps 960x720.
    for source_name, output_name in (
        ("main_screen_background_16x9.png", "main_screen_background_canvas_4x3.png"),
        ("level_select_screen_background_16x9.png", "level_select_screen_background_canvas_4x3.png"),
    ):
        source = atlas.crop(SLICES[source_name])
        source.crop((160, 0, 1120, 720)).save(OUT / output_name)


def main() -> None:
    add_relevant_buttons()
    OUT.mkdir(parents=True, exist_ok=True)

    atlas = Image.open(ATLAS).convert("RGBA")
    for name, crop in SLICES.items():
        atlas.crop(crop).save(OUT / name)
    save_canvas_crops(atlas)

    print(f"Sliced {len(SLICES) + 2} menu PNG files into {OUT}")


if __name__ == "__main__":
    main()
