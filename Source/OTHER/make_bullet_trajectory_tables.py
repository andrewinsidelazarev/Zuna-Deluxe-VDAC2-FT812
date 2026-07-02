"""Build per-level bullet trajectory event tables for Z80 collision prefilter.

The table is generated from the same 1024-space track samples that are packed
into ZUMALVL.PAK. It is intentionally recall-safe: events are emitted per VDC
cell along the hit corridor, then runtime still validates each candidate with
the old bbox/manhattan test before inserting a ball.
"""
from __future__ import annotations

import math
import re
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

TABLE_MAGIC = b"ZBT1"
TABLE_VERSION = 2
TABLE_PAGE = 16 * 1024
DIR_OFF = 16
ANGLE_COUNT = 256
STREAM_OFF = DIR_OFF + ANGLE_COUNT * 2

SCREEN_W = 1024
SCREEN_H = 768
BULLET_RADIUS = 26
BULLET_SPEED = 19
VDC_CELL_SIZE = 32

# Old runtime hit test: bbox threshold 35, then manhattan threshold 54.
# The offline corridor uses the wider number to avoid false negatives; Z80 keeps
# the exact old bbox/manhattan validation before accepting the event.
HIT_CORRIDOR_RADIUS = 54

EV_TRACK2 = 0x01
EV_HIT = 0x02
EV_TUNNEL = 0x04
EV_TUNNEL_ENTER = 0x08
EV_TUNNEL_EXIT = 0x10

TRACK_SRC_HDR = 2
TRACK_SRC_REC = 6
TRACKF_TUNNEL = 0x01


@dataclass(frozen=True)
class TrackSample:
    x: int
    y: int
    tangent: int
    flags: int


@dataclass
class Event:
    frame: int
    flags: int
    cell: int
    sub: int

    def key(self) -> tuple[int, int, int, int]:
        return (self.frame, self.flags, self.cell, self.sub)


def parse_old_track(blob: bytes) -> list[TrackSample]:
    count = struct.unpack_from("<H", blob, 0)[0]
    samples: list[TrackSample] = []
    off = TRACK_SRC_HDR
    for _ in range(count):
        x, y, tangent, flags = struct.unpack_from("<hhBB", blob, off)
        samples.append(TrackSample(x=x, y=y, tangent=tangent, flags=flags))
        off += TRACK_SRC_REC
    return samples


def load_frog_positions() -> list[tuple[int, int]]:
    text = (ROOT / "Source" / "ASM" / "level_runtime_table.inc").read_text(
        encoding="utf-8"
    )
    frogs: list[tuple[int, int]] = []
    in_table = False
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].strip()
        if line == "LevelRuntimeTable:":
            in_table = True
            continue
        if not in_table:
            continue
        if line.startswith("LEVEL_") or line.startswith("Level"):
            break
        if not line.startswith("DW "):
            continue
        nums = [int(x) for x in re.findall(r"-?\d+", line)]
        if len(nums) >= 2:
            frogs.append((nums[0], nums[1]))
    if len(frogs) != 22:
        raise ValueError(f"expected 22 frog positions, got {len(frogs)}")
    return frogs


def exit_distance_full_sprite(fx: int, fy: int, dx: float, dy: float) -> int:
    candidates: list[float] = []
    if dx > 0:
        candidates.append((SCREEN_W + BULLET_RADIUS - fx) / dx)
    elif dx < 0:
        candidates.append((-BULLET_RADIUS - fx) / dx)
    if dy > 0:
        candidates.append((SCREEN_H + BULLET_RADIUS - fy) / dy)
    elif dy < 0:
        candidates.append((-BULLET_RADIUS - fy) / dy)
    positives = [v for v in candidates if v >= 0]
    if not positives:
        return 0
    return int(math.ceil(min(positives)))


def distance_to_frame(s: float | int) -> int:
    return max(0, min(255, int(round(float(s) / BULLET_SPEED))))


def sample_projection(
    sample: TrackSample, fx: int, fy: int, dx: float, dy: float
) -> tuple[float, float]:
    rx = sample.x - fx
    ry = sample.y - fy
    s = rx * dx + ry * dy
    perp = abs(rx * dy - ry * dx)
    return s, perp


def emit_hit_events_for_track(
    samples: list[TrackSample],
    track_idx: int,
    fx: int,
    fy: int,
    dx: float,
    dy: float,
    exit_s: int,
) -> list[Event]:
    """Emit one best event per VDC cell inside the ray hit corridor."""
    best: dict[tuple[int, bool], tuple[float, int, int, int]] = {}
    for t, sample in enumerate(samples):
        s_float, perp = sample_projection(sample, fx, fy, dx, dy)
        if s_float < -HIT_CORRIDOR_RADIUS:
            continue
        if s_float > exit_s + HIT_CORRIDOR_RADIUS:
            continue
        if perp > HIT_CORRIDOR_RADIUS:
            continue
        cell = t // VDC_CELL_SIZE
        sub = t & (VDC_CELL_SIZE - 1)
        if cell > 255:
            raise ValueError(f"track cell index {cell} does not fit u8")
        tunnel = bool(sample.flags & TRACKF_TUNNEL)
        key = (cell, tunnel)
        rank = (perp, abs(s_float - round(s_float)), int(round(s_float)), sub)
        old = best.get(key)
        if old is None or rank < old:
            best[key] = rank

    events: list[Event] = []
    base_flags = EV_HIT | (EV_TRACK2 if track_idx else 0)
    for (cell, tunnel), (_perp, _frac, s_int, sub) in best.items():
        flags = base_flags | (EV_TUNNEL if tunnel else 0)
        s_int = max(0, min(exit_s, s_int))
        events.append(Event(frame=distance_to_frame(s_int), flags=flags, cell=cell, sub=sub))
    return events


