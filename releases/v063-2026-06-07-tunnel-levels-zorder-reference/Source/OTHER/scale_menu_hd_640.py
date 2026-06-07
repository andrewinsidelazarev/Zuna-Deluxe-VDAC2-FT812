#!/usr/bin/env python3
"""Scale HD menu slices into the VDAC2 640x480 menu coordinate space."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Graphics" / "Menu" / "Original HD"
OUT = ROOT / "Graphics" / "Menu" / "Original to 640-480"
SRC_JSON = SRC / "menu_hd_slices.json"
OUT_JSON = OUT / "menu_hd_slices_640x480.json"
SCALE_NUM = 2
SCALE_DEN = 3


def scaled(value: int) -> int:
    return (value * SCALE_NUM + SCALE_DEN // 2) // SCALE_DEN


def scale_size(width: int, height: int) -> tuple[int, int]:
    return scaled(width), scaled(height)


def resize_file(source_name: str, output_name: str | None = None) -> tuple[int, int]:
    output_name = output_name or source_name
    with Image.open(SRC / source_name) as image:
        output_size = scale_size(image.width, image.height)
        image.convert("RGBA").resize(output_size, Image.Resampling.LANCZOS).save(OUT / output_name)
    return output_size


def crop_and_scale_sky(source_name: str, output_name: str) -> tuple[int, int]:
    # Sky strips use the same centered 16:9 -> 4:3 x crop as the screen canvases.
    with Image.open(SRC / source_name) as image:
        crop = image.convert("RGBA").crop((160, 0, 1120, image.height))
        output_size = scale_size(crop.width, crop.height)
        crop.resize(output_size, Image.Resampling.LANCZOS).save(OUT / output_name)
    return output_size


def local_rect(size: tuple[int, int]) -> list[int]:
    return [0, 0, size[0], size[1]]


def scaled_atlas_rect(rect: list[int]) -> list[int]:
    return [scaled(value) for value in rect]


def add_asset(
    output: dict[str, Any],
    source_name: str,
    output_name: str,
    output_size: tuple[int, int],
    source_atlas_rect: list[int] | None = None,
) -> None:
    asset: dict[str, Any] = {
        "source_file": source_name,
        "output_file": output_name,
        "output_local_rect": local_rect(output_size),
    }
    if source_atlas_rect is not None:
        asset["source_atlas_rect"] = source_atlas_rect
        asset["source_atlas_rect_scaled_reference"] = scaled_atlas_rect(source_atlas_rect)
    output[output_name] = asset


def scale_single_layers(metadata: dict[str, Any], assets: dict[str, Any]) -> None:
    # Background canvases are produced from the centered 4:3 PNGs.
    for name, entry in metadata["derived_slices"].items():
        size = resize_file(name)
        add_asset(assets, name, name, size)
        assets[name]["screen_rect_640x480"] = local_rect(size)
        assets[name]["source_local_crop_rect"] = entry["source_local_crop_rect"]

    # Sun layers are separate screen elements from the menu atlas.
    for name in ("main_sun.png", "main_sun_light.png"):
        size = resize_file(name)
        add_asset(assets, name, name, size, metadata["single_slices"][name]["rect"])

    for source_name, output_name in (
        ("main_screen_sky_16x9.png", "main_screen_sky_canvas_4x3.png"),
        ("level_select_screen_sky_16x9.png", "level_select_screen_sky_canvas_4x3.png"),
    ):
        size = crop_and_scale_sky(source_name, output_name)
        add_asset(assets, source_name, output_name, size, metadata["single_slices"][source_name]["rect"])
        assets[output_name]["source_local_crop_rect"] = [160, 0, 960, 250]


def scale_state_groups(metadata: dict[str, Any], assets: dict[str, Any]) -> dict[str, Any]:
    groups: dict[str, Any] = {}
    for group_name, group in metadata["state_groups"].items():
        base_x, base_y, width, height = group["base_rect"]
        stride_x, stride_y = group["state_stride"]
        groups[group_name] = {
            "states": group["states"],
            "file_pattern": group["file_pattern"],
            "source_base_atlas_rect": group["base_rect"],
            "source_state_stride": group["state_stride"],
            "output_asset_size": [scaled(width), scaled(height)],
        }
        for index, state in enumerate(group["states"]):
            name = group["file_pattern"].format(state=state)
            size = resize_file(name)
            source_rect = [
                base_x + stride_x * index,
                base_y + stride_y * index,
                width,
                height,
            ]
            add_asset(assets, name, name, size, source_rect)
    return groups


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(SRC_JSON.read_text(encoding="utf-8"))
    assets: dict[str, Any] = {}

    scale_single_layers(metadata, assets)
    groups = scale_state_groups(metadata, assets)

    output_metadata = {
        "source_metadata": str(SRC_JSON).replace("\\", "/"),
        "coordinate_format": {
            "rect": ["x", "y", "width", "height"],
            "origin": "top-left",
            "units": "pixels",
        },
        "screen_space_640x480": {
            "size": {"width": 640, "height": 480},
            "from_hd_canvas": {
                "source_canvas_size": {"width": 1280, "height": 720},
                "center_crop_rect": [160, 0, 960, 720],
                "scale": "2/3",
            },
        },
        "notes": [
            "Output PNG coordinates are local to each sliced asset unless screen_rect_640x480 is present.",
            "source_atlas_rect_scaled_reference scales the atlas crop rect by 2/3; it is not a placement coordinate.",
            "The HD reference source provides atlas crop coordinates here, not final on-screen button placement coordinates.",
        ],
        "assets": assets,
        "state_groups": groups,
    }
    OUT_JSON.write_text(json.dumps(output_metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Scaled {len(assets)} menu PNG files into {OUT}")
    print(f"Wrote {OUT_JSON}")


if __name__ == "__main__":
    main()
