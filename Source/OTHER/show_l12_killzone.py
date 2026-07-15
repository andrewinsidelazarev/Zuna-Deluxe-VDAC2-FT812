#!/usr/bin/env python3
"""Интерактивная схема границы kill-zone на уровне L12 (Snake Pit).

Скрипт ничего не сохраняет на диск. Он открывает окно, кладёт родной фон
уровня нижним слоем и рисует поверх обе baked-кривые L12.

Текущий контракт VDC_CheckKillzone:
    rem > 64   — голова ещё вне kill-zone;
    rem 1..64  — участок kill-zone, пасть открывается;
    rem <= 0   — конец baked-трека и запуск Lose State.
"""

from __future__ import annotations

import argparse
import struct
import tkinter as tk
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageTk


ROOT = Path(__file__).resolve().parents[2]
BACKGROUND = ROOT / "Graphics" / "levels" / "Original" / "12-snakepit" / "level_src_12.png"
TRACKS = (
    ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l12_640.bin",
    ROOT / "Graphics" / "levels" / "Converted" / "pack" / "track_l12_2_640.bin",
)

# VDC_CheckKillzone начинает открывать череп при rem <= 64.
KILLZONE_REMAINING = 64
TRACK_RECORD_SIZE = 6  # x:int16, y:int16, tangent:uint8, flags:uint8


@dataclass(frozen=True)
class Track:
    number: int
    points: tuple[tuple[int, int], ...]

    @property
    def end_index(self) -> int:
        return len(self.points) - 1

    @property
    def killzone_start_index(self) -> int:
        return max(0, self.end_index - KILLZONE_REMAINING)

    @property
    def killzone_start(self) -> tuple[int, int]:
        return self.points[self.killzone_start_index]

    @property
    def end(self) -> tuple[int, int]:
        return self.points[self.end_index]


def load_track(path: Path, number: int) -> Track:
    data = path.read_bytes()
    if len(data) < 2:
        raise ValueError(f"Пустой файл трека: {path}")

    count = struct.unpack_from("<H", data, 0)[0]
    expected_size = 2 + count * TRACK_RECORD_SIZE
    if len(data) != expected_size:
        raise ValueError(
            f"Неверный размер {path.name}: {len(data)}, ожидалось {expected_size} "
            f"для {count} sample"
        )

    points: list[tuple[int, int]] = []
    offset = 2
    for _ in range(count):
        x, y, _tangent, _flags = struct.unpack_from("<hhBB", data, offset)
        points.append((x, y))
        offset += TRACK_RECORD_SIZE

    if len(points) <= KILLZONE_REMAINING:
        raise ValueError(f"Трек {number} короче участка kill-zone")
    return Track(number, tuple(points))


def scaled_points(points: tuple[tuple[int, int], ...], scale: float) -> list[float]:
    flat: list[float] = []
    for x, y in points:
        flat.extend((x * scale, y * scale))
    return flat