def emit_tunnel_range_events_for_track(
    samples: list[TrackSample],
    track_idx: int,
    fx: int,
    fy: int,
    dx: float,
    dy: float,
    exit_s: int,
) -> list[Event]:
    """Emit enter/exit markers for no-hit/tunnel zones crossed by the ray."""
    events: list[Event] = []
    base = EV_TRACK2 if track_idx else 0
    active: list[tuple[int, float, int]] = []  # (t, s, cell)

    def flush() -> None:
        nonlocal active
        if not active:
            return
        active.sort(key=lambda item: item[1])
        t0, s0, cell0 = active[0]
        t1, s1, cell1 = active[-1]
        events.append(
            Event(
                frame=distance_to_frame(max(0, min(exit_s, int(round(s0))))),
                flags=base | EV_TUNNEL_ENTER,
                cell=min(255, cell0),
                sub=t0 & (VDC_CELL_SIZE - 1),
            )
        )
        events.append(
            Event(
                frame=distance_to_frame(max(0, min(exit_s, int(round(s1))))),
                flags=base | EV_TUNNEL_EXIT,
                cell=min(255, cell1),
                sub=t1 & (VDC_CELL_SIZE - 1),
            )
        )
        active = []

    prev_t: int | None = None
    for t, sample in enumerate(samples):
        s_float, perp = sample_projection(sample, fx, fy, dx, dy)
        near = (
            bool(sample.flags & TRACKF_TUNNEL)
            and -HIT_CORRIDOR_RADIUS <= s_float <= exit_s + HIT_CORRIDOR_RADIUS
            and perp <= HIT_CORRIDOR_RADIUS
        )
        if not near:
            flush()
            prev_t = None
            continue
        if prev_t is not None and t != prev_t + 1:
            flush()
        cell = t // VDC_CELL_SIZE
        if cell > 255:
            raise ValueError(f"track cell index {cell} does not fit u8")
        active.append((t, s_float, cell))
        prev_t = t
    flush()
    return events


def coalesce_events(events: Iterable[Event]) -> list[Event]:
    by_key: dict[tuple[int, int, int, int], Event] = {}
    for ev in events:
        by_key[ev.key()] = ev
    return sorted(by_key.values(), key=lambda ev: (ev.frame, ev.flags, ev.cell, ev.sub))


def build_level_table(level_idx0: int, scaled_tracks: list[bytes]) -> bytes:
    frogs = load_frog_positions()
    fx, fy = frogs[level_idx0]
    tracks = [parse_old_track(blob) for blob in scaled_tracks if blob is not None]
    if not tracks:
        raise ValueError(f"L{level_idx0 + 1:02d}: no track samples")

    out = bytearray(TABLE_PAGE)
    out[0:4] = TABLE_MAGIC
    out[4] = TABLE_VERSION
    out[5] = level_idx0 + 1
    out[6] = len(tracks)
    out[7] = HIT_CORRIDOR_RADIUS
    struct.pack_into("<H", out, 8, BULLET_SPEED)
    struct.pack_into("<H", out, 10, BULLET_RADIUS)
    pos = STREAM_OFF
    max_events = 0

    for angle in range(ANGLE_COUNT):
        rad = angle * math.tau / ANGLE_COUNT
        dx = math.cos(rad)
        dy = math.sin(rad)
        exit_s = exit_distance_full_sprite(fx, fy, dx, dy)
        events: list[Event] = []
        for track_idx, samples in enumerate(tracks):
            events.extend(
                emit_hit_events_for_track(samples, track_idx, fx, fy, dx, dy, exit_s)
            )
            events.extend(
                emit_tunnel_range_events_for_track(
                    samples, track_idx, fx, fy, dx, dy, exit_s
                )
            )
        events = coalesce_events(events)
        if len(events) > 255:
            raise ValueError(
                f"L{level_idx0 + 1:02d} angle {angle}: {len(events)} events > 255"
            )
        max_events = max(max_events, len(events))
        needed = 2 + len(events) * 4
        if pos + needed > TABLE_PAGE:
            raise ValueError(
                f"L{level_idx0 + 1:02d}: bullet table overflow at angle {angle}, "
                f"need {pos + needed} bytes"
            )
        struct.pack_into("<H", out, DIR_OFF + angle * 2, pos)
        out[pos + 0] = distance_to_frame(exit_s)
        out[pos + 1] = len(events)
        pos += 2
        for ev in events:
            struct.pack_into("<BBBB", out, pos, ev.frame, ev.flags, ev.cell, ev.sub)
            pos += 4

    struct.pack_into("<H", out, 12, pos)
    out[14] = max_events
    return bytes(out)


def main() -> int:
    from make_level_pack import PACK_ASSETS, LEVEL_COUNT, scale_track_samples

    total = 0
    for li in range(LEVEL_COUNT):
        n = li + 1
        paths = [PACK_ASSETS / f"track_l{n:02d}_640.bin"]
        second = PACK_ASSETS / f"track_l{n:02d}_2_640.bin"
        if second.exists():
            paths.append(second)
        scaled = [scale_track_samples(p.read_bytes()) for p in paths if p.exists()]
        table = build_level_table(li, scaled)
        used = struct.unpack_from("<H", table, 12)[0]
        max_events = table[14]
        total += used
        print(f"L{n:02d}: ZBT1 used={used:5d}/16384 max_events={max_events}")
    print(f"total stream bytes used={total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