class Viewer:
    TRACK_COLORS = ("#19d7ff", "#ffe34d")
    KILLZONE_COLORS = ("#ff3030", "#ff8a24")

    def __init__(self, background: Image.Image, tracks: tuple[Track, ...]) -> None:
        self.root = tk.Tk()
        self.root.title("L12 — начало kill-zone и конец baked-трека")

        max_scale_x = (self.root.winfo_screenwidth() - 80) / background.width
        max_scale_y = (self.root.winfo_screenheight() - 120) / background.height
        self.scale = max(1.0, min(1.75, max_scale_x, max_scale_y))
        width = round(background.width * self.scale)
        height = round(background.height * self.scale)

        resized = background.resize((width, height), Image.Resampling.LANCZOS)
        self.background_photo = ImageTk.PhotoImage(resized)
        self.canvas = tk.Canvas(
            self.root,
            width=width,
            height=height,
            highlightthickness=0,
            background="black",
        )
        self.canvas.pack()
        self.canvas.create_image(0, 0, image=self.background_photo, anchor="nw")

        for track in tracks:
            self.draw_track(track)
        self.draw_legend(tracks)

        self.root.bind("<Escape>", lambda _event: self.root.destroy())

    def xy(self, point: tuple[int, int]) -> tuple[float, float]:
        return point[0] * self.scale, point[1] * self.scale

    def draw_track(self, track: Track) -> None:
        track_color = self.TRACK_COLORS[track.number - 1]
        killzone_color = self.KILLZONE_COLORS[track.number - 1]

        # Вся baked-кривая поверх фоновой канавки.
        self.canvas.create_line(
            *scaled_points(track.points, self.scale),
            fill=track_color,
            width=max(2, round(2 * self.scale)),
            smooth=False,
        )

        # Последние 64 sample — ровно участок rem=64..0 из VDC_CheckKillzone.
        killzone_points = track.points[track.killzone_start_index :]
        self.canvas.create_line(
            *scaled_points(killzone_points, self.scale),
            fill=killzone_color,
            width=max(4, round(5 * self.scale)),
            smooth=False,
        )

        start_x, start_y = self.xy(track.killzone_start)
        end_x, end_y = self.xy(track.end)
        radius = 7 * self.scale

        # Зелёное кольцо — первый центр шара, для которого rem <= 64.
        self.canvas.create_oval(
            start_x - radius,
            start_y - radius,
            start_x + radius,
            start_y + radius,
            outline="#3cff57",
            width=max(3, round(3 * self.scale)),
        )

        # Бело-малиновый крест — последний baked sample, rem=0.
        cross = 9 * self.scale
        for color, width in (("#ffffff", 5), ("#ff2bd6", 2)):
            line_width = max(1, round(width * self.scale))
            self.canvas.create_line(
                end_x - cross,
                end_y - cross,
                end_x + cross,
                end_y + cross,
                fill=color,
                width=line_width,
            )
            self.canvas.create_line(
                end_x - cross,
                end_y + cross,
                end_x + cross,
                end_y - cross,
                fill=color,
                width=line_width,
            )

        # Подписи отнесены от точек, чтобы сами координаты оставались видимыми.
        direction = -1 if track.number == 1 else 1
        self.label_with_pointer(
            start_x,
            start_y,
            start_x + direction * 78 * self.scale,
            start_y - 54 * self.scale,
            f"Цепь {track.number}: НАЧАЛО KILL-ZONE\n"
            f"sample {track.killzone_start_index}, rem=64\n"
            f"({track.killzone_start[0]}, {track.killzone_start[1]})",
            "#3cff57",
        )
        self.label_with_pointer(
            end_x,
            end_y,
            end_x + direction * 86 * self.scale,
            end_y + 58 * self.scale,
            f"Цепь {track.number}: КОНЕЦ ТРЕКА\n"
            f"sample {track.end_index}, rem=0\n"
            f"({track.end[0]}, {track.end[1]})",
            "#ff80e5",
        )

    def label_with_pointer(
        self,
        point_x: float,
        point_y: float,
        text_x: float,
        text_y: float,
        text: str,
        color: str,
    ) -> None:
        self.canvas.create_line(
            point_x,
            point_y,
            text_x,
            text_y,
            fill=color,
            width=max(1, round(2 * self.scale)),
            arrow=tk.LAST,
        )
        text_id = self.canvas.create_text(
            text_x,
            text_y,
            text=text,
            fill=color,
            font=("Segoe UI", max(9, round(10 * self.scale)), "bold"),
            justify="center",
            anchor="center",
        )
        bbox = self.canvas.bbox(text_id)
        if bbox:
            pad = 4 * self.scale
            background_id = self.canvas.create_rectangle(
                bbox[0] - pad,
                bbox[1] - pad,
                bbox[2] + pad,
                bbox[3] + pad,
                fill="#101010",
                outline=color,
                width=1,
            )
            self.canvas.tag_lower(background_id, text_id)

    def draw_legend(self, tracks: tuple[Track, ...]) -> None:
        lines = [
            "L12 / Snake Pit — фактические baked-данные",
            "голубой/жёлтый: треки до kill-zone",
            "красный/оранжевый: последние 64 sample (rem=64..0)",
            "зелёное кольцо: начало kill-zone",
            "крест: последний sample и конец трека",
            "Esc — закрыть окно",
        ]
        text_id = self.canvas.create_text(
            12 * self.scale,
            12 * self.scale,
            text="\n".join(lines),
            anchor="nw",
            justify="left",
            fill="white",
            font=("Segoe UI", max(9, round(10 * self.scale)), "bold"),
        )
        bbox = self.canvas.bbox(text_id)
        if bbox:
            pad = 7 * self.scale
            background_id = self.canvas.create_rectangle(
                bbox[0] - pad,
                bbox[1] - pad,
                bbox[2] + pad,
                bbox[3] + pad,
                fill="#080808",
                outline="#dddddd",
                width=1,
            )
            self.canvas.tag_lower(background_id, text_id)

    def run(self) -> None:
        self.root.mainloop()


def print_boundaries(tracks: tuple[Track, ...]) -> None:
    for track in tracks:
        print(
            f"Цепь {track.number}: samples={len(track.points)}, "
            f"начало kill-zone sample={track.killzone_start_index} "
            f"xy={track.killzone_start}, конец sample={track.end_index} xy={track.end}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Показать фон L12, обе кривые, начало kill-zone и конец трека."
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="напечатать точные sample/координаты без открытия окна",
    )
    args = parser.parse_args()

    tracks = tuple(load_track(path, index) for index, path in enumerate(TRACKS, 1))
    print_boundaries(tracks)
    if args.print_only:
        return 0

    background = Image.open(BACKGROUND).convert("RGB")
    Viewer(background, tracks).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
